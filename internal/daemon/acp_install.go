package daemon

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/bzip2"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/adapters/procgroup"
)

const (
	// acpInstallerTimeout bounds one npm or uv run. Their own network timeouts
	// don't cover a postinstall script that hangs.
	acpInstallerTimeout = 10 * time.Minute
	// acpDownloadStallTimeout ends a download that stopped: big archives outlast
	// any whole-request deadline on a slow link.
	acpDownloadStallTimeout = 60 * time.Second
)

// acpDistribution is one way an agent version reaches the disk.
type acpDistribution interface {
	// install puts the agent into dir, which is empty, and says how to run it.
	install(ctx context.Context, r *acpRegistry, dir string) (acpEntry, error)
	// blocker says what the daemon's machine lacks to install it.
	blocker() wire.ACPAgentBlocker
	// releasedAt looks up when this version came out; zero when nobody says.
	releasedAt(ctx context.Context, r *acpRegistry) (time.Time, error)
}

// acpEntry is an installed agent's executable, relative to its directory.
type acpEntry struct {
	path string
	node bool
}

// acpInstallJob is the one install or update running on an agent.
type acpInstallJob struct {
	agent    acpRegistryAgent
	updating bool
	dir      string
	ctx      context.Context
	cancel   context.CancelFunc
	// done closes after the job's result is published.
	done chan struct{}
}

// startInstall begins a job bringing the agent to the listed version. It
// returns nil when there is nothing to start: a job is already running, which
// the caller joins, or the version is already installed.
func (r *acpRegistry) startInstall(ctx context.Context, id string) (*acpInstallJob, error) {
	agent, err := r.registryAgent(ctx, id)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.ctx.Err(); err != nil {
		return nil, fmt.Errorf("the daemon is shutting down: %w", err)
	}
	if err := r.loadInstalledLocked(); err != nil {
		return nil, err
	}
	if _, running := r.jobs[agent.ID]; running {
		return nil, nil
	}
	current := slices.IndexFunc(r.installed, func(installed acpInstalledAgent) bool { return installed.ID == agent.ID })
	if current >= 0 && r.installed[current].Version == agent.Version {
		if _, failed := r.failures[agent.ID]; failed {
			delete(r.failures, agent.ID)
			r.publishLocked()
		}
		return nil, nil
	}
	switch agent.Blocker {
	case "":
	case wire.ACPAgentNeedsPlatform:
		return nil, fmt.Errorf("%s has no build for this platform", agent.Name)
	case wire.ACPAgentNeedsNode:
		return nil, fmt.Errorf("%s needs Node.js, which the daemon can't find", agent.Name)
	case wire.ACPAgentNeedsUV:
		return nil, fmt.Errorf("%s needs uv, which the daemon can't find", agent.Name)
	}
	// Each job gets a directory of its own and nothing ever moves it: uv's
	// scripts and some npm packages' postinstall output hold absolute paths, and
	// a version being installed again may still be running from the old one.
	if err := os.MkdirAll(r.agentDir(agent.ID), 0o755); err != nil {
		return nil, fmt.Errorf("create agent directory: %w", err)
	}
	dir, err := os.MkdirTemp(r.agentDir(agent.ID), agent.Version+"-*")
	if err != nil {
		return nil, fmt.Errorf("create agent directory: %w", err)
	}
	jobCtx, cancel := context.WithCancel(r.ctx)
	job := &acpInstallJob{agent: agent, updating: current >= 0, dir: dir, ctx: jobCtx, cancel: cancel, done: make(chan struct{})}
	r.jobs[agent.ID] = job
	delete(r.failures, agent.ID)
	r.publishLocked()
	return job, nil
}

// build installs the job's agent and commits it to the manifest, which is what
// makes it installed: a daemon that dies before this leaves only a directory
// nothing refers to, which the next start deletes.
func (r *acpRegistry) build(job *acpInstallJob) (acpInstalledAgent, error) {
	agent := job.agent
	entry, err := agent.Distribution.install(job.ctx, r, job.dir)
	if err != nil {
		return acpInstalledAgent{}, err
	}
	record := acpInstalledAgent{
		ID: agent.ID, InstanceID: agent.instanceID(), Name: agent.Name, Source: wire.ACPAgentSourceRegistry, Version: agent.Version,
		Description: agent.Description, Icon: agent.Icon, Repository: agent.Repository, Website: agent.Website, LicenseURL: agent.License,
		Dir: filepath.Base(job.dir), Node: entry.node, Command: entry.path, Args: agent.Args, Env: agent.Env,
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := job.ctx.Err(); err != nil {
		return acpInstalledAgent{}, err
	}
	if err := r.loadInstalledLocked(); err != nil {
		return acpInstalledAgent{}, err
	}
	if err := r.saveInstalledLocked(upsertInstalledAgent(slices.Clone(r.installed), record)); err != nil {
		return acpInstalledAgent{}, err
	}
	return record, nil
}

// finish ends the job and tells clients. A canceled job isn't a failure: its
// agent is being removed or the daemon is stopping.
func (r *acpRegistry) finish(job *acpInstallJob, jobErr error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.jobs, job.agent.ID)
	if jobErr != nil {
		if job.ctx.Err() == nil {
			r.failures[job.agent.ID] = jobErr.Error()
		}
		if err := r.discardLocked(job.dir); err != nil {
			r.logger.Warn("delete failed install", "agent", job.agent.ID, "error", err)
		}
		// Fails while a version remains, which is the point.
		_ = os.Remove(r.agentDir(job.agent.ID))
	}
	r.publishLocked()
	job.cancel()
	close(job.done)
}

// waitForJobs waits for the jobs the daemon's shutdown canceled.
func (r *acpRegistry) waitForJobs() {
	r.mu.Lock()
	jobs := make([]*acpInstallJob, 0, len(r.jobs))
	for _, job := range r.jobs {
		jobs = append(jobs, job)
	}
	r.mu.Unlock()
	for _, job := range jobs {
		<-job.done
	}
}

// acpPlatform is the registry's name for the daemon's platform.
func acpPlatform() string {
	arch := runtime.GOARCH
	switch arch {
	case "arm64":
		arch = "aarch64"
	case "amd64":
		arch = "x86_64"
	}
	return runtime.GOOS + "-" + arch
}

// runInstaller runs npm or uv in dir. Canceling ctx kills its whole process
// group, install scripts included, so a stopping daemon doesn't wait for them.
func runInstaller(ctx context.Context, dir string, env []string, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, acpInstallerTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir, cmd.Env = dir, append(os.Environ(), env...)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	procgroup.Configure(cmd)
	cmd.Cancel = func() error {
		procgroup.Kill(cmd)
		return nil
	}
	// An install script that left something running holds the output pipe open.
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	procgroup.Kill(cmd)
	if err == nil || errors.Is(err, exec.ErrWaitDelay) {
		return nil
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return fmt.Errorf("%s stopped: %w", name, ctxErr)
	}
	// The cause comes last in what npm and uv print.
	const tail = 1200
	text := strings.TrimSpace(output.String())
	if len(text) > tail {
		text = "…" + strings.ToValidUTF8(text[len(text)-tail:], "")
	}
	if text == "" {
		return fmt.Errorf("%s install failed: %w", name, err)
	}
	return fmt.Errorf("%s install failed: %s", name, text)
}

// acpNPMPackage is an npm package at an exact version.
type acpNPMPackage struct {
	name, version string
}

func parseNPMPackage(index *acpIndexPackage, version string) *acpNPMPackage {
	if index == nil {
		return nil
	}
	name := index.Package
	if at := strings.LastIndex(name, "@"); at > 0 {
		name = name[:at]
	}
	if name == "" || strings.HasPrefix(name, "-") {
		return nil
	}
	return &acpNPMPackage{name: name, version: version}
}

func (p *acpNPMPackage) blocker() wire.ACPAgentBlocker {
	for _, tool := range []string{"node", "npm"} {
		if _, err := exec.LookPath(tool); err != nil {
			return wire.ACPAgentNeedsNode
		}
	}
	return ""
}

// install runs npm once. Its install scripts stay on, as in Zed: most agents
// have one in their dependencies, and some fetch their binary with it. The cache
// is private and deleted afterwards: npm's shared one would keep every version
// of every agent after it is removed.
func (p *acpNPMPackage) install(ctx context.Context, r *acpRegistry, dir string) (acpEntry, error) {
	// A manifest of its own keeps npm from walking up into a project that holds
	// the data directory.
	if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte("{\"private\":true}\n"), 0o644); err != nil {
		return acpEntry{}, fmt.Errorf("write package.json: %w", err)
	}
	cache := filepath.Join(dir, ".npm-cache")
	err := runInstaller(ctx, dir, nil, "npm", "install", "--save-exact", "--no-audit", "--no-fund", "--no-progress", "--loglevel=error",
		// A user-level omit=optional would drop the platform binary many agents
		// ship as an optional dependency.
		"--include=optional", "--cache", cache, p.name+"@"+p.version)
	if err != nil {
		return acpEntry{}, err
	}
	entry, err := p.executable(dir)
	if err != nil {
		return acpEntry{}, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.discardLocked(cache); err != nil {
		return acpEntry{}, err
	}
	return entry, nil
}

// executable is the package's bin, chosen as Zed's read_package_executable
// chooses it. Launch never goes through npm: `npm exec` costs half a second
// even with everything cached.
func (p *acpNPMPackage) executable(dir string) (acpEntry, error) {
	root := filepath.Join("node_modules", filepath.FromSlash(p.name))
	raw, err := os.ReadFile(filepath.Join(dir, root, "package.json"))
	if err != nil {
		return acpEntry{}, fmt.Errorf("read the installed package: %w", err)
	}
	var manifest struct {
		Bin json.RawMessage `json:"bin"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return acpEntry{}, fmt.Errorf("decode the installed package: %w", err)
	}
	var bin string
	if json.Unmarshal(manifest.Bin, &bin) != nil {
		var bins map[string]string
		if err := json.Unmarshal(manifest.Bin, &bins); err != nil {
			return acpEntry{}, fmt.Errorf("npm package %s declares no executable", p.name)
		}
		unscoped := p.name[strings.LastIndex(p.name, "/")+1:]
		bin = bins[unscoped]
		if len(bins) == 1 {
			for _, only := range bins {
				bin = only
			}
		}
	}
	if bin == "" {
		return acpEntry{}, fmt.Errorf("npm package %s declares no executable", p.name)
	}
	relative := filepath.Join(root, filepath.FromSlash(bin))
	if !filepath.IsLocal(relative) {
		return acpEntry{}, fmt.Errorf("npm package %s declares an executable outside itself", p.name)
	}
	return acpEntry{path: relative, node: true}, nil
}

func (p *acpNPMPackage) releasedAt(ctx context.Context, r *acpRegistry) (time.Time, error) {
	var doc struct {
		Time map[string]time.Time `json:"time"`
	}
	endpoint := "https://registry.npmjs.org/" + url.PathEscape(p.name)
	if err := r.getJSON(ctx, endpoint, &doc); err != nil {
		return time.Time{}, err
	}
	return doc.Time[p.version], nil
}

// acpUVPackage is a Python package at an exact version. What it runs is the
// script named after the package, as `uvx` picks it.
type acpUVPackage struct {
	name, requirement, version string
}

func parseUVPackage(index *acpIndexPackage, version string) *acpUVPackage {
	if index == nil {
		return nil
	}
	spec, _, _ := strings.Cut(index.Package, "==")
	spec, _, _ = strings.Cut(spec, "@")
	name, _, _ := strings.Cut(spec, "[")
	if name == "" || strings.HasPrefix(name, "-") {
		return nil
	}
	return &acpUVPackage{name: name, requirement: spec + "==" + version, version: version}
}

func (p *acpUVPackage) blocker() wire.ACPAgentBlocker {
	if _, err := exec.LookPath("uv"); err != nil {
		return wire.ACPAgentNeedsUV
	}
	return ""
}

func (p *acpUVPackage) install(ctx context.Context, _ *acpRegistry, dir string) (acpEntry, error) {
	env := []string{"UV_TOOL_DIR=" + filepath.Join(dir, "tools"), "UV_TOOL_BIN_DIR=" + filepath.Join(dir, "bin")}
	if err := runInstaller(ctx, dir, env, "uv", "tool", "install", "--quiet", p.requirement); err != nil {
		return acpEntry{}, err
	}
	entry := filepath.Join("bin", p.name)
	if _, err := os.Stat(filepath.Join(dir, entry)); err != nil {
		return acpEntry{}, fmt.Errorf("package %s has no script named after it: %w", p.name, err)
	}
	return acpEntry{path: entry}, nil
}

func (p *acpUVPackage) releasedAt(ctx context.Context, r *acpRegistry) (time.Time, error) {
	var doc struct {
		URLs []struct {
			UploadTime time.Time `json:"upload_time_iso_8601"`
		} `json:"urls"`
	}
	endpoint := "https://pypi.org/pypi/" + url.PathEscape(p.name) + "/" + url.PathEscape(p.version) + "/json"
	if err := r.getJSON(ctx, endpoint, &doc); err != nil || len(doc.URLs) == 0 {
		return time.Time{}, err
	}
	return doc.URLs[0].UploadTime, nil
}

// acpBinaryArchive is a platform's download from the registry's binary
// distribution.
type acpBinaryArchive struct {
	url, command, sha256 string
}

func (a acpBinaryArchive) blocker() wire.ACPAgentBlocker { return "" }

func (a acpBinaryArchive) install(ctx context.Context, r *acpRegistry, dir string) (acpEntry, error) {
	extract, err := archiveExtractor(a.url)
	if err != nil {
		return acpEntry{}, err
	}
	want := a.sha256
	if want == "" {
		// Without a release, or a digest on it, the download goes unchecked, as
		// in Zed.
		if release, ok := a.githubRelease(ctx, r); ok {
			if parsed, err := url.Parse(a.url); err == nil {
				want = release.digest(path.Base(parsed.Path))
			}
		}
	}
	download := filepath.Join(dir, ".download")
	if err := r.download(ctx, a.url, download, want); err != nil {
		return acpEntry{}, err
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return acpEntry{}, fmt.Errorf("open the agent directory: %w", err)
	}
	defer root.Close()
	if err := extract(ctx, download, root); err != nil {
		return acpEntry{}, fmt.Errorf("unpack %s: %w", a.url, err)
	}
	// A raw binary's download has become the agent.
	if err := os.Remove(download); err != nil && !os.IsNotExist(err) {
		return acpEntry{}, fmt.Errorf("delete the download: %w", err)
	}
	command := filepath.FromSlash(strings.TrimPrefix(a.command, "./"))
	if !filepath.IsLocal(command) {
		return acpEntry{}, fmt.Errorf("the registry's command %q is outside the agent's directory", a.command)
	}
	info, err := root.Stat(command)
	if err != nil || !info.Mode().IsRegular() {
		return acpEntry{}, fmt.Errorf("the archive has no %s", a.command)
	}
	// Archives built off Unix can lose the executable bit.
	if err := root.Chmod(command, info.Mode().Perm()|0o755); err != nil {
		return acpEntry{}, fmt.Errorf("make the agent executable: %w", err)
	}
	return acpEntry{path: command}, nil
}

func (a acpBinaryArchive) releasedAt(ctx context.Context, r *acpRegistry) (time.Time, error) {
	if release, ok := a.githubRelease(ctx, r); ok {
		return release.PublishedAt, nil
	}
	return time.Time{}, nil
}

type githubRelease struct {
	PublishedAt time.Time `json:"published_at"`
	Assets      []struct {
		Name   string `json:"name"`
		Digest string `json:"digest"`
	} `json:"assets"`
}

// digest is the sha256 GitHub recorded for an asset.
func (g githubRelease) digest(name string) string {
	for _, asset := range g.Assets {
		if digest, ok := strings.CutPrefix(asset.Digest, "sha256:"); ok && asset.Name == name {
			return digest
		}
	}
	return ""
}

// githubRelease looks up the release a github.com download belongs to. Any
// failure counts as no release: the API's rate limit mustn't stop an install.
func (a acpBinaryArchive) githubRelease(ctx context.Context, r *acpRegistry) (githubRelease, bool) {
	parsed, err := url.Parse(a.url)
	if err != nil || parsed.Host != "github.com" {
		return githubRelease{}, false
	}
	segments := strings.Split(strings.Trim(parsed.EscapedPath(), "/"), "/")
	if len(segments) < 6 || segments[2] != "releases" || segments[3] != "download" {
		return githubRelease{}, false
	}
	var release githubRelease
	endpoint := "https://api.github.com/repos/" + segments[0] + "/" + segments[1] + "/releases/tags/" + segments[4]
	if err := r.getJSON(ctx, endpoint, &release); err != nil {
		r.logger.Debug("look up GitHub release", "url", endpoint, "error", err)
		return githubRelease{}, false
	}
	return release, true
}

func (r *acpRegistry) getJSON(ctx context.Context, endpoint string, into any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s returned %s", endpoint, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(into)
}

// download saves rawURL to path, refusing a body whose sha256 isn't want when
// there is a want.
func (r *acpRegistry) download(ctx context.Context, rawURL, path, want string) error {
	if !strings.HasPrefix(rawURL, "https://") {
		return fmt.Errorf("refusing to download %s: not HTTPS", rawURL)
	}
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	stalled := fmt.Errorf("no data for %s", acpDownloadStallTimeout)
	watchdog := time.AfterFunc(acpDownloadStallTimeout, func() { cancel(stalled) })
	defer watchdog.Stop()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return fmt.Errorf("download %s: %w", rawURL, err)
	}
	client := *r.client
	client.Timeout = 0
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", rawURL, describeCause(ctx, err))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: server returned %s", rawURL, resp.Status)
	}
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("download %s: %w", rawURL, err)
	}
	defer file.Close()
	sum := sha256.New()
	if _, err := io.Copy(io.MultiWriter(file, sum, progressWriter{watchdog}), resp.Body); err != nil {
		return fmt.Errorf("download %s: %w", rawURL, describeCause(ctx, err))
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("download %s: %w", rawURL, err)
	}
	if got := hex.EncodeToString(sum.Sum(nil)); want != "" && !strings.EqualFold(got, want) {
		return fmt.Errorf("sha256 mismatch: expected %s, the download has %s", want, got)
	}
	return nil
}

func describeCause(ctx context.Context, err error) error {
	if cause := context.Cause(ctx); cause != nil {
		return cause
	}
	return err
}

// progressWriter pushes the download's stall deadline back on every chunk.
type progressWriter struct {
	watchdog *time.Timer
}

func (p progressWriter) Write(chunk []byte) (int, error) {
	p.watchdog.Reset(acpDownloadStallTimeout)
	return len(chunk), nil
}

// acpExtractor unpacks a download into root, which refuses paths and links that
// leave it.
type acpExtractor func(ctx context.Context, download string, root *os.Root) error

// archiveExtractor picks an extractor by the URL's name, for the formats the
// registry's schema allows; anything else is a raw binary.
func archiveExtractor(rawURL string) (acpExtractor, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("the registry's archive URL %q: %w", rawURL, err)
	}
	name := strings.ToLower(path.Base(parsed.Path))
	switch {
	case strings.HasSuffix(name, ".zip"):
		return extractZip, nil
	case strings.HasSuffix(name, ".tar.gz"), strings.HasSuffix(name, ".tgz"):
		return func(ctx context.Context, download string, root *os.Root) error {
			return withFile(download, func(file io.Reader) error {
				gz, err := gzip.NewReader(file)
				if err != nil {
					return err
				}
				defer gz.Close()
				return extractTar(ctx, gz, root)
			})
		}, nil
	case strings.HasSuffix(name, ".tar.bz2"), strings.HasSuffix(name, ".tbz2"):
		return func(ctx context.Context, download string, root *os.Root) error {
			return withFile(download, func(file io.Reader) error {
				return extractTar(ctx, bzip2.NewReader(file), root)
			})
		}, nil
	}
	// Refused before a download that couldn't run anyway.
	for _, suffix := range []string{".dmg", ".pkg", ".deb", ".rpm", ".msi", ".appimage", ".txz", ".tar", ".gz", ".bz2", ".xz", ".7z"} {
		if strings.HasSuffix(name, suffix) {
			return nil, fmt.Errorf("maiD can't unpack %s", path.Base(parsed.Path))
		}
	}
	// A raw binary keeps the name the URL gives it, which the registry's command
	// refers to.
	return func(_ context.Context, download string, root *os.Root) error {
		return root.Rename(filepath.Base(download), path.Base(parsed.Path))
	}, nil
}

func withFile(path string, use func(io.Reader) error) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return use(file)
}

func extractTar(ctx context.Context, stream io.Reader, root *os.Root) error {
	reader := tar.NewReader(stream)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(header.Name)
		if name == "." {
			continue
		}
		mode := header.FileInfo().Mode()
		switch header.Typeflag {
		case tar.TypeDir:
			err = root.MkdirAll(name, 0o755)
		case tar.TypeReg:
			err = writeFile(ctx, root, name, mode, reader)
		case tar.TypeSymlink:
			if err = makeParent(root, name); err == nil {
				err = root.Symlink(header.Linkname, name)
			}
		case tar.TypeLink:
			if err = makeParent(root, name); err == nil {
				err = root.Link(filepath.Clean(header.Linkname), name)
			}
		}
		if err != nil {
			return fmt.Errorf("%s: %w", header.Name, err)
		}
	}
}

func extractZip(ctx context.Context, download string, root *os.Root) error {
	archive, err := zip.OpenReader(download)
	if err != nil {
		return err
	}
	defer archive.Close()
	for _, entry := range archive.File {
		name := filepath.Clean(entry.Name)
		mode := entry.Mode()
		switch {
		case mode.IsDir():
			err = root.MkdirAll(name, 0o755)
		case mode&fs.ModeSymlink != 0:
			err = withZipEntry(entry, func(body io.Reader) error {
				target, err := io.ReadAll(body)
				if err != nil {
					return err
				}
				if err := makeParent(root, name); err != nil {
					return err
				}
				return root.Symlink(string(target), name)
			})
		case mode.IsRegular():
			err = withZipEntry(entry, func(body io.Reader) error { return writeFile(ctx, root, name, mode, body) })
		}
		if err != nil {
			return fmt.Errorf("%s: %w", entry.Name, err)
		}
	}
	return nil
}

func withZipEntry(entry *zip.File, use func(io.Reader) error) error {
	body, err := entry.Open()
	if err != nil {
		return err
	}
	defer body.Close()
	return use(body)
}

// makeParent makes the directory an entry goes in: archives needn't list them.
func makeParent(root *os.Root, name string) error {
	return root.MkdirAll(filepath.Dir(name), 0o755)
}

func writeFile(ctx context.Context, root *os.Root, name string, mode fs.FileMode, body io.Reader) error {
	if err := makeParent(root, name); err != nil {
		return err
	}
	file, err := root.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode.Perm()|0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := io.Copy(file, contextReader{ctx, body}); err != nil {
		return err
	}
	return file.Close()
}

// contextReader ends a long copy when the daemon stops.
type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (c contextReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.reader.Read(p)
}

// releaseKey names one version of one agent in the released map.
func releaseKey(id, version string) string {
	return id + "@" + version
}

// lookUpReleaseDatesLocked finds out when each installed agent's available
// update came out. Only those: a lookup is a network call per agent, and npm's
// answer can run to megabytes. A lookup that fails tries again at the next
// refresh; rows gain their date through a later list.
func (r *acpRegistry) lookUpReleaseDatesLocked() {
	for _, agent := range r.installed {
		listed, ok := findRegistryAgent(r.catalog, agent.ID)
		if !ok || agent.custom() || listed.Version == agent.Version || listed.Distribution == nil {
			continue
		}
		key := releaseKey(listed.ID, listed.Version)
		if _, known := r.released[key]; known {
			continue
		}
		r.released[key] = time.Time{}
		go func() {
			at, err := listed.Distribution.releasedAt(r.ctx, r)
			r.mu.Lock()
			defer r.mu.Unlock()
			if err != nil {
				r.logger.Debug("look up release date", "agent", listed.ID, "error", err)
				delete(r.released, key)
				return
			}
			if !at.IsZero() {
				r.released[key] = at
				r.publishLocked()
			}
		}()
	}
}
