package daemon

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/provider"
)

// Opt-in because this exercises the installed npm executable. Every package,
// registry response, prefix, cache and provider is disposable and local. The
// acquired package only launches this package's existing ACP protocol helper.
func TestACPRegistryNPMUpdatePreservesActiveTurn(t *testing.T) {
	if os.Getenv("MAID_REGISTRY_NPM_QA") != "1" {
		t.Skip("set MAID_REGISTRY_NPM_QA=1 to exercise local npm acquisition")
	}
	npm, err := exec.LookPath("npm")
	if err != nil {
		t.Fatal(err)
	}
	version, err := exec.Command(npm, "--version").Output()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("npm=%s version=%s", npm, strings.TrimSpace(string(version)))
	dir := t.TempDir()
	launchLog := filepath.Join(dir, "launches")
	config := filepath.Join(dir, "empty-npmrc")
	globalConfig := filepath.Join(dir, "empty-global-npmrc")
	if err := os.WriteFile(config, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(globalConfig, nil, 0600); err != nil {
		t.Fatal(err)
	}
	archives := map[string][]byte{}
	for _, v := range []string{"1.0.0", "2.0.0"} {
		archives[v] = registryQAPackage(t, v)
	}
	var mu sync.Mutex
	ceiling := "1.0.0"
	downloads := map[string]int{}
	var registryURL string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/acp.json":
			mu.Lock()
			v := ceiling
			mu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]any{"version": "1", "agents": []any{map[string]any{
				"id": "qa-agent", "name": "QA Agent", "version": v,
				"distribution": map[string]any{"npx": map[string]any{"package": "maid-qa-agent@" + v, "env": map[string]string{
					"npm_config_registry": registryURL, "npm_config_userconfig": config, "npm_config_globalconfig": globalConfig,
					"npm_config_audit": "false", "npm_config_fund": "false",
					"MAID_DAEMON_ACP_HELPER": "1", "QA_HELPER": os.Args[0], "QA_LAUNCH_LOG": launchLog,
				}}},
			}}})
		case "/maid-qa-agent":
			versions := map[string]any{}
			for v, archive := range archives {
				sum := sha1.Sum(archive)
				versions[v] = map[string]any{"name": "maid-qa-agent", "version": v, "bin": map[string]string{"maid-qa-agent": "agent.js"}, "dist": map[string]string{"tarball": registryURL + "/" + v + ".tgz", "shasum": hex.EncodeToString(sum[:])}}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "maid-qa-agent", "dist-tags": map[string]string{"latest": "2.0.0"}, "versions": versions})
		case "/1.0.0.tgz", "/2.0.0.tgz":
			v := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/"), ".tgz")
			mu.Lock()
			downloads[v]++
			mu.Unlock()
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(archives[v])
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	registryURL = server.URL
	// Keep npm configuration isolated even for the CLI's startup phase.
	t.Setenv("NPM_CONFIG_USERCONFIG", config)
	t.Setenv("NPM_CONFIG_GLOBALCONFIG", globalConfig)
	t.Setenv("NPM_CONFIG_REGISTRY", registryURL)
	s := newTestServer(t)
	defer s.Close()
	s.acpRegistry = &acpRegistry{url: registryURL + "/acp.json", client: server.Client(), dataDir: filepath.Join(dir, "data"), npm: npm}
	client := dialRecordingClient(t, newWSTestServer(t, s))
	var catalog []wire.ACPRegistryAgent
	client.call(t, wire.MethodACPRegistryList, nil, &catalog)
	var installed wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryInstall, wire.ACPRegistryInstallParams{RegistryID: "qa-agent"}, &installed)
	if installed.Version != "1.0.0" {
		t.Fatalf("initial version=%s", installed.Version)
	}
	var foundCold bool
	for _, instance := range s.providerService.ListInstances() {
		if instance.InstanceID == installed.InstanceID && instance.Status == provider.InstanceStatusConfigured {
			foundCold = true
		}
	}
	if !foundCold {
		t.Fatal("install should register a cold provider")
	}
	var info provider.InstanceInfo
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa-agent"}, &info)
	firstPID := info.PID
	thread := client.createThread(t, info.InstanceID, dir).Thread
	client.subscribe(t, thread)
	blocked := client.deliver(t, thread, "block "+dir).Delivery
	waitForFile(t, filepath.Join(dir, "ready"))
	mu.Lock()
	ceiling = "2.0.0"
	mu.Unlock()
	client.call(t, wire.MethodACPRegistryList, nil, &catalog)
	client.call(t, wire.MethodACPRegistryInstall, wire.ACPRegistryInstallParams{RegistryID: "qa-agent"}, &installed)
	if installed.Version != "2.0.0" {
		t.Fatalf("updated version=%s", installed.Version)
	}
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa-agent"}, &info)
	if info.PID != firstPID {
		t.Fatal("update replaced the running provider")
	}
	if turns := client.subscribe(t, thread).Turns; len(turns) != 1 || turns[0].State != provider.TurnRunning {
		t.Fatalf("active turn interrupted: %#v", turns)
	}
	launches, err := os.ReadFile(launchLog)
	if err != nil || string(launches) != "1.0.0\n" {
		t.Fatalf("active launch log=%q error=%v", launches, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "release"), []byte("finish"), 0600); err != nil {
		t.Fatal(err)
	}
	turn := client.waitSettled(t, thread, blocked)
	if want := []string{"user_message: block " + dir, "assistant_message: hi"}; turn.State != provider.TurnCompleted || !slices.Equal(entryTexts(turn), want) {
		t.Fatalf("turn after update = %s %q, want completed %q", turn.State, entryTexts(turn), want)
	}
	// End only the owned, now-idle process group. The chat's next message
	// must start the saved update, not silently respawn the old version.
	if err := syscall.Kill(-firstPID, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the old version to exit", func() bool {
		current, ok := s.providerService.Info(info.InstanceID)
		return ok && current.Status == provider.InstanceStatusExited
	})
	if turn := client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn on the update = %s, want completed", turn.State)
	}
	launches, err = os.ReadFile(launchLog)
	if err != nil || string(launches) != "1.0.0\n2.0.0\n" {
		t.Fatalf("recovery launch log=%q error=%v", launches, err)
	}
	reloaded := &acpRegistry{dataDir: s.acpRegistry.dataDir, npm: npm}
	records, err := reloaded.installedAgents()
	if err != nil || len(records) != 1 || records[0].Version != "2.0.0" {
		t.Fatalf("reloaded manifest=%v error=%v", records, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if downloads["1.0.0"] != 1 || downloads["2.0.0"] != 1 {
		t.Fatalf("downloads=%v", downloads)
	}
	t.Log("PASS: local npm ceiling, cold install, active-turn update, unchanged PID, exact completion, next-launch version and manifest reload")
}

func registryQAPackage(t *testing.T, version string) []byte {
	t.Helper()
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	archive := tar.NewWriter(gz)
	manifest := fmt.Sprintf(`{"name":"maid-qa-agent","version":%q,"bin":{"maid-qa-agent":"agent.js"}}`, version)
	script := `#!/usr/bin/env node
const fs=require('node:fs');
const {spawn}=require('node:child_process');
fs.appendFileSync(process.env.QA_LAUNCH_LOG,require('./package.json').version+'\n');
const child=spawn(process.env.QA_HELPER,['-test.run=TestHelperProcess'],{stdio:'inherit'});
child.on('exit',code=>process.exit(code??1));
`
	for name, data := range map[string]string{"package/package.json": manifest, "package/agent.js": script} {
		if err := archive.WriteHeader(&tar.Header{Name: name, Mode: 0755, Size: int64(len(data))}); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write([]byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}
