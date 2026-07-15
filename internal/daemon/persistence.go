package daemon

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/store"
)

func metadataDBPath() (string, error) {
	dir := os.Getenv("MAID_DATA_DIR")
	if dir == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return "", fmt.Errorf("resolve user config dir: %w", err)
		}
		dir = filepath.Join(base, "maiD")
	}
	return filepath.Join(dir, "maid.db"), nil
}

// openMetadataStore falls back to in-memory operation when persistence is unavailable.
func openMetadataStore(logger *slog.Logger) *store.SQLite {
	path, err := metadataDBPath()
	if err == nil {
		var metadata *store.SQLite
		if metadata, err = store.Open(path); err == nil {
			logger.Info("metadata store opened", "path", path)
			return metadata
		}
	}
	logger.Warn("metadata persistence disabled; running in-memory only", "error", err)
	return nil
}

// restorePersistedThreads seeds the projection with thread stubs and reconciles
// their routes before the daemon serves connections. Route writes are
// synchronous while thread metadata is debounced, so a conflicting route is
// the newer provider selection after a crash.
func restorePersistedThreads(engine *orchestration.Engine, threads store.ThreadStore, routes store.RouteStore, logger *slog.Logger) (int, error) {
	metas, err := threads.ListThreads()
	if err != nil {
		return 0, err
	}
	restored := make([]orchestration.RestoredThread, 0, len(metas))
	threadIndexes := make(map[string]int, len(metas))
	for _, meta := range metas {
		threadIndexes[meta.ThreadID] = len(restored)
		restored = append(restored, orchestration.RestoredThread{
			ThreadID:           orchestration.ThreadID(meta.ThreadID),
			Title:              meta.Title,
			Cwd:                meta.Cwd,
			ProviderInstanceID: meta.ProviderInstanceID,
			ModelSelection:     meta.ModelSelection,
			CreatedAt:          meta.CreatedAt,
			UpdatedAt:          meta.UpdatedAt,
		})
	}

	persistedRoutes, routeErr := routes.LoadRoutes()
	if routeErr != nil {
		logger.Warn("reconcile persisted routes", "error", routeErr)
	} else {
		for threadID, route := range persistedRoutes {
			index, ok := threadIndexes[threadID]
			if ok {
				if restored[index].ProviderInstanceID != route.InstanceID {
					restored[index].ProviderInstanceID = route.InstanceID
					restored[index].ModelSelection = route.StartInput.ModelSelection
				}
				continue
			}
			if err := routes.DeleteRoute(threadID); err != nil {
				logger.Warn("delete orphaned persisted route", "thread", threadID, "error", err)
			}
		}
	}

	engine.RestoreThreads(restored)
	return len(restored), nil
}

const threadMetaFlushDebounce = 250 * time.Millisecond

// threadMetaWriter persists projection metadata without blocking the engine worker.
type threadMetaWriter struct {
	engine  *orchestration.Engine
	threads store.ThreadStore
	logger  *slog.Logger

	mu    sync.Mutex
	dirty map[orchestration.ThreadID]struct{}

	wake      chan struct{}
	closing   chan struct{}
	done      chan struct{}
	closeOnce sync.Once
}

func newThreadMetaWriter(engine *orchestration.Engine, threads store.ThreadStore, logger *slog.Logger) *threadMetaWriter {
	w := &threadMetaWriter{
		engine:  engine,
		threads: threads,
		logger:  logger,
		dirty:   make(map[orchestration.ThreadID]struct{}),
		wake:    make(chan struct{}, 1),
		closing: make(chan struct{}),
		done:    make(chan struct{}),
	}
	go w.run()
	return w
}

func (w *threadMetaWriter) markDirty(threadID orchestration.ThreadID) {
	if threadID == "" {
		return
	}
	w.mu.Lock()
	w.dirty[threadID] = struct{}{}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

func (w *threadMetaWriter) Close() {
	w.closeOnce.Do(func() { close(w.closing) })
	<-w.done
}

func (w *threadMetaWriter) run() {
	defer close(w.done)
	for {
		select {
		case <-w.closing:
			w.flush()
			return
		case <-w.wake:
			timer := time.NewTimer(threadMetaFlushDebounce)
			select {
			case <-w.closing:
				timer.Stop()
				w.flush()
				return
			case <-timer.C:
			}
			w.flush()
		}
	}
}

func (w *threadMetaWriter) flush() {
	w.mu.Lock()
	dirty := w.dirty
	w.dirty = make(map[orchestration.ThreadID]struct{})
	w.mu.Unlock()
	var failed []orchestration.ThreadID
	for threadID := range dirty {
		entry, ok := w.engine.ThreadListEntry(threadID)
		if !ok || entry.Draft {
			continue
		}
		meta := store.ThreadMeta{
			ThreadID:           string(entry.ID),
			Title:              entry.Title,
			Cwd:                entry.Cwd,
			ProviderInstanceID: entry.ProviderInstanceID,
			ModelSelection:     entry.ModelSelection,
			CreatedAt:          entry.CreatedAt,
			UpdatedAt:          entry.UpdatedAt,
		}
		if err := w.threads.UpsertThread(meta); err != nil {
			w.logger.Warn("persist thread metadata; will retry on a later flush", "thread", threadID, "error", err)
			failed = append(failed, threadID)
		}
	}
	if len(failed) == 0 {
		return
	}
	// Do not self-wake on failure; retry on the next event or shutdown.
	w.mu.Lock()
	for _, threadID := range failed {
		w.dirty[threadID] = struct{}{}
	}
	w.mu.Unlock()
}
