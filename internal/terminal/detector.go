package terminal

import (
	"log/slog"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

// Detector derives shared coding-agent state for one terminal run without a
// client attached. Identity is process-first: the PTY's foreground process
// group is probed on output (a cheap ioctl) and inspected with one /bin/ps
// scan only when it changes. Title and progress evidence comes from the
// streaming OSC tracker; screen evidence comes from a passive headless
// Ghostty VT screen when the build provides one. All evidence stays inside
// the detector — published reports carry only semantic fields and the
// normalized title.
type Detector struct {
	cfg detectorConfig

	mu       sync.Mutex
	tracker  oscTracker
	rawTitle string
	progress string
	fgPGID   int
	// pendingInspectPGID is identified by the detector worker, never by the
	// PTY output path. A non-zero value means foreground identity is pending.
	pendingInspectPGID int
	// kind is the current foreground agent; lastKind survives into a done
	// report after the agent returns to the shell.
	kind     AgentKind
	lastKind AgentKind
	activity AgentActivityState
	attached bool
	// pendingIdleSince tracks a working-to-idle candidate that must stay
	// stable before it commits, so spinner redraws and transient prompt
	// frames do not flicker the sidebar.
	pendingIdleSince time.Time
	published        AgentReport
	hasPublished     bool
	updatedAt        time.Time

	// Screen formatting is debounced: output marks the screen dirty, and a
	// scan formats it once output settles (or at a bounded forced interval
	// during continuous output). Clean idle terminals format nothing.
	screen       vtscreen.Screen // nil when unavailable
	cachedScreen string
	screenFailed bool
	dirty        bool
	lastOutputAt time.Time
	lastScanAt   time.Time

	stop     chan struct{}
	wake     chan struct{}
	stopOnce sync.Once
	stopped  bool
}

type processInfo struct {
	pid  int
	argv []string
}

type detectorConfig struct {
	// shellPGID is the login shell's process group (its pid under Setsid).
	shellPGID int
	// foregroundPGID reads the PTY's current foreground process group.
	foregroundPGID func() (int, bool)
	// inspectGroup lists the processes of one foreground group.
	inspectGroup func(pgid int) []processInfo
	// publish delivers one changed report. Called without detector locks.
	publish func(AgentReport)
	// screen is the optional headless VT screen; the detector owns closing
	// it.
	screen vtscreen.Screen

	now               func() time.Time
	recheckInterval   time.Duration // foreground recheck while an agent is known
	settleInterval    time.Duration // recheck while a working→idle candidate settles
	idleStabilization time.Duration // stable evidence required before working→idle
	scanDebounce      time.Duration // screen scan delay after output settles
	scanForce         time.Duration // bounded scan interval during continuous output
}

const (
	defaultRecheckInterval   = time.Second
	defaultSettleInterval    = 100 * time.Millisecond
	defaultIdleStabilization = 300 * time.Millisecond
	defaultScanDebounce      = 200 * time.Millisecond
	defaultScanForce         = 500 * time.Millisecond
)

func newDetector(cfg detectorConfig) *Detector {
	if cfg.now == nil {
		cfg.now = time.Now
	}
	if cfg.recheckInterval <= 0 {
		cfg.recheckInterval = defaultRecheckInterval
	}
	if cfg.settleInterval <= 0 {
		cfg.settleInterval = defaultSettleInterval
	}
	if cfg.idleStabilization <= 0 {
		cfg.idleStabilization = defaultIdleStabilization
	}
	if cfg.scanDebounce <= 0 {
		cfg.scanDebounce = defaultScanDebounce
	}
	if cfg.scanForce <= 0 {
		cfg.scanForce = defaultScanForce
	}
	d := &Detector{
		cfg:      cfg,
		screen:   cfg.screen,
		activity: AgentActivityNone,
		stop:     make(chan struct{}),
		wake:     make(chan struct{}, 1),
	}
	go d.run()
	return d
}

// ObserveOutput feeds one ordered PTY output chunk. Called serially by the
// session read loop. The VT screen sees the original bytes synchronously so
// its state follows the stream exactly; formatting waits for the debounce.
func (d *Detector) ObserveOutput(data []byte) {
	d.mu.Lock()
	now := d.cfg.now()
	// Probe before scanning: a foreground change resets retained OSC evidence,
	// and evidence arriving in this same chunk belongs to the new job. The
	// potentially slow process-table inspection runs on the detector worker.
	fgChanged := d.probeForegroundLocked()
	if d.screen != nil {
		d.screen.Feed(data)
	}
	previousNormalized := normalizeTitle(d.rawTitle)
	previousProgress := d.progress
	d.tracker.scan(data,
		func(title string) { d.rawTitle = capScalars(title, rawTitleScalarCap) },
		func(payload string) { d.progress = payload },
	)
	d.lastOutputAt = now

	// Meaningful changes scan immediately; ordinary output waits for the
	// debounced scan. Spinner-frame title churn normalizes away and stays
	// on the debounced path.
	meaningful := fgChanged ||
		normalizeTitle(d.rawTitle) != previousNormalized ||
		d.progress != previousProgress
	var report AgentReport
	changed := false
	if meaningful {
		d.refreshScreenLocked()
		if d.pendingInspectPGID == 0 {
			report, changed = d.evaluateLocked()
		} else {
			d.nudgeRecheckLocked()
		}
	} else if d.screen != nil && !d.screenFailed {
		d.dirty = true
		d.nudgeRecheckLocked()
	}
	d.mu.Unlock()
	if changed {
		d.cfg.publish(report)
	}
}

// ResizeScreen matches the detector screen to the PTY grid. Applied in the
// same serialized session operation as the PTY resize.
func (d *Detector) ResizeScreen(columns, rows uint16) {
	d.mu.Lock()
	if d.screen != nil {
		_ = d.screen.Resize(columns, rows)
		// Reflow changes the screen contents; rescan once output settles.
		d.dirty = true
		d.nudgeRecheckLocked()
	}
	d.mu.Unlock()
}

// SetAttached tells the detector whether any client is currently attached.
// Attaching acknowledges a pending done state.
func (d *Detector) SetAttached(attached bool) {
	d.mu.Lock()
	d.attached = attached
	if attached && d.activity == AgentActivityDone {
		// The attach acknowledged the finished run; recompute from current
		// evidence instead of holding done.
		d.activity = d.freshActivityLocked()
		d.updatedAt = d.cfg.now()
	}
	report, changed := d.evaluateLocked()
	d.mu.Unlock()
	if changed {
		d.cfg.publish(report)
	}
}

// Report returns the last published semantic state.
func (d *Detector) Report() AgentReport {
	if d == nil {
		return AgentReport{Activity: AgentActivityNone}
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.hasPublished {
		return AgentReport{Activity: AgentActivityNone}
	}
	return d.published
}

// Stop ends the recheck goroutine, releases the VT screen, and clears the
// run's transient agent report.
func (d *Detector) Stop() {
	if d == nil {
		return
	}
	d.stopOnce.Do(func() {
		close(d.stop)
		d.mu.Lock()
		d.stopped = true
		if d.screen != nil {
			d.screen.Close()
			d.screen = nil
		}
		// Agent evidence is transient run state. Once the shell itself ends,
		// list snapshots must not combine an exited/stopped lifecycle with a
		// stale working agent report.
		d.cachedScreen = ""
		d.dirty = false
		d.rawTitle = ""
		d.progress = ""
		d.tracker = oscTracker{}
		d.kind = AgentNone
		d.lastKind = AgentNone
		d.activity = AgentActivityNone
		d.pendingIdleSince = time.Time{}
		d.pendingInspectPGID = 0
		d.published = AgentReport{Activity: AgentActivityNone}
		d.hasPublished = true
		d.mu.Unlock()
	})
}

// probeForegroundLocked reads the foreground group and schedules process
// identification only when it changes. It performs only the cheap ioctl and
// never invokes /bin/ps on the PTY output path.
func (d *Detector) probeForegroundLocked() bool {
	fg, ok := d.cfg.foregroundPGID()
	if !ok || fg == d.fgPGID {
		return false
	}
	d.fgPGID = fg
	// OSC title/progress belongs to the process that emitted it. In particular,
	// an agent title must disappear as soon as control returns to the shell,
	// even when the shell does not publish a replacement title.
	d.rawTitle = ""
	d.progress = ""
	d.tracker = oscTracker{}
	d.cachedScreen = ""
	if fg == d.cfg.shellPGID {
		d.kind = AgentNone
		d.pendingInspectPGID = 0
	} else {
		// Keep identity private until the worker has inspected this exact group;
		// this avoids publishing a temporary unknown-agent state.
		d.kind = AgentUnknown
		d.pendingInspectPGID = fg
		d.nudgeRecheckLocked()
	}
	return true
}

// refreshScreenLocked formats the current active screen into the cache. A
// formatter failure degrades to evidence-free classification permanently for
// this run, with one bounded diagnostic and no screen contents logged.
func (d *Detector) refreshScreenLocked() {
	d.dirty = false
	if d.screen == nil || d.screenFailed {
		return
	}
	text, err := d.screen.Text()
	if err != nil {
		d.screenFailed = true
		d.cachedScreen = ""
		slog.Warn("terminal detector screen formatting failed; continuing without screen evidence", "error", err)
		return
	}
	d.cachedScreen = text
	d.lastScanAt = d.cfg.now()
}

// freshActivityLocked classifies current evidence with no transition rules.
func (d *Detector) freshActivityLocked() AgentActivityState {
	return classifyActivity(agentEvidence{
		kind:     d.kind,
		rawTitle: d.rawTitle,
		progress: d.progress,
		screen:   d.cachedScreen,
	}, d.activity)
}

// evaluateLocked applies transition semantics to freshly classified
// evidence and composes the next report. It returns the report and whether
// it changed; the caller publishes outside the lock.
func (d *Detector) evaluateLocked() (AgentReport, bool) {
	now := d.cfg.now()
	target := d.freshActivityLocked()

	if d.kind != AgentNone {
		d.lastKind = d.kind
	}

	switch {
	case d.kind == AgentNone && d.activity == AgentActivityWorking && !d.attached:
		// The agent returned to the shell while nobody was watching: the
		// run finished. Shell foreground is definitive, so done commits
		// immediately and persists until the next attach.
		d.commitLocked(AgentActivityDone, now)
	case d.kind == AgentNone && d.activity == AgentActivityDone:
		// Hold done until an attach acknowledges it.
		d.pendingIdleSince = time.Time{}
	case d.kind == AgentNone:
		d.commitLocked(AgentActivityNone, now)
		d.lastKind = AgentNone
	case d.activity == AgentActivityDone &&
		(target == AgentActivityWorking || target == AgentActivityBlocked):
		// New explicit activity overrides an unacknowledged done.
		d.commitLocked(target, now)
	case d.activity == AgentActivityDone:
		d.pendingIdleSince = time.Time{}
	case d.activity == AgentActivityWorking &&
		(target == AgentActivityIdle || target == AgentActivityUnknown):
		// Working must stay stable through spinner redraws: require the
		// idle evidence to persist before committing.
		if d.pendingIdleSince.IsZero() {
			d.pendingIdleSince = now
		} else if now.Sub(d.pendingIdleSince) >= d.cfg.idleStabilization {
			if target == AgentActivityIdle && !d.attached {
				target = AgentActivityDone
			}
			d.commitLocked(target, now)
		}
	default:
		d.commitLocked(target, now)
	}

	kind := d.reportKindLocked()
	activity := d.activity
	// An unnamed foreground job (every ordinary shell command) surfaces only
	// when generic evidence produced a real signal; otherwise `ls` and `vim`
	// would churn the thread list with meaningless unknown reports.
	if kind == AgentUnknown &&
		activity != AgentActivityWorking &&
		activity != AgentActivityBlocked &&
		activity != AgentActivityDone {
		kind, activity = AgentNone, AgentActivityNone
	}
	report := AgentReport{
		Kind:      kind,
		Activity:  activity,
		Title:     normalizeTitle(d.rawTitle),
		UpdatedAt: d.updatedAt,
	}
	changed := !d.hasPublished ||
		report.Kind != d.published.Kind ||
		report.Activity != d.published.Activity ||
		report.Title != d.published.Title
	if changed {
		if report.UpdatedAt.IsZero() {
			report.UpdatedAt = now
			d.updatedAt = now
		}
		d.published = report
		d.hasPublished = true
	}
	d.nudgeRecheckLocked()
	return report, changed
}

func (d *Detector) commitLocked(activity AgentActivityState, now time.Time) {
	d.pendingIdleSince = time.Time{}
	if d.activity == activity {
		return
	}
	d.activity = activity
	d.updatedAt = now
}

func (d *Detector) reportKindLocked() AgentKind {
	if d.activity == AgentActivityDone {
		return d.lastKind
	}
	return d.kind
}

// nudgeRecheckLocked wakes the periodic loop when timed work exists: a known
// agent needs the one-second silent-exit probe, a pending idle candidate
// needs its settle checks, and a dirty screen needs its debounced scan. Idle
// shells schedule nothing.
func (d *Detector) nudgeRecheckLocked() {
	if d.kind == AgentNone && d.pendingIdleSince.IsZero() && !d.dirty && d.pendingInspectPGID == 0 {
		return
	}
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

func (d *Detector) run() {
	for {
		select {
		case <-d.stop:
			return
		case <-d.wake:
		}
		for {
			d.mu.Lock()
			pendingInspection := d.pendingInspectPGID != 0
			active := d.kind != AgentNone || !d.pendingIdleSince.IsZero() || d.dirty || pendingInspection
			interval := d.cfg.recheckInterval
			if d.dirty {
				interval = d.cfg.settleInterval
			}
			if !d.pendingIdleSince.IsZero() && d.cfg.settleInterval < interval {
				interval = d.cfg.settleInterval
			}
			d.mu.Unlock()
			if !active {
				break
			}
			if pendingInspection {
				d.recheck()
				continue
			}
			select {
			case <-d.stop:
				return
			case <-time.After(interval):
			}
			d.recheck()
		}
	}
}

func (d *Detector) recheck() {
	d.mu.Lock()
	d.probeForegroundLocked()
	inspectPGID := d.pendingInspectPGID
	d.mu.Unlock()

	// /bin/ps can be materially slower than feeding terminal output. Perform
	// it without holding the detector lock so rendering, resize, and shutdown
	// remain responsive. A foreground change fences the result below.
	var inspectedKind AgentKind
	if inspectPGID != 0 {
		inspectedKind = identifyAgentGroup(inspectPGID, d.cfg.inspectGroup(inspectPGID))
	}

	d.mu.Lock()
	if d.stopped {
		d.mu.Unlock()
		return
	}
	if inspectPGID != 0 && d.fgPGID == inspectPGID && d.pendingInspectPGID == inspectPGID {
		d.kind = inspectedKind
		d.pendingInspectPGID = 0
	}
	if d.pendingInspectPGID != 0 {
		// The foreground changed again while inspection was running. Do not
		// publish temporary identity; the worker immediately inspects the newer
		// process group on its next pass.
		d.mu.Unlock()
		return
	}
	now := d.cfg.now()
	// The debounced screen scan: format after output settles, or at the
	// bounded forced interval while output stays continuous.
	if d.dirty &&
		(now.Sub(d.lastOutputAt) >= d.cfg.scanDebounce ||
			now.Sub(d.lastScanAt) >= d.cfg.scanForce) {
		d.refreshScreenLocked()
	}
	report, changed := d.evaluateLocked()
	d.mu.Unlock()
	if changed {
		d.cfg.publish(report)
	}
}
