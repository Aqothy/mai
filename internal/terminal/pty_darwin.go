//go:build darwin

package terminal

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

const (
	terminateSignal = syscall.SIGTERM
	killSignal      = syscall.SIGKILL
)

// signalProcessGroup signals the whole process group led by pgid. The shell is
// started with Setsid, so its pid is also its group id.
func signalProcessGroup(pgid int, sig syscall.Signal) {
	_ = syscall.Kill(-pgid, sig)
}

// foregroundProcessGroup reports the PTY's current foreground process group.
// Job control gives foreground jobs their own group, so terminating only the
// shell's group would orphan a running vim or sleep.
func foregroundProcessGroup(ptyFile *os.File) (int, bool) {
	if ptyFile == nil {
		return 0, false
	}
	pgid, err := unix.IoctlGetInt(int(ptyFile.Fd()), unix.TIOCGPGRP)
	if err != nil || pgid <= 0 {
		return 0, false
	}
	return pgid, true
}
