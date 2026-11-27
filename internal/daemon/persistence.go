package daemon

import (
	"fmt"
	"os"
	"path/filepath"
)

func maidDataDir() (string, error) {
	if dir := os.Getenv("MAID_DATA_DIR"); dir != "" {
		// Absolute, since agents run elsewhere and are given paths inside it.
		return filepath.Abs(dir)
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user config dir: %w", err)
	}
	return filepath.Join(base, "maiD"), nil
}
