package provider

import "testing"

func TestToolActionFromNameMatchesWholeWords(t *testing.T) {
	for name, want := range map[string]ToolAction{
		// Claude built-ins not mapped by exact name.
		"PowerShell":           ToolActionExecute,
		"MultiEdit":            ToolActionEdit,
		"CronList":             ToolActionRead,
		"TaskList":             ToolActionRead,
		"ListMcpResourcesTool": ToolActionRead,
		"CronDelete":           ToolActionDelete,
		"TeamDelete":           ToolActionDelete,
		"ToolSearch":           ToolActionSearch,
		"TaskCreate":           ToolActionOther,
		// Codex collaboration and dynamic tools.
		"sendInput":    ToolActionDelegate,
		"spawnAgent":   ToolActionDelegate,
		"exec_command": ToolActionExecute,
		"execute-sql":  ToolActionExecute,
		"HTTPRequest":  ToolActionFetch,
		"fs.read_file": ToolActionRead,
		"files/remove": ToolActionDelete,
		// MCP names whose substrings used to misfire.
		"reddit_search":      ToolActionSearch,
		"credit_charge":      ToolActionOther,
		"dispatch_workflow":  ToolActionOther,
		"set_status":         ToolActionOther,
		"update_state":       ToolActionOther,
		"review_pr":          ToolActionOther,
		"get_overview":       ToolActionOther,
		"global_config":      ToolActionOther,
		"listen":             ToolActionOther,
		"create_thread":      ToolActionOther,
		"spreadsheet_update": ToolActionOther,
		"create_task":        ToolActionOther,
		"send_email":         ToolActionOther,
	} {
		if got := ToolActionFromName(name); got != want {
			t.Errorf("ToolActionFromName(%q) = %q, want %q", name, got, want)
		}
	}
}
