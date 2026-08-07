//go:build darwin

package terminal

import (
	"os/exec"
	"strconv"
	"strings"
)

// inspectProcessGroup lists the processes of one process group with a single
// /bin/ps invocation. The detector calls it only when the PTY's foreground
// group changes, never per output chunk or per scan.
func inspectProcessGroup(pgid int) []processInfo {
	out, err := exec.Command("/bin/ps", "-axww", "-o", "pgid=,pid=,args=").Output()
	if err != nil {
		return nil
	}
	var processes []processInfo
	for line := range strings.Lines(string(out)) {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		linePGID, err := strconv.Atoi(fields[0])
		if err != nil || linePGID != pgid {
			continue
		}
		pid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		processes = append(processes, processInfo{pid: pid, argv: fields[2:]})
	}
	return processes
}
