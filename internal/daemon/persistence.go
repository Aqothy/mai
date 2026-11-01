package daemon

import (
	"fmt"
	"os"
	"path/filepath"
)

func maidDataDir() (string, error) {
	if dir := os.Getenv("MAID_DATA_DIR"); dir != "" {
		return dir, nil
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user config dir: %w", err)
	}
	return filepath.Join(base, "maiD"), nil
}
