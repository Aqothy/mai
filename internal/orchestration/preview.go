package orchestration

import "github.com/Aqothy/maiD/internal/provider"

const (
	maxToolSummaryEntries     = 20
	maxToolSummaryFieldRunes  = 512
	maxToolSummaryOutputRunes = 1024
)

// ToolCallSummary is the bounded form of a tool call that snapshots and live
// events carry. The whole call is a ThreadEntry read away.
type ToolCallSummary struct {
	Action               provider.ToolAction     `json:"action,omitempty"`
	Name                 string                  `json:"name,omitempty"`
	Namespace            string                  `json:"namespace,omitempty"`
	ProviderKind         string                  `json:"providerKind,omitempty"`
	CommandPreview       string                  `json:"commandPreview,omitempty"`
	QueryPreview         string                  `json:"queryPreview,omitempty"`
	Cwd                  string                  `json:"cwd,omitempty"`
	OutputPreview        string                  `json:"outputPreview,omitempty"`
	OutputFormat         provider.OutputFormat   `json:"outputFormat,omitempty"`
	ErrorPreview         string                  `json:"errorPreview,omitempty"`
	Locations            []provider.ToolLocation `json:"locations,omitempty"`
	LocationCount        int                     `json:"locationCount,omitempty"`
	Changes              []FileChangeSummary     `json:"changes,omitempty"`
	ChangeCount          int                     `json:"changeCount,omitempty"`
	Attachments          []ToolAttachmentSummary `json:"attachments,omitempty"`
	AttachmentCount      int                     `json:"attachmentCount,omitempty"`
	ExitCode             *int                    `json:"exitCode,omitempty"`
	DurationMilliseconds *int64                  `json:"durationMilliseconds,omitempty"`
	// Background: the call runs on as a background task; while it runs,
	// clients offer to stop it.
	Background bool `json:"background,omitempty"`
	Truncated  bool `json:"truncated,omitempty"`
}

// FileChangeSummary leaves out the diff and the file's text.
type FileChangeSummary struct {
	Path     string                  `json:"path"`
	Kind     provider.FileChangeKind `json:"kind,omitempty"`
	MovePath string                  `json:"movePath,omitempty"`
}

// ToolAttachmentSummary leaves out the data.
type ToolAttachmentSummary struct {
	Kind     provider.AttachmentKind `json:"kind"`
	Name     string                  `json:"name,omitempty"`
	MimeType string                  `json:"mimeType,omitempty"`
	URI      string                  `json:"uri,omitempty"`
}

func summarizeToolCall(call *provider.ToolCall) *ToolCallSummary {
	if call == nil {
		return nil
	}
	summary := &ToolCallSummary{
		Action:               call.Action,
		OutputFormat:         call.OutputFormat,
		LocationCount:        len(call.Locations),
		ChangeCount:          len(call.Changes),
		AttachmentCount:      len(call.Attachments),
		ExitCode:             clonePtr(call.ExitCode),
		DurationMilliseconds: clonePtr(call.DurationMilliseconds),
		Background:           call.Background,
	}
	summary.Name, summary.Truncated = boundedPreview(call.Name, maxToolSummaryFieldRunes, summary.Truncated)
	summary.Namespace, summary.Truncated = boundedPreview(call.Namespace, maxToolSummaryFieldRunes, summary.Truncated)
	summary.ProviderKind, summary.Truncated = boundedPreview(call.ProviderKind, maxToolSummaryFieldRunes, summary.Truncated)
	summary.Cwd, summary.Truncated = boundedPreview(call.Cwd, maxToolSummaryFieldRunes, summary.Truncated)
	summary.CommandPreview, summary.Truncated = boundedPreview(call.Command, maxToolSummaryFieldRunes, summary.Truncated)
	summary.QueryPreview, summary.Truncated = boundedPreview(call.Query, maxToolSummaryFieldRunes, summary.Truncated)
	summary.OutputPreview, summary.Truncated = boundedPreview(call.Output, maxToolSummaryOutputRunes, summary.Truncated)
	summary.ErrorPreview, summary.Truncated = boundedPreview(call.Error, maxToolSummaryFieldRunes, summary.Truncated)

	locationLimit := min(len(call.Locations), maxToolSummaryEntries)
	summary.Locations = make([]provider.ToolLocation, locationLimit)
	for index := range locationLimit {
		summary.Locations[index] = call.Locations[index]
		var truncated bool
		summary.Locations[index].Path, truncated = truncateRunes(call.Locations[index].Path, maxToolSummaryFieldRunes)
		summary.Truncated = summary.Truncated || truncated
		summary.Locations[index].Line = clonePtr(call.Locations[index].Line)
	}
	summary.Truncated = summary.Truncated || locationLimit < len(call.Locations)

	changeLimit := min(len(call.Changes), maxToolSummaryEntries)
	summary.Changes = make([]FileChangeSummary, changeLimit)
	for index := range changeLimit {
		change := call.Changes[index]
		path, pathTruncated := truncateRunes(change.Path, maxToolSummaryFieldRunes)
		movePath, movePathTruncated := truncateRunes(change.MovePath, maxToolSummaryFieldRunes)
		summary.Changes[index] = FileChangeSummary{Path: path, Kind: change.Kind, MovePath: movePath}
		summary.Truncated = summary.Truncated || pathTruncated || movePathTruncated
	}
	summary.Truncated = summary.Truncated || changeLimit < len(call.Changes)

	attachmentLimit := min(len(call.Attachments), maxToolSummaryEntries)
	summary.Attachments = make([]ToolAttachmentSummary, attachmentLimit)
	for index := range attachmentLimit {
		attachment := call.Attachments[index]
		name, nameTruncated := truncateRunes(attachment.Name, maxToolSummaryFieldRunes)
		mimeType, mimeTypeTruncated := truncateRunes(attachment.MimeType, maxToolSummaryFieldRunes)
		uri, uriTruncated := truncateRunes(attachment.URI, maxToolSummaryFieldRunes)
		summary.Attachments[index] = ToolAttachmentSummary{Kind: attachment.Kind, Name: name, MimeType: mimeType, URI: uri}
		summary.Truncated = summary.Truncated || nameTruncated || mimeTypeTruncated || uriTruncated
	}
	summary.Truncated = summary.Truncated || attachmentLimit < len(call.Attachments)
	return summary
}

func boundedPreview(value string, limit int, alreadyTruncated bool) (string, bool) {
	preview, truncated := truncateRunes(value, limit)
	return preview, alreadyTruncated || truncated
}

func truncateRunes(value string, limit int) (string, bool) {
	if value == "" || len(value) <= limit {
		return value, false
	}
	runes := 0
	for index := range value {
		if runes == limit {
			return value[:index], true
		}
		runes++
	}
	return value, false
}

func clonePtr[T any](value *T) *T {
	if value == nil {
		return nil
	}
	copied := *value
	return &copied
}
