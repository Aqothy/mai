//go:build darwin && cgo

package fff

/*
#cgo CFLAGS: -I${SRCDIR}/../../../third_party/fff/include
#cgo LDFLAGS: -L${SRCDIR}/../../../third_party/fff/lib/darwin-arm64 -lfff_c -Wl,-rpath,${SRCDIR}/../../../third_party/fff/lib/darwin-arm64

#include <stdlib.h>
#include "fff.h"

// maid_fff_create keeps the FffCreateOptions layout in C: designated
// initializers zero every field this build does not set, so upstream
// appending new fields never requires mirroring the struct in Go.
static FffResult *maid_fff_create(const char *base_path) {
	FffCreateOptions opts = {
		.version = FFF_CREATE_OPTIONS_VERSION,
		.base_path = base_path,
		.watch = true,
		.enable_mmap_cache = false,
		.enable_content_indexing = false,
		.ai_mode = false,
		.enable_fs_root_scanning = false,
		.enable_home_dir_scanning = false,
	};
	return fff_create_instance_with(&opts);
}
*/
import "C"

import (
	"context"
	"fmt"
	"runtime"
	"sync"
	"unsafe"
)

// waitSliceMillis bounds each blocking fff_wait_for_scan call so WaitReady
// can observe context cancellation; a native call in progress cannot be
// interrupted.
const waitSliceMillis = 100

type finder struct {
	// mu lets searches run concurrently (the native index synchronizes its
	// own state against the watcher) while Close excludes every native call.
	mu     sync.RWMutex
	handle unsafe.Pointer
	closed bool
}

// New creates a warm path-only index rooted at root and starts its
// asynchronous initial scan. The caller owns the index and must Close it.
func New(root string) (Finder, error) {
	cRoot := C.CString(root)
	defer C.free(unsafe.Pointer(cRoot))
	handle, _, err := consumeResult(C.maid_fff_create(cRoot), "create index")
	if err != nil {
		return nil, err
	}
	if handle == nil {
		return nil, fmt.Errorf("fff: create index returned no instance")
	}
	f := &finder{handle: handle}
	// Leak safety net only; the service owns the explicit Close path.
	runtime.SetFinalizer(f, func(f *finder) { _ = f.Close() })
	return f, nil
}

// consumeResult frees the FffResult envelope and converts it into Go-owned
// values. The returned handle payload (if any) remains owned by the caller
// and must be freed with its type-specific fff_free_* function.
func consumeResult(res *C.FffResult, op string) (unsafe.Pointer, int64, error) {
	if res == nil {
		return nil, 0, fmt.Errorf("fff: %s returned no result", op)
	}
	defer C.fff_free_result(res)
	if !bool(res.success) {
		message := "unknown native error"
		if res.error != nil {
			message = C.GoString(res.error)
		}
		// Deliberately excludes query text and absolute paths.
		return nil, 0, fmt.Errorf("fff: %s failed: %s", op, message)
	}
	return res.handle, int64(res.int_value), nil
}

func (f *finder) WaitReady(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		done, err := f.waitForScanSlice()
		if err != nil {
			return err
		}
		if done {
			return nil
		}
	}
}

func (f *finder) waitForScanSlice() (bool, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	if f.closed {
		return false, ErrClosed
	}
	_, completed, err := consumeResult(C.fff_wait_for_scan(f.handle, waitSliceMillis), "wait for scan")
	if err != nil {
		return false, err
	}
	return completed == 1, nil
}

func (f *finder) SearchFiles(query string, limit int) ([]FileMatch, error) {
	if limit < 1 {
		return nil, fmt.Errorf("fff: search limit must be positive, got %d", limit)
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	if f.closed {
		return nil, ErrClosed
	}
	cQuery := C.CString(query)
	defer C.free(unsafe.Pointer(cQuery))
	handle, _, err := consumeResult(
		C.fff_search(f.handle, cQuery, nil, 0, 0, C.uint32_t(limit), 0, 0),
		"search",
	)
	if err != nil {
		return nil, err
	}
	result := (*C.FffSearchResult)(handle)
	if result == nil {
		return nil, nil
	}
	defer C.fff_free_search_result(result)

	count := int(result.count)
	if count == 0 || result.items == nil {
		return nil, nil
	}
	items := unsafe.Slice(result.items, count)
	matches := make([]FileMatch, 0, count)
	for i := range items {
		matches = append(matches, FileMatch{
			RelativePath: C.GoString(items[i].relative_path),
			DisplayName:  C.GoString(items[i].file_name),
		})
	}
	return matches, nil
}

func (f *finder) ScanProgress() (ScanProgress, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	if f.closed {
		return ScanProgress{}, ErrClosed
	}
	handle, _, err := consumeResult(C.fff_get_scan_progress(f.handle), "scan progress")
	if err != nil {
		return ScanProgress{}, err
	}
	progress := (*C.FffScanProgress)(handle)
	if progress == nil {
		return ScanProgress{}, fmt.Errorf("fff: scan progress returned no payload")
	}
	defer C.fff_free_scan_progress(progress)
	return ScanProgress{
		ScannedFiles: uint64(progress.scanned_files_count),
		Scanning:     bool(progress.is_scanning),
		WatcherReady: bool(progress.is_watcher_ready),
	}, nil
}

func (f *finder) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil
	}
	f.closed = true
	C.fff_destroy(f.handle)
	f.handle = nil
	runtime.SetFinalizer(f, nil)
	return nil
}
