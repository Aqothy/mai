package workspacesearch

import (
	"context"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Aqothy/maiD/internal/workspacesearch/fff"
)

const (
	// scanWaitBudget bounds how long one request waits for a warming index
	// before answering Indexing:true and letting the client retry.
	scanWaitBudget = 100 * time.Millisecond
	// idleTTL and maxIndexes are initial safety defaults (see the FFF plan);
	// change them only from measured memory behavior.
	idleTTL       = 15 * time.Minute
	maxIndexes    = 8
	sweepInterval = time.Minute
)

// Service is a concurrency-safe registry of warm FFF indexes keyed by
// canonical workspace root. The registry lock is never held across native
// scan or search calls.
type Service struct {
	newIndex func(root string) (fff.Finder, error)
	now      func() time.Time

	mu      sync.Mutex
	indexes map[string]*workspaceIndex
	closed  bool

	sweepStop chan struct{}
	sweepDone chan struct{}
}

// workspaceIndex tracks one root's index through its asynchronous life:
// ready closes once creation finished (finder or createErr is then set), and
// scanned flips once the initial workspace scan completed.
type workspaceIndex struct {
	root string

	ready     chan struct{}
	finder    fff.Finder
	createErr error

	// scanned latches initial-scan completion: warm searches check the
	// atomic and skip the native wait (and its lock) entirely.
	scanned  atomic.Bool
	scanWait sync.Mutex

	// lastUsed is guarded by Service.mu.
	lastUsed time.Time
}

func NewService() *Service {
	s := &Service{
		newIndex:  fff.New,
		now:       time.Now,
		indexes:   make(map[string]*workspaceIndex),
		sweepStop: make(chan struct{}),
		sweepDone: make(chan struct{}),
	}
	go s.sweepIdle()
	return s
}

// Search runs one fuzzy path query against root's warm index, creating the
// index on first use. It never blocks on a full initial scan: after
// scanWaitBudget it reports Indexing:true instead.
func (s *Service) Search(ctx context.Context, root, query string, limit int) (Result, error) {
	if len(query) > MaxQueryBytes {
		return Result{}, ErrQueryTooLong
	}
	if limit == 0 {
		limit = DefaultLimit
	}
	limit = min(max(limit, 1), MaxLimit)
	canonical, err := CanonicalRoot(root)
	if err != nil {
		return Result{}, err
	}

	entry, err := s.entryFor(canonical)
	if err != nil {
		return Result{}, err
	}

	waitCtx, cancel := context.WithTimeout(ctx, scanWaitBudget)
	defer cancel()
	select {
	case <-entry.ready:
	case <-waitCtx.Done():
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		return Result{Indexing: true}, nil
	}
	if entry.createErr != nil {
		return Result{}, fmt.Errorf("workspacesearch: index initialization failed: %w", entry.createErr)
	}
	if !entry.scanComplete(waitCtx) {
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		return Result{Indexing: true}, nil
	}

	matches, err := entry.finder.SearchFiles(query, limit)
	if err != nil {
		return Result{}, fmt.Errorf("workspacesearch: search failed: %w", err)
	}
	return Result{Entries: sanitizeEntries(matches)}, nil
}

// CanonicalRoot validates root as an absolute existing directory and
// resolves symlinks so every alias of a workspace shares one index.
func CanonicalRoot(root string) (string, error) {
	if root == "" || !filepath.IsAbs(root) {
		return "", fmt.Errorf("%w: %q is not an absolute path", ErrInvalidRoot, root)
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidRoot, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidRoot, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%w: %q is not a directory", ErrInvalidRoot, root)
	}
	return resolved, nil
}

// entryFor returns the root's index entry, creating and initializing it for
// the first caller. Concurrent first requests coalesce on the single map
// entry; initialization runs outside the registry lock.
func (s *Service) entryFor(root string) (*workspaceIndex, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, ErrClosed
	}
	entry, ok := s.indexes[root]
	if !ok {
		if len(s.indexes) >= maxIndexes {
			s.evictLRULocked()
		}
		entry = &workspaceIndex{root: root, ready: make(chan struct{})}
		s.indexes[root] = entry
		go s.initialize(entry)
	}
	entry.lastUsed = s.now()
	return entry, nil
}

func (s *Service) initialize(entry *workspaceIndex) {
	defer close(entry.ready)
	finder, err := s.newIndex(entry.root)
	s.mu.Lock()
	if err != nil {
		entry.createErr = err
		// Drop the failed entry so a later request can retry cleanly.
		if s.indexes[entry.root] == entry {
			delete(s.indexes, entry.root)
		}
		s.mu.Unlock()
		return
	}
	if s.closed || s.indexes[entry.root] != entry {
		// Shutdown or eviction raced creation; nobody else owns this finder.
		entry.createErr = ErrClosed
		s.mu.Unlock()
		_ = finder.Close()
		return
	}
	entry.finder = finder
	s.mu.Unlock()
}

// scanComplete reports whether the initial scan has finished, waiting at
// most until ctx expires. scanWait keeps concurrent warm-up requests from
// stacking native waits on one index.
func (e *workspaceIndex) scanComplete(ctx context.Context) bool {
	if e.scanned.Load() {
		return true
	}
	e.scanWait.Lock()
	defer e.scanWait.Unlock()
	if e.scanned.Load() {
		return true
	}
	if err := e.finder.WaitReady(ctx); err != nil {
		return false
	}
	e.scanned.Store(true)
	return true
}

// sanitizeEntries enforces the wire contract: relative, normalized,
// root-contained, deduplicated paths only.
func sanitizeEntries(matches []fff.FileMatch) []Entry {
	entries := make([]Entry, 0, len(matches))
	seen := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		cleaned := path.Clean(filepath.ToSlash(match.RelativePath))
		if cleaned == "" || cleaned == "." || cleaned == ".." ||
			strings.HasPrefix(cleaned, "/") || strings.HasPrefix(cleaned, "../") {
			continue
		}
		if _, duplicate := seen[cleaned]; duplicate {
			continue
		}
		seen[cleaned] = struct{}{}
		display := match.DisplayName
		if display == "" {
			display = path.Base(cleaned)
		}
		entries = append(entries, Entry{RelativePath: cleaned, DisplayName: display})
	}
	return entries
}

// evictLRULocked removes the least-recently-used index to stay within
// maxIndexes. The finder is closed off-lock; fff.Finder.Close serializes
// against in-flight searches itself.
func (s *Service) evictLRULocked() {
	var oldest *workspaceIndex
	for _, entry := range s.indexes {
		if oldest == nil || entry.lastUsed.Before(oldest.lastUsed) {
			oldest = entry
		}
	}
	if oldest == nil {
		return
	}
	delete(s.indexes, oldest.root)
	go closeEntry(oldest)
}

func (s *Service) sweepIdle() {
	defer close(s.sweepDone)
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.sweepStop:
			return
		case <-ticker.C:
			s.evictIdle()
		}
	}
}

// evictIdle closes every index that has not served a request for idleTTL.
func (s *Service) evictIdle() {
	cutoff := s.now().Add(-idleTTL)
	s.mu.Lock()
	var idle []*workspaceIndex
	for root, entry := range s.indexes {
		if entry.lastUsed.Before(cutoff) {
			delete(s.indexes, root)
			idle = append(idle, entry)
		}
	}
	s.mu.Unlock()
	for _, entry := range idle {
		closeEntry(entry)
	}
}

// closeEntry waits out a pending initialization, then closes the finder.
func closeEntry(entry *workspaceIndex) {
	<-entry.ready
	if entry.finder != nil {
		_ = entry.finder.Close()
	}
}

// Close shuts the registry down: every index is closed and later requests
// fail with ErrClosed.
func (s *Service) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		<-s.sweepDone
		return
	}
	s.closed = true
	entries := make([]*workspaceIndex, 0, len(s.indexes))
	for _, entry := range s.indexes {
		entries = append(entries, entry)
	}
	s.indexes = nil
	s.mu.Unlock()

	close(s.sweepStop)
	<-s.sweepDone
	for _, entry := range entries {
		closeEntry(entry)
	}
}
