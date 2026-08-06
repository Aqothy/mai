// Command fff-smoke proves the vendored FFF dylib loads and serves a real
// search through internal/workspacesearch/fff. `make fff-verify` stages this
// binary next to the dylib in an empty directory to verify relocatable
// (@loader_path) loading outside the repository.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Aqothy/maiD/internal/workspacesearch/fff"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fff smoke failed:", err)
		os.Exit(1)
	}
	fmt.Println("fff smoke OK")
}

func run() error {
	root, err := os.MkdirTemp("", "fff-smoke-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	if root, err = filepath.EvalSymlinks(root); err != nil {
		return err
	}
	fixture := filepath.Join(root, "src", "smoke_target.go")
	if err := os.MkdirAll(filepath.Dir(fixture), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(fixture, []byte("package src\n"), 0o644); err != nil {
		return err
	}

	finder, err := fff.New(root)
	if err != nil {
		return err
	}
	defer finder.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := finder.WaitReady(ctx); err != nil {
		return fmt.Errorf("wait for scan: %w", err)
	}
	matches, err := finder.SearchFiles("smoketarget", 10)
	if err != nil {
		return fmt.Errorf("search: %w", err)
	}
	if len(matches) == 0 || matches[0].RelativePath != "src/smoke_target.go" {
		return fmt.Errorf("expected src/smoke_target.go, got %v", matches)
	}
	progress, err := finder.ScanProgress()
	if err != nil {
		return fmt.Errorf("scan progress: %w", err)
	}
	if progress.ScannedFiles == 0 {
		return fmt.Errorf("expected non-zero scanned file count")
	}
	return finder.Close()
}
