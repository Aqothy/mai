package claudecode

import (
	"encoding/json"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// taskPlan is the plan the CLI keeps with its Task tools (TaskCreate,
// TaskUpdate, TaskList), which replaced TodoWrite. Unlike TodoWrite, whose
// input is the whole list, these change one task at a time and only their
// results carry the task ids, so the list is rebuilt from the results.
type taskPlan struct {
	tasks []planTask
}

type planTask struct {
	id    string
	entry provider.PlanEntry
}

// apply records a plan tool's result and reports whether the plan changed.
func (p *taskPlan) apply(tool string, input, result json.RawMessage) bool {
	switch tool {
	case "TaskCreate":
		var created struct {
			Task struct {
				ID      string `json:"id"`
				Subject string `json:"subject"`
			} `json:"task"`
		}
		if json.Unmarshal(result, &created) != nil || created.Task.ID == "" {
			return false
		}
		p.tasks = append(p.tasks, planTask{id: created.Task.ID, entry: provider.PlanEntry{Content: created.Task.Subject, Status: provider.PlanEntryStatusPending}})
		return true
	case "TaskUpdate":
		var update struct {
			TaskID  string `json:"taskId"`
			Subject string `json:"subject"`
			Status  string `json:"status"`
		}
		var outcome struct {
			Success bool `json:"success"`
		}
		if json.Unmarshal(input, &update) != nil || json.Unmarshal(result, &outcome) != nil || !outcome.Success {
			return false
		}
		index := slices.IndexFunc(p.tasks, func(task planTask) bool { return task.id == update.TaskID })
		if index < 0 {
			return false
		}
		if update.Status == "deleted" {
			p.tasks = slices.Delete(p.tasks, index, index+1)
			return true
		}
		if strings.TrimSpace(update.Subject) != "" {
			p.tasks[index].entry.Content = update.Subject
		}
		if update.Status != "" {
			p.tasks[index].entry.Status = planStatus(update.Status)
		}
		return true
	case "TaskList":
		var list struct {
			Tasks []struct {
				ID      string `json:"id"`
				Subject string `json:"subject"`
				Status  string `json:"status"`
			} `json:"tasks"`
		}
		if json.Unmarshal(result, &list) != nil || list.Tasks == nil {
			return false
		}
		p.tasks = p.tasks[:0]
		for _, task := range list.Tasks {
			p.tasks = append(p.tasks, planTask{id: task.ID, entry: provider.PlanEntry{Content: task.Subject, Status: planStatus(task.Status)}})
		}
		return true
	}
	return false
}

func (p *taskPlan) entries() []provider.PlanEntry {
	entries := make([]provider.PlanEntry, 0, len(p.tasks))
	for _, task := range p.tasks {
		entries = append(entries, task.entry)
	}
	return entries
}

func planStatus(status string) provider.PlanEntryStatus {
	switch status {
	case "in_progress":
		return provider.PlanEntryStatusInProgress
	case "completed":
		return provider.PlanEntryStatusCompleted
	default:
		return provider.PlanEntryStatusPending
	}
}
