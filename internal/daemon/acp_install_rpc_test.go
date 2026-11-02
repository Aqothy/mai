package daemon

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

// fakeACPHosts serves the registry index, downloads and every release API over
// TLS. Requests to any host reach it, so the daemon's real URLs work unchanged.
type fakeACPHosts struct {
	t      *testing.T
	server *httptest.Server

	mu       sync.Mutex
	index    string
	files    map[string][]byte
	gates    map[string]chan struct{}
	requests map[string]int
}

type rewriteToServer struct {
	target *url.URL
	base   http.RoundTripper
}

func (r rewriteToServer) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.URL.Path = "/" + req.URL.Host + req.URL.Path
	req.URL.RawPath = ""
	req.URL.Host, req.URL.Scheme = r.target.Host, r.target.Scheme
	return r.base.RoundTrip(req)
}

// serveFakeACPHosts points s's registry at a fake index.
func serveFakeACPHosts(t *testing.T, s *Server) *fakeACPHosts {
	t.Helper()
	hosts := &fakeACPHosts{t: t, files: map[string][]byte{}, gates: map[string]chan struct{}{}, requests: map[string]int{}}
	hosts.server = httptest.NewTLSServer(http.HandlerFunc(hosts.serve))
	t.Cleanup(hosts.server.Close)
	target, err := url.Parse(hosts.server.URL)
	if err != nil {
		t.Fatal(err)
	}
	client := hosts.server.Client()
	client.Transport = rewriteToServer{target: target, base: client.Transport}
	s.acpRegistry.url, s.acpRegistry.client = "https://registry.test/index.json", client
	return hosts
}

func (h *fakeACPHosts) serve(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	h.requests[r.URL.Path]++
	body, ok := h.files[r.URL.Path]
	gate := h.gates[r.URL.Path]
	if r.URL.Path == "/registry.test/index.json" {
		body, ok = []byte(h.index), true
	}
	h.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-r.Context().Done():
			return
		}
	}
	if !ok {
		http.NotFound(w, r)
		return
	}
	_, _ = w.Write(body)
}

func (h *fakeACPHosts) setIndex(agents ...string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.index = `{"version":"1","agents":[` + strings.Join(agents, ",") + `]}`
}

// put serves body at host+path, and returns the file's real URL.
func (h *fakeACPHosts) put(hostAndPath string, body []byte) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.files["/"+hostAndPath] = body
	return "https://" + hostAndPath
}

// hold makes requests for a file wait until the returned function runs.
func (h *fakeACPHosts) hold(hostAndPath string) (release func()) {
	gate := make(chan struct{})
	h.mu.Lock()
	h.gates["/"+hostAndPath] = gate
	h.mu.Unlock()
	release = sync.OnceFunc(func() {
		h.mu.Lock()
		delete(h.gates, "/"+hostAndPath)
		h.mu.Unlock()
		close(gate)
	})
	h.t.Cleanup(release)
	return release
}

func (h *fakeACPHosts) requested(hostAndPath string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.requests["/"+hostAndPath]
}

// fakeBinaryAgent is an index entry for this platform's build of an agent.
func fakeBinaryAgent(id, version, archive, sha string) string {
	target, _ := json.Marshal(map[string]any{
		"archive": archive, "cmd": "./bin/agent", "sha256": sha,
		"env": map[string]string{"MAID_DAEMON_ACP_HELPER": "1"},
	})
	return fmt.Sprintf(`{"id":%q,"name":%q,"version":%q,"description":"d","repository":"https://example.test/repo","website":"https://example.test","license_url":"https://example.test/license","distribution":{"binary":{%q:%s}}}`,
		id, id, version, acpPlatform(), target)
}

// fakeAgentScript launches the fake ACP agent, logging which version ran.
func fakeAgentScript(version, launchLog string) string {
	return fmt.Sprintf("#!/bin/sh\necho %s >> %q\npwd >> %q\nexec %q -test.run=TestHelperProcess -- \"$@\"\n", version, launchLog, launchLog+".cwd", os.Args[0])
}

func tarGz(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	archive := tar.NewWriter(gz)
	for _, name := range slices.Sorted(maps.Keys(files)) {
		if err := archive.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(files[name]))}); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write([]byte(files[name])); err != nil {
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

func fakeAgentArchive(t *testing.T, version, launchLog string) []byte {
	t.Helper()
	return tarGz(t, map[string]string{"bin/agent": fakeAgentScript(version, launchLog)})
}

// subscribeACP subscribes c to the list and returns the first snapshot.
func subscribeACP(t *testing.T, c *recordingClient) wire.ACPRegistryList {
	t.Helper()
	var list wire.ACPRegistryList
	c.call(t, wire.MethodACPRegistrySubscribeList, nil, &list)
	return list
}

func refreshACP(t *testing.T, c *recordingClient) wire.ACPRegistryList {
	t.Helper()
	var list wire.ACPRegistryList
	c.call(t, wire.MethodACPRegistryRefresh, nil, &list)
	return list
}

func acpRow(list wire.ACPRegistryList, id string) (wire.ACPRegistryAgent, bool) {
	i := slices.IndexFunc(list.Agents, func(agent wire.ACPRegistryAgent) bool { return agent.ID == id })
	if i < 0 {
		return wire.ACPRegistryAgent{}, false
	}
	return list.Agents[i], true
}

// waitACPRow waits until the latest notified list has a row matching done.
func (c *recordingClient) waitACPRow(t *testing.T, id, desc string, done func(wire.ACPRegistryAgent) bool) wire.ACPRegistryAgent {
	t.Helper()
	var found wire.ACPRegistryAgent
	c.waitFor(t, id+" to be "+desc, func() bool {
		if len(c.acpLists) == 0 {
			return false
		}
		row, ok := acpRow(c.acpLists[len(c.acpLists)-1], id)
		if ok && done(row) {
			found = row
			return true
		}
		return false
	})
	return found
}

func (c *recordingClient) waitACPState(t *testing.T, id string, state wire.ACPAgentState) wire.ACPRegistryAgent {
	t.Helper()
	return c.waitACPRow(t, id, string(state), func(row wire.ACPRegistryAgent) bool { return row.State == state })
}

func installACP(t *testing.T, c *recordingClient, id string) {
	t.Helper()
	c.call(t, wire.MethodACPRegistryInstall, wire.ACPRegistryInstallParams{RegistryID: id}, nil)
}

// installDirs lists what is on disk for an agent.
func installDirs(t *testing.T, dataDir, id string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(dataDir, "agents", "registry", id))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func trashEntries(t *testing.T, dataDir string) []fs.DirEntry {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(dataDir, "agents", "registry", acpTrashDir))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return entries
}

// Install is a job: the row says Installed only once it has finished, a second
// client joins it, and neither client needs the call to stay open.
func TestInstallIsOneJobThatEveryClientSees(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	work := t.TempDir()
	archive := hosts.put("downloads.test/agent.tar.gz", fakeAgentArchive(t, "1.0.0", filepath.Join(work, "launches")))
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", archive, ""))
	release := hosts.hold("downloads.test/agent.tar.gz")

	url := newWSTestServer(t, s)
	mac, phone := dialRecordingClient(t, url), dialRecordingClient(t, url)
	if list := subscribeACP(t, mac); len(list.Agents) != 0 {
		t.Fatalf("list before any refresh = %#v, want nothing yet", list)
	}
	subscribeACP(t, phone)
	row, ok := acpRow(refreshACP(t, mac), "qa")
	if !ok || row.State != wire.ACPAgentNotInstalled || row.AvailableVersion != "1.0.0" || row.LicenseURL != "https://example.test/license" {
		t.Fatalf("listed row = %#v", row)
	}

	// Both clicks at once, and neither call waits for the download.
	var clicks sync.WaitGroup
	for _, client := range []*recordingClient{mac, phone} {
		clicks.Go(func() { installACP(t, client, "qa") })
	}
	clicks.Wait()
	for _, client := range []*recordingClient{mac, phone} {
		client.waitACPState(t, "qa", wire.ACPAgentInstalling)
	}
	waitUntil(t, "the download to start", func() bool { return hosts.requested("downloads.test/agent.tar.gz") > 0 })
	if row, _ := acpRow(subscribeACP(t, phone), "qa"); row.InstalledVersion != "" || row.State != wire.ACPAgentInstalling {
		t.Fatalf("row during the install = %#v, want not installed yet", row)
	}
	if err := mac.callErr(wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, nil); err == nil {
		t.Fatal("started an agent still installing")
	}

	release()
	for _, client := range []*recordingClient{mac, phone} {
		row := client.waitACPState(t, "qa", wire.ACPAgentInstalled)
		if row.InstalledVersion != "1.0.0" || row.AvailableVersion != "" {
			t.Fatalf("installed row = %#v", row)
		}
	}
	if got := hosts.requested("downloads.test/agent.tar.gz"); got != 1 {
		t.Fatalf("downloads = %d, want one job", got)
	}
	if !providerListed(t, phone, "registry-qa") {
		t.Fatal("provider.list doesn't offer the installed agent")
	}

	// Installing what is installed changes nothing.
	installACP(t, phone, "qa")
	if got := hosts.requested("downloads.test/agent.tar.gz"); got != 1 {
		t.Fatalf("downloads after a second install = %d, want 1", got)
	}

	// The fake agent only starts with the registry's env, which proves launch
	// passes it.
	var info provider.InstanceInfo
	mac.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, &info)
	if info.Status != provider.InstanceStatusInitialized {
		t.Fatalf("started = %#v", info)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	// It stays installed across a restart, without the index.
	restarted := newRecordingClient(t, newTestServerAt(t, dataDir))
	if row, _ := acpRow(subscribeACP(t, restarted), "qa"); row.State != wire.ACPAgentInstalled || row.InstalledVersion != "1.0.0" {
		t.Fatalf("row after restart = %#v", row)
	}
}

func TestWrongChecksumIsRefusedAndRetryWorks(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	body := fakeAgentArchive(t, "1.0.0", filepath.Join(t.TempDir(), "launches"))
	archive := hosts.put("downloads.test/agent.tar.gz", body)
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", archive, strings.Repeat("0", 64)))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)

	installACP(t, client, "qa")
	row := client.waitACPState(t, "qa", wire.ACPAgentFailed)
	if !strings.Contains(row.Error, "sha256 mismatch") || row.InstalledVersion != "" {
		t.Fatalf("failed row = %#v", row)
	}
	waitUntil(t, "the refused download to be deleted", func() bool {
		return len(installDirs(t, dataDir, "qa")) == 0 && len(trashEntries(t, dataDir)) == 0
	})
	if err := client.callErr(wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, nil); err == nil {
		t.Fatal("started an agent whose download was refused")
	}

	// The registry corrects its hash; the row's Retry is the same call.
	sum := sha256.Sum256(body)
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", archive, hex.EncodeToString(sum[:])))
	refreshACP(t, client)
	installACP(t, client, "qa")
	if row := client.waitACPState(t, "qa", wire.ACPAgentInstalled); row.Error != "" || row.InstalledVersion != "1.0.0" {
		t.Fatalf("row after retry = %#v", row)
	}
}

// A github.com download without a hash in the index is checked against the
// digest GitHub recorded for it.
func TestGitHubDigestIsCheckedWhenTheIndexHasNoHash(t *testing.T) {
	s := newTestServer(t)
	hosts := serveFakeACPHosts(t, s)
	body := fakeAgentArchive(t, "1.0.0", filepath.Join(t.TempDir(), "launches"))
	archive := hosts.put("github.com/o/r/releases/download/v1.0.0/agent.tar.gz", body)
	release := func(digest string) {
		hosts.put("api.github.com/repos/o/r/releases/tags/v1.0.0", fmt.Appendf(nil, `{"assets":[{"name":"agent.tar.gz","digest":"sha256:%s"}]}`, digest))
	}
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", archive, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)

	release(strings.Repeat("0", 64))
	installACP(t, client, "qa")
	if row := client.waitACPState(t, "qa", wire.ACPAgentFailed); !strings.Contains(row.Error, "sha256 mismatch") {
		t.Fatalf("failed row = %#v", row)
	}

	sum := sha256.Sum256(body)
	release(hex.EncodeToString(sum[:]))
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
}

// Every format the registry's schema allows ends up runnable, and an archive
// can't write outside the agent's directory.
func TestArchiveFormats(t *testing.T) {
	work := t.TempDir()
	script := fakeAgentScript("1.0.0", filepath.Join(work, "launches"))
	zipped := func(t *testing.T) []byte {
		var out bytes.Buffer
		archive := zip.NewWriter(&out)
		header := &zip.FileHeader{Name: "real/agent", Method: zip.Deflate}
		header.SetMode(0o755)
		file, err := archive.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write([]byte(script)); err != nil {
			t.Fatal(err)
		}
		link := &zip.FileHeader{Name: "bin/agent"}
		link.SetMode(fs.ModeSymlink | 0o777)
		file, err = archive.CreateHeader(link)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write([]byte("../real/agent")); err != nil {
			t.Fatal(err)
		}
		if err := archive.Close(); err != nil {
			t.Fatal(err)
		}
		return out.Bytes()
	}
	bzipped := func(t *testing.T) []byte {
		if _, err := exec.LookPath("bzip2"); err != nil {
			t.Skip("bzip2 isn't installed")
		}
		var plain bytes.Buffer
		archive := tar.NewWriter(&plain)
		if err := archive.WriteHeader(&tar.Header{Name: "./bin/agent", Mode: 0o755, Size: int64(len(script))}); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write([]byte(script)); err != nil {
			t.Fatal(err)
		}
		if err := archive.Close(); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("bzip2", "-c")
		cmd.Stdin = &plain
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	tarWith := func(t *testing.T, headers ...tar.Header) []byte {
		var out bytes.Buffer
		gz := gzip.NewWriter(&out)
		archive := tar.NewWriter(gz)
		for _, header := range headers {
			body := []byte("x")
			if header.Typeflag == tar.TypeReg {
				header.Size = int64(len(body))
			}
			if err := archive.WriteHeader(&header); err != nil {
				t.Fatal(err)
			}
			if header.Typeflag == tar.TypeReg {
				if _, err := archive.Write(body); err != nil {
					t.Fatal(err)
				}
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

	for _, test := range []struct {
		name, file string
		body       func(t *testing.T) []byte
		command    string
		wantErr    string
	}{
		{name: "zip with a symlink", file: "agent.zip", body: zipped, command: "./bin/agent"},
		{name: "tar.gz", file: "agent.tar.gz", body: func(t *testing.T) []byte { return tarGz(t, map[string]string{"bin/agent": script}) }, command: "./bin/agent"},
		{name: "tgz", file: "agent.tgz", body: func(t *testing.T) []byte { return tarGz(t, map[string]string{"bin/agent": script}) }, command: "./bin/agent"},
		{name: "tar.bz2", file: "agent.tar.bz2", body: bzipped, command: "./bin/agent"},
		{name: "raw binary", file: "agent", body: func(*testing.T) []byte { return []byte(script) }, command: "./agent"},
		{name: "unsupported format", file: "agent.tar.xz", body: func(*testing.T) []byte { return []byte("x") }, command: "./agent", wantErr: "can't unpack"},
		{name: "corrupt archive", file: "agent.tar.gz", body: func(*testing.T) []byte { return []byte("x") }, command: "./agent", wantErr: "unpack"},
		{name: "missing command", file: "agent.tar.gz", body: func(t *testing.T) []byte { return tarGz(t, map[string]string{"other": "x"}) }, command: "./agent", wantErr: "has no ./agent"},
		{name: "command outside", file: "agent.tar.gz", body: func(t *testing.T) []byte { return tarGz(t, map[string]string{"other": "x"}) }, command: "../../other", wantErr: "outside"},
		{
			name: "entry outside", file: "agent.tar.gz", command: "./agent", wantErr: "../escaped",
			body: func(t *testing.T) []byte {
				return tarWith(t, tar.Header{Name: "../escaped", Typeflag: tar.TypeReg, Mode: 0o644})
			},
		},
		{
			name: "write through a link", file: "agent.tar.gz", command: "./agent", wantErr: "out/escaped",
			body: func(t *testing.T) []byte {
				return tarWith(t,
					tar.Header{Name: "out", Typeflag: tar.TypeSymlink, Linkname: work},
					tar.Header{Name: "out/escaped", Typeflag: tar.TypeReg, Mode: 0o644},
				)
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := newTestServer(t)
			hosts := serveFakeACPHosts(t, s)
			archive := hosts.put("downloads.test/"+test.file, test.body(t))
			target, _ := json.Marshal(map[string]any{"archive": archive, "cmd": test.command, "env": map[string]string{"MAID_DAEMON_ACP_HELPER": "1"}})
			hosts.setIndex(fmt.Sprintf(`{"id":"qa","name":"QA","version":"1.0.0","distribution":{"binary":{%q:%s}}}`, acpPlatform(), target))
			client := newRecordingClient(t, s)
			subscribeACP(t, client)
			refreshACP(t, client)
			installACP(t, client, "qa")

			if test.wantErr != "" {
				if row := client.waitACPState(t, "qa", wire.ACPAgentFailed); !strings.Contains(row.Error, test.wantErr) {
					t.Fatalf("error = %q, want it to contain %q", row.Error, test.wantErr)
				}
				if _, err := os.Stat(filepath.Join(work, "escaped")); !os.IsNotExist(err) {
					t.Fatalf("an archive wrote outside its directory: stat err = %v", err)
				}
				return
			}
			client.waitACPState(t, "qa", wire.ACPAgentInstalled)
			client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, nil)
		})
	}
}

// An update builds beside the old version and doesn't touch a running turn.
// The agent then moves over, and the old version's files go.
func TestUpdateWaitsForTheTurnThenReplacesTheOldVersion(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	work := t.TempDir()
	launches := filepath.Join(work, "launches")
	v1 := hosts.put("downloads.test/v1.tar.gz", fakeAgentArchive(t, "1.0.0", launches))
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", v1, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
	var info provider.InstanceInfo
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa", Cwd: client.addProject(t, work)}, &info)
	thread := client.createThread(t, info.InstanceID, work).Thread
	client.subscribe(t, thread)
	blocked := client.deliver(t, thread, "block "+work).Delivery
	waitForFile(t, filepath.Join(work, "ready"))
	oldDirs := installDirs(t, dataDir, "qa")

	v2 := hosts.put("downloads.test/v2.tar.gz", fakeAgentArchive(t, "2.0.0", launches))
	hosts.setIndex(fakeBinaryAgent("qa", "2.0.0", v2, ""))
	if row, _ := acpRow(refreshACP(t, client), "qa"); row.InstalledVersion != "1.0.0" || row.AvailableVersion != "2.0.0" || row.State != wire.ACPAgentInstalled {
		t.Fatalf("row with an update = %#v", row)
	}
	release := hosts.hold("downloads.test/v2.tar.gz")
	installACP(t, client, "qa")
	if row := client.waitACPState(t, "qa", wire.ACPAgentUpdating); row.InstalledVersion != "1.0.0" {
		t.Fatalf("updating row = %#v, want the old version until it finishes", row)
	}
	release()
	if row := client.waitACPState(t, "qa", wire.ACPAgentInstalled); row.InstalledVersion != "2.0.0" || row.AvailableVersion != "" {
		t.Fatalf("updated row = %#v", row)
	}

	// The turn runs on, on the old process, whose files are still there.
	if turns := client.subscribe(t, thread).Turns; len(turns) != 1 || turns[0].State != provider.TurnRunning {
		t.Fatalf("turn after the update = %#v", turns)
	}
	if current, _ := s.providerService.Info(info.InstanceID); current.PID != info.PID {
		t.Fatalf("pid = %d, want %d: the update replaced the running agent", current.PID, info.PID)
	}
	if dirs := installDirs(t, dataDir, "qa"); !slices.Contains(dirs, oldDirs[0]) || len(dirs) != 2 {
		t.Fatalf("install dirs during the turn = %v, want the old one %v and the new", dirs, oldDirs)
	}
	if err := os.WriteFile(filepath.Join(work, "release"), []byte("finish"), 0o600); err != nil {
		t.Fatal(err)
	}
	if turn := client.waitSettled(t, thread, blocked); turn.State != provider.TurnCompleted {
		t.Fatalf("turn = %s, want completed", turn.State)
	}

	waitUntil(t, "the new version to run and the old one's files to go", func() bool {
		raw, _ := os.ReadFile(launches)
		dirs := installDirs(t, dataDir, "qa")
		return string(raw) == "1.0.0\n2.0.0\n" && len(dirs) == 1 && dirs[0] != oldDirs[0] && len(trashEntries(t, dataDir)) == 0
	})
	if turn := client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn on the new version = %s, want completed", turn.State)
	}
}

func TestFailedUpdateKeepsTheOldVersionWorking(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	work := t.TempDir()
	launches := filepath.Join(work, "launches")
	v1 := hosts.put("downloads.test/v1.tar.gz", fakeAgentArchive(t, "1.0.0", launches))
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", v1, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
	kept := installDirs(t, dataDir, "qa")

	hosts.setIndex(fakeBinaryAgent("qa", "2.0.0", "https://downloads.test/missing.tar.gz", ""))
	refreshACP(t, client)
	installACP(t, client, "qa")
	row := client.waitACPState(t, "qa", wire.ACPAgentFailed)
	if !strings.Contains(row.Error, "404") || row.InstalledVersion != "1.0.0" || row.AvailableVersion != "2.0.0" {
		t.Fatalf("row after a failed update = %#v", row)
	}
	waitUntil(t, "the failed version's files to go", func() bool { return slices.Equal(installDirs(t, dataDir, "qa"), kept) })

	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, nil)
	if raw, err := os.ReadFile(launches); err != nil || string(raw) != "1.0.0\n" {
		t.Fatalf("launches = %q, %v, want the old version", raw, err)
	}
}

// Remove deletes every version, ends an install in progress, and frees the
// agent to be installed again. It leaves another agent's files alone.
func TestRemoveDeletesEveryVersionAndEndsAnInstall(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	launches := filepath.Join(t.TempDir(), "launches")
	archive := hosts.put("downloads.test/agent.tar.gz", fakeAgentArchive(t, "1.0.0", launches))
	hosts.setIndex(fakeBinaryAgent("drop", "1.0.0", archive, ""), fakeBinaryAgent("keep", "1.0.0", archive, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	for _, id := range []string{"drop", "keep"} {
		installACP(t, client, id)
		client.waitACPState(t, id, wire.ACPAgentInstalled)
	}
	kept := installDirs(t, dataDir, "keep")
	stale := filepath.Join(dataDir, "agents", "registry", "drop", "0.9.0-old", "file")
	if err := os.MkdirAll(filepath.Dir(stale), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stale, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: "drop"}, nil)
	if row := client.waitACPState(t, "drop", wire.ACPAgentNotInstalled); row.InstalledVersion != "" || row.AvailableVersion != "1.0.0" {
		t.Fatalf("removed row = %#v", row)
	}
	// Gone from its place by the time the call returns; deleted in the background.
	if dirs := installDirs(t, dataDir, "drop"); len(dirs) != 0 {
		t.Fatalf("removed agent's dirs = %v", dirs)
	}
	waitUntil(t, "the trash to empty", func() bool { return len(trashEntries(t, dataDir)) == 0 })
	if dirs := installDirs(t, dataDir, "keep"); !slices.Equal(dirs, kept) {
		t.Fatalf("other agent's dirs = %v, want %v", dirs, kept)
	}
	if providerListed(t, client, "registry-drop") {
		t.Fatal("provider.list still offers the removed agent")
	}

	// A removal during an install ends the job, and that isn't a failure.
	release := hosts.hold("downloads.test/agent.tar.gz")
	installACP(t, client, "drop")
	client.waitACPState(t, "drop", wire.ACPAgentInstalling)
	client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: "drop"}, nil)
	if row := client.waitACPState(t, "drop", wire.ACPAgentNotInstalled); row.Error != "" {
		t.Fatalf("row after the install was ended = %#v", row)
	}
	client.mu.Lock()
	for _, list := range client.acpLists {
		if row, ok := acpRow(list, "drop"); ok && row.State == wire.ACPAgentFailed {
			client.mu.Unlock()
			t.Fatalf("ending an install showed as a failure: %#v", row)
		}
	}
	client.mu.Unlock()
	waitUntil(t, "the ended install's files to go", func() bool {
		_, err := os.Stat(filepath.Join(dataDir, "agents", "registry", "drop"))
		return os.IsNotExist(err) && len(trashEntries(t, dataDir)) == 0
	})
	release()

	// It can be installed again, on the same instance its chats name.
	installACP(t, client, "drop")
	if row := client.waitACPState(t, "drop", wire.ACPAgentInstalled); row.InstanceID != "registry-drop" {
		t.Fatalf("reinstalled row = %#v", row)
	}

	// A client's id can't name a path: not the agents' parent, where the manifest
	// lives, and not another agent by a way round.
	reinstalled := installDirs(t, dataDir, "drop")
	for _, hostile := range []string{"..", "keep/../drop", "../registry/keep"} {
		client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: hostile}, nil)
	}
	if dirs := installDirs(t, dataDir, "keep"); !slices.Equal(dirs, kept) {
		t.Fatalf("other agent's dirs after hostile removals = %v, want %v", dirs, kept)
	}
	if dirs := installDirs(t, dataDir, "drop"); !slices.Equal(dirs, reinstalled) {
		t.Fatalf("installed agent's dirs after hostile removals = %v, want %v", dirs, reinstalled)
	}
	if _, err := os.Stat(s.acpRegistry.installedManifestPath()); err != nil {
		t.Fatalf("manifest after hostile removals: %v", err)
	}
}

// A daemon that died mid-install or mid-delete leaves directories nothing refers
// to. The next start deletes them, keeps what the manifest lists, and shows
// nothing as installed that wasn't committed.
func TestStartupDeletesWhatNothingRefersTo(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "agents", "registry")
	leftovers := []string{
		"gone/1.0.0-a/file",             // an agent no longer in the manifest
		"listed/1.0.0-interrupted/file", // the listed agent's interrupted update
		acpTrashDir + "/XYZ/file",       // an interrupted delete
	}
	for _, leftover := range append(slices.Clone(leftovers), "listed/1.0.0-kept/file") {
		path := filepath.Join(root, leftover)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	manifest := `[{"id":"listed","instanceId":"registry-listed","name":"Listed","source":"registry","version":"1.0.0","dir":"1.0.0-kept","command":"agent"}]`
	if err := os.WriteFile(filepath.Join(dir, "agents", "installed.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	client := newRecordingClient(t, newTestServerAt(t, dir))
	list := subscribeACP(t, client)
	if len(list.Agents) != 1 || list.Agents[0].ID != "listed" || list.Agents[0].State != wire.ACPAgentInstalled {
		t.Fatalf("list = %#v, want only the committed agent", list)
	}
	waitUntil(t, "the leftovers to be deleted", func() bool {
		for _, leftover := range leftovers {
			if _, err := os.Stat(filepath.Join(root, leftover)); !os.IsNotExist(err) {
				return false
			}
		}
		return len(trashEntries(t, dir)) == 0
	})
	if _, err := os.Stat(filepath.Join(root, "listed", "1.0.0-kept", "file")); err != nil {
		t.Fatalf("listed agent's files: %v", err)
	}
}

// fakeTool writes a script for the caller to put on PATH.
func fakeTool(t *testing.T, dir, tool, script string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, tool), []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// npm's whole process group dies with the daemon, install scripts included, and
// the next start finds nothing installed.
func TestShutdownKillsARunningInstallAndTheNextStartCleansUp(t *testing.T) {
	dataDir, tools, work := t.TempDir(), t.TempDir(), t.TempDir()
	pidfile := filepath.Join(work, "pid")
	fakeTool(t, tools, "node", "exit 0\n")
	// npm's install script: a child of npm that outlives its parent's signal.
	fakeTool(t, tools, "npm", fmt.Sprintf("sleep 600 &\necho $! > %q\nwait\n", pidfile))
	t.Setenv("PATH", tools+string(os.PathListSeparator)+"/usr/bin:/bin")

	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	hosts.setIndex(`{"id":"qa","name":"QA","version":"1.0.0","distribution":{"npx":{"package":"qa-agent@1.0.0"}}}`)
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	installACP(t, client, "qa")
	waitForFile(t, pidfile)
	waitUntil(t, "the pid to be written", func() bool {
		raw, _ := os.ReadFile(pidfile)
		return strings.TrimSpace(string(raw)) != ""
	})
	pid := readPIDTrimmed(t, pidfile)

	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	// Close waits for the job, so the group is already signaled; the kernel may
	// take a moment to reap the orphan.
	waitUntil(t, "npm's child to die", func() bool { return syscall.Kill(pid, 0) != nil })
	if dirs := installDirs(t, dataDir, "qa"); len(dirs) > 1 {
		t.Fatalf("install dirs = %v", dirs)
	}

	restarted := newRecordingClient(t, newTestServerAt(t, dataDir))
	if list := subscribeACP(t, restarted); len(list.Agents) != 0 {
		t.Fatalf("list after restart = %#v, want nothing installed", list)
	}
	waitUntil(t, "the leftovers to be deleted", func() bool {
		return len(installDirs(t, dataDir, "qa")) == 0 && len(trashEntries(t, dataDir)) == 0
	})
}

func readPIDTrimmed(t *testing.T, path string) int {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var pid int
	if _, err := fmt.Sscan(string(raw), &pid); err != nil {
		t.Fatalf("pid in %q: %v", raw, err)
	}
	return pid
}

// npm and uv run with the daemon's environment only: the registry's reaches the
// agent's launch, where it can't redirect what gets installed. Launch needs
// neither tool.
func TestPackageManagersNeverSeeTheRegistryEnvAndLaunchWithoutThem(t *testing.T) {
	for _, test := range []struct {
		name, tool, distribution, wantRequest string
		fakeInstall                           string
	}{
		{
			name: "npm", tool: "npm",
			distribution: `"npx":{"package":"@scope/qa-agent@9.9.9","args":["-pidfile","PIDFILE"],"env":{"MAID_DAEMON_ACP_HELPER":"1","npm_config_registry":"https://evil.test"}}`,
			wantRequest:  "@scope/qa-agent@1.0.0",
			fakeInstall: `mkdir -p node_modules/@scope/qa-agent
printf '{"version":"1.0.0","bin":{"qa-agent":"run.sh"}}' > node_modules/@scope/qa-agent/package.json
cp "$AGENT_SCRIPT" node_modules/@scope/qa-agent/run.sh
chmod +x node_modules/@scope/qa-agent/run.sh
`,
		},
		{
			name: "uv", tool: "uv",
			distribution: `"uvx":{"package":"qa-agent==9.9.9","args":["-pidfile","PIDFILE"],"env":{"MAID_DAEMON_ACP_HELPER":"1","npm_config_registry":"https://evil.test"}}`,
			wantRequest:  "qa-agent==1.0.0",
			fakeInstall: `mkdir -p "$UV_TOOL_BIN_DIR"
cp "$AGENT_SCRIPT" "$UV_TOOL_BIN_DIR/qa-agent"
chmod +x "$UV_TOOL_BIN_DIR/qa-agent"
`,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			tools, work := t.TempDir(), t.TempDir()
			agentScript := filepath.Join(work, "agent.sh")
			launches, record := filepath.Join(work, "launches"), filepath.Join(work, "tool-saw")
			if err := os.WriteFile(agentScript, []byte(fakeAgentScript("1.0.0", launches)), 0o755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("AGENT_SCRIPT", agentScript)
			fakeTool(t, tools, "node", "exec \"$@\"\n")
			fakeTool(t, tools, test.tool, fmt.Sprintf("{ echo \"$@\"; env; } > %q\n%s", record, test.fakeInstall))
			t.Setenv("PATH", tools+string(os.PathListSeparator)+"/usr/bin:/bin")

			s := newTestServer(t)
			hosts := serveFakeACPHosts(t, s)
			pidfile := filepath.Join(work, "pid")
			hosts.setIndex(`{"id":"qa","name":"QA","version":"1.0.0","distribution":{` + strings.ReplaceAll(test.distribution, "PIDFILE", pidfile) + `}}`)
			client := newRecordingClient(t, s)
			subscribeACP(t, client)
			refreshACP(t, client)
			installACP(t, client, "qa")
			if row := client.waitACPState(t, "qa", wire.ACPAgentInstalled); row.InstalledVersion != "1.0.0" {
				t.Fatalf("row = %#v", row)
			}
			saw, err := os.ReadFile(record)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(saw), test.wantRequest) {
				t.Fatalf("%s saw %q, want the exact listed version %q", test.tool, saw, test.wantRequest)
			}
			if strings.Contains(string(saw), "evil.test") || strings.Contains(string(saw), "MAID_DAEMON_ACP_HELPER") {
				t.Fatalf("%s saw the registry's env: %q", test.tool, saw)
			}

			// A tool taken away afterwards doesn't matter to a launch.
			if err := os.Remove(filepath.Join(tools, test.tool)); err != nil {
				t.Fatal(err)
			}
			var info provider.InstanceInfo
			client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, &info)
			if info.Status != provider.InstanceStatusInitialized {
				t.Fatalf("started = %#v", info)
			}
			// The index's args reached the agent: only they name this file.
			waitForFile(t, pidfile)
		})
	}
}

// Every agent in the index gets a row, and a row says what stops it installing.
func TestRowsSayWhatStopsAnInstall(t *testing.T) {
	tools := t.TempDir()
	t.Setenv("PATH", tools)
	s := newTestServer(t)
	hosts := serveFakeACPHosts(t, s)
	hosts.setIndex(
		`{"id":"elsewhere","name":"Elsewhere","version":"1","distribution":{"binary":{"plan9-mips":{"archive":"https://x.test/a.zip","cmd":"./a"}}}}`,
		`{"id":"needs-node","name":"Needs Node","version":"1","distribution":{"npx":{"package":"a@1"}}}`,
		`{"id":"needs-uv","name":"Needs uv","version":"1","distribution":{"uvx":{"package":"a==1"}}}`,
		fmt.Sprintf(`{"id":"both","name":"Both","version":"1","distribution":{"npx":{"package":"a@1"},"binary":{%q:{"archive":"https://x.test/a.zip","cmd":"./a"}}}}`, acpPlatform()),
	)
	client := newRecordingClient(t, s)
	list := refreshACP(t, client)
	for id, want := range map[string]wire.ACPAgentBlocker{
		"elsewhere":  wire.ACPAgentNeedsPlatform,
		"needs-node": wire.ACPAgentNeedsNode,
		"needs-uv":   wire.ACPAgentNeedsUV,
		"both":       "",
	} {
		row, ok := acpRow(list, id)
		if !ok || row.Blocker != want {
			t.Fatalf("row %s = %#v, want blocker %q", id, row, want)
		}
		if want != "" {
			if err := client.callErr(wire.MethodACPRegistryInstall, wire.ACPRegistryInstallParams{RegistryID: id}, nil); err == nil {
				t.Fatalf("installed %s despite %s", id, want)
			}
		}
	}

	// A tool that appears is seen at the next refresh.
	fakeTool(t, tools, "uv", "exit 0\n")
	if row, _ := acpRow(refreshACP(t, client), "needs-uv"); row.Blocker != "" {
		t.Fatalf("row after uv appeared = %#v", row)
	}
}

// An update shows when it came out, from the source that published it, and only
// installed agents with an update cost a lookup.
func TestReleaseDatesOfAvailableUpdates(t *testing.T) {
	dir := t.TempDir()
	manifest := []map[string]any{}
	for _, id := range []string{"from-npm", "from-pypi", "from-github", "from-vendor", "failing", "same"} {
		manifest = append(manifest, map[string]any{"id": id, "instanceId": "registry-" + id, "name": id, "source": "registry", "version": "1.0.0", "dir": "d", "command": "c"})
	}
	raw, _ := json.Marshal(manifest)
	if err := os.MkdirAll(filepath.Join(dir, "agents"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "agents", "installed.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir())
	s := newTestServerAt(t, dir)
	hosts := serveFakeACPHosts(t, s)
	binary := func(id, archive string) string {
		return fmt.Sprintf(`{"id":%q,"name":%q,"version":"2.0.0","distribution":{"binary":{%q:{"archive":%q,"cmd":"./a"}}}}`, id, id, acpPlatform(), archive)
	}
	hosts.setIndex(
		`{"id":"from-npm","name":"from-npm","version":"2.0.0","distribution":{"npx":{"package":"@s/n@2.0.0"}}}`,
		`{"id":"from-pypi","name":"from-pypi","version":"2.0.0","distribution":{"uvx":{"package":"p==2.0.0"}}}`,
		binary("from-github", "https://github.com/o/r/releases/download/v2.0.0/a.zip"),
		binary("from-vendor", "https://vendor.test/a.zip"),
		binary("failing", "https://github.com/o/gone/releases/download/v2.0.0/a.zip"),
		binary("same", "https://vendor.test/same.zip"),
		binary("not-installed", "https://github.com/o/uninstalled/releases/download/v2.0.0/a.zip"),
	)
	hosts.put("registry.npmjs.org/@s/n", []byte(`{"time":{"1.0.0":"2026-01-01T00:00:00.000Z","2.0.0":"2026-02-03T04:05:06.789Z"}}`))
	hosts.put("pypi.org/pypi/p/2.0.0/json", []byte(`{"urls":[{"upload_time_iso_8601":"2026-03-04T05:06:07.123456Z"}]}`))
	hosts.put("api.github.com/repos/o/r/releases/tags/v2.0.0", []byte(`{"published_at":"2026-04-05T06:07:08Z"}`))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)

	for id, want := range map[string]string{
		"from-npm":    "2026-02-03T04:05:06.789Z",
		"from-pypi":   "2026-03-04T05:06:07.123456Z",
		"from-github": "2026-04-05T06:07:08Z",
	} {
		row := client.waitACPRow(t, id, "dated", func(row wire.ACPRegistryAgent) bool { return row.AvailableReleasedAt != nil })
		wantTime, err := time.Parse(time.RFC3339Nano, want)
		if err != nil {
			t.Fatal(err)
		}
		if !row.AvailableReleasedAt.Equal(wantTime) {
			t.Fatalf("%s released at %v, want %v", id, row.AvailableReleasedAt, wantTime)
		}
	}
	var list wire.ACPRegistryList
	client.call(t, wire.MethodACPRegistrySubscribeList, nil, &list)
	for _, id := range []string{"from-vendor", "failing", "not-installed"} {
		if row, _ := acpRow(list, id); row.AvailableReleasedAt != nil {
			t.Fatalf("%s has a date: %#v", id, row)
		}
	}
	if got := hosts.requested("api.github.com/repos/o/uninstalled/releases/tags/v2.0.0"); got != 0 {
		t.Fatalf("looked up an agent that isn't installed %d times", got)
	}
}

// A chat outlives its agent's removal. While the agent is installing again its
// messages are refused, and once installed the chat goes on.
func TestAChatOnAnAgentInstallingAgainStaysRefusedUntilInstalled(t *testing.T) {
	s := newTestServer(t)
	hosts := serveFakeACPHosts(t, s)
	work := t.TempDir()
	archive := hosts.put("downloads.test/agent.tar.gz", fakeAgentArchive(t, "1.0.0", filepath.Join(work, "launches")))
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", archive, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
	thread := client.createThread(t, "registry-qa", work).Thread
	client.subscribe(t, thread)
	if turn := client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("first turn = %s", turn.State)
	}
	client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: "qa"}, nil)

	release := hosts.hold("downloads.test/agent.tar.gz")
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalling)
	refused := client.deliver(t, thread, "too soon").Delivery
	client.waitEvent(t, "the message to be refused", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventDelivery && event.Delivery.ID == refused && event.Delivery.State == orchestration.DeliveryRefused
	})
	release()
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
	if turn := client.waitSettled(t, thread, client.deliver(t, thread, "hello again").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn after reinstalling = %s", turn.State)
	}
}
