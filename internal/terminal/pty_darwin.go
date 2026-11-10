//go:build darwin

package terminal

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
)

const (
	hangupSignal    = syscall.SIGHUP
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

// startPTY starts cmd on a new PTY of the given size and returns the PTY's
// master. The child leads its own session (Setsid) with the PTY as its
// controlling terminal, so group signals reach every descendant.
//
// The master is nonblocking, so a read can tell that the PTY has run dry
// (EAGAIN), and it stays out of Go's netpoller: kqueue would post an event
// for every write the program makes, and waking the runtime for each one
// added about 60% to the CPU a flood of output costs. readPTY and writePTY
// wait in poll only when they must.
func startPTY(cmd *exec.Cmd, columns, rows uint16) (*os.File, error) {
	master, tty, err := pty.Open()
	if err != nil {
		return nil, err
	}
	defer tty.Close()
	if err := setupPTY(tty, columns, rows); err != nil {
		_ = master.Close()
		return nil, err
	}
	if err := unix.SetNonblock(int(master.Fd()), true); err != nil {
		_ = master.Close()
		return nil, fmt.Errorf("pty nonblocking: %w", err)
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = tty, tty, tty
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true}
	if err := cmd.Start(); err != nil {
		_ = master.Close()
		return nil, err
	}
	return master, nil
}

// setupPTY sizes the terminal and turns on UTF-8 input, before the program
// starts and records the terminal's modes. macOS PTYs start without IUTF8,
// so erasing in line input would remove one byte of a multibyte character
// (Ghostty's pty.zig sets it for the same reason).
func setupPTY(tty *os.File, columns, rows uint16) error {
	if err := pty.Setsize(tty, &pty.Winsize{Rows: rows, Cols: columns}); err != nil {
		return err
	}
	fd := int(tty.Fd())
	termios, err := unix.IoctlGetTermios(fd, unix.TIOCGETA)
	if err != nil {
		return err
	}
	termios.Iflag |= unix.IUTF8
	return unix.IoctlSetTermios(fd, unix.TIOCSETA, termios)
}

// idleReads is how many reads in a row must find the PTY empty before the
// program counts as idle. A PTY read returns at most the kernel's ~1 KB
// buffer, and a program that is streaming refills it within microseconds,
// so an empty read alone doesn't mean the program has stopped. Retrying
// keeps its output in one burst; a program that has stopped is noticed
// after well under a tenth of a millisecond of empty reads.
const idleReads = 32

// readPTY reads what the PTY holds into buf. With wait, it waits for output;
// without, it returns 0 and no error once idleReads reads in a row find the
// PTY empty. The error is io.EOF or EIO once the program's side of the PTY
// is gone. Control keeps the descriptor open until the read returns.
func readPTY(raw syscall.RawConn, buf []byte, wait bool) (n int, err error) {
	controlErr := raw.Control(func(fd uintptr) {
		for empty := 0; ; {
			m, readErr := unix.Read(int(fd), buf)
			switch {
			case m > 0:
				n = m
				return
			case readErr == unix.EINTR:
			case readErr == unix.EAGAIN && wait:
				if err = waitPTY(int(fd), unix.POLLIN); err != nil {
					return
				}
			case readErr == unix.EAGAIN:
				if empty++; empty == idleReads {
					return
				}
			case readErr == nil:
				err = io.EOF
				return
			default:
				err = readErr
				return
			}
		}
	})
	if controlErr != nil {
		return 0, controlErr
	}
	return n, err
}

// writePTY writes all of data to the PTY, waiting while the program has not
// read what is already there. It ends with EIO once the program's side of
// the PTY is gone. Control keeps the descriptor open until the write returns.
func writePTY(raw syscall.RawConn, data []byte) (err error) {
	controlErr := raw.Control(func(fd uintptr) {
		for len(data) > 0 {
			m, writeErr := unix.Write(int(fd), data)
			switch {
			case m > 0:
				data = data[m:]
			case writeErr == unix.EINTR:
			case writeErr == unix.EAGAIN:
				if err = waitPTY(int(fd), unix.POLLOUT); err != nil {
					return
				}
			default:
				err = writeErr
				return
			}
		}
	})
	if controlErr != nil {
		return controlErr
	}
	return err
}

// waitPTY blocks until the PTY is ready for events or its program's side is
// gone, which poll also reports.
func waitPTY(fd int, events int16) error {
	fds := []unix.PollFd{{Fd: int32(fd), Events: events}}
	for {
		if _, err := unix.Poll(fds, -1); err != unix.EINTR {
			return err
		}
	}
}
