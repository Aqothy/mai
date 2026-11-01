package terminal

import (
	"slices"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

// ProgramState is what a terminal's program last reported doing through the
// program status protocol (OSC 7501).
type ProgramState string

const (
	ProgramIdle    ProgramState = "idle"
	ProgramWorking ProgramState = "working"
	ProgramDone    ProgramState = "done"
	ProgramBlocked ProgramState = "blocked"
	ProgramError   ProgramState = "error"
)

// ProgramNeed is what a blocked program needs from the user.
type ProgramNeed string

const (
	ProgramNeedsPermission ProgramNeed = "permission"
	ProgramNeedsAnswer     ProgramNeed = "answer"
	ProgramNeedsAuth       ProgramNeed = "auth"
)

// ProgramStatus is the report a terminal shows for its program. Title and
// Message are the program's own text, sanitized for display outside the
// terminal.
type ProgramStatus struct {
	State ProgramState
	// Need is set only while blocked, and only when the program said.
	Need ProgramNeed
	// Progress is 0-100, or nil when the program gave none.
	Progress  *int
	App       string
	Title     string
	Message   string
	UpdatedAt time.Time
}

// ProgramInfo is what the program running in a terminal says about itself.
type ProgramInfo struct {
	// Title is the normalized OSC 0/2 window title.
	Title string
	// Pwd is the working directory the shell reported (OSC 7).
	Pwd string
	// Status is the most pressing program status record, if any.
	Status *ProgramStatus
}

// maxProgramRecords is the spec's cap: keep at most 256 records, dropping
// the one that changed least recently.
const maxProgramRecords = 256

// programRecords keeps one record per report ID, by the program status
// protocol's rules (libghostty ProgramStatusFunc).
type programRecords map[string]programRecord

type programRecord struct {
	status ProgramStatus
	// app is the record's own App; status.App inherits from parents.
	app string
}

// apply records one report.
func (records programRecords) apply(report vtscreen.ProgramStatus, now time.Time) {
	if report.State == vtscreen.ProgramClear {
		// Clearing an ID clears its children; clearing "" clears all.
		for id := range records {
			if report.ID == "" || id == report.ID || strings.HasPrefix(id, report.ID+"/") {
				delete(records, id)
			}
		}
		return
	}
	status := ProgramStatus{
		State:     programStates[report.State],
		Title:     displayText(report.Title, maxStatusTextScalars),
		Message:   displayText(report.Message, maxStatusTextScalars),
		UpdatedAt: now,
	}
	if status.State == ProgramBlocked {
		status.Need = programNeeds[report.Kind]
	}
	if report.Progress >= 0 {
		progress := report.Progress
		status.Progress = &progress
	}
	if _, exists := records[report.ID]; !exists && len(records) >= maxProgramRecords {
		oldest := ""
		for id, record := range records {
			if oldest == "" || record.status.UpdatedAt.Before(records[oldest].status.UpdatedAt) {
				oldest = id
			}
		}
		delete(records, oldest)
	}
	// A new report replaces the record entirely.
	records[report.ID] = programRecord{status: status, app: displayText(report.App, maxStatusTextScalars)}
}

// remove drops the records in the given states: working and blocked ones
// when a new prompt appears or the run ends, done and error ones once the
// user has seen them.
func (records programRecords) remove(states ...ProgramState) {
	for id, record := range records {
		if slices.Contains(states, record.status.State) {
			delete(records, id)
		}
	}
}

// pressing is the record most worth the user's attention: blocked, then
// failed, finished, working and idle, the latest first among equals.
func (records programRecords) pressing() *ProgramStatus {
	var best *ProgramStatus
	var bestID string
	for id, record := range records {
		status := record.status
		if best == nil || programUrgency[status.State] > programUrgency[best.State] ||
			(programUrgency[status.State] == programUrgency[best.State] && status.UpdatedAt.After(best.UpdatedAt)) {
			best, bestID = &status, id
		}
	}
	if best != nil {
		best.App = records.app(bestID)
	}
	return best
}

// app is a record's App, or its closest parent's: "us-east" without one
// uses "" (the program's own record), "build/test" uses "build".
func (records programRecords) app(id string) string {
	for {
		if record, ok := records[id]; ok && record.app != "" {
			return record.app
		}
		if id == "" {
			return ""
		}
		if slash := strings.LastIndexByte(id, '/'); slash >= 0 {
			id = id[:slash]
		} else {
			id = ""
		}
	}
}

var programStates = map[vtscreen.ProgramState]ProgramState{
	vtscreen.ProgramIdle:    ProgramIdle,
	vtscreen.ProgramWorking: ProgramWorking,
	vtscreen.ProgramDone:    ProgramDone,
	vtscreen.ProgramBlocked: ProgramBlocked,
	vtscreen.ProgramError:   ProgramError,
}

var programNeeds = map[vtscreen.ProgramKind]ProgramNeed{
	vtscreen.ProgramNeedsPermission: ProgramNeedsPermission,
	vtscreen.ProgramNeedsAnswer:     ProgramNeedsAnswer,
	vtscreen.ProgramNeedsAuth:       ProgramNeedsAuth,
}

var programUrgency = map[ProgramState]int{
	ProgramIdle:    0,
	ProgramWorking: 1,
	ProgramDone:    2,
	ProgramError:   3,
	ProgramBlocked: 4,
}
