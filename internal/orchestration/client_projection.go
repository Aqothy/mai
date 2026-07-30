package orchestration

import "github.com/Aqothy/maiD/internal/provider"

const (
	maxToolSummaryEntries     = 20
	maxToolSummaryFieldRunes  = 512
	maxToolSummaryOutputRunes = 1024
)

// projectThreadForClient builds a compact snapshot without first cloning the
// complete tool payloads that it will omit.
func projectThreadForClient(thread Thread) Thread {
	projected := thread
	projected.ModelSelection = cloneModelSelection(thread.ModelSelection)
	projected.ConfigSelections = nil
	projected.Session = cloneSessionPtr(thread.Session)
	projected.LatestTurn = cloneTurnPtr(thread.LatestTurn)
	projected.Plan = clonePlanPtr(thread.Plan)
	projected.Timeline = make(Timeline, len(thread.Timeline))

	for index, entry := range thread.Timeline {
		projectedEntry := TimelineEntry{Kind: entry.Kind}
		if entry.Message != nil {
			message := *entry.Message
			message.Attachments = cloneAttachments(entry.Message.Attachments)
			projectedEntry.Message = &message
		}
		if entry.Item != nil {
			item := projectItemForClient(*entry.Item)
			projectedEntry.Item = &item
		}
		if entry.Approval != nil {
			approval := *entry.Approval
			approval.Args = cloneRawMessage(entry.Approval.Args)
			approval.Options = append([]provider.ApprovalOption(nil), entry.Approval.Options...)
			projectedEntry.Approval = &approval
		}
		projected.Timeline[index] = projectedEntry
	}
	return projected
}

// ProjectEventForClient applies the same compact item representation to live
// notifications as thread snapshots. The canonical event remains untouched.
func ProjectEventForClient(event Event) Event {
	if event.Payload.Item == nil {
		return event
	}
	item := projectItemForClient(*event.Payload.Item)
	event.Payload.Item = &item
	return event
}

func projectItemForClient(item Item) Item {
	// Sparse upserts may omit Kind, but the presence of a complete ToolCall is
	// sufficient to enforce the compact wire boundary.
	if !isToolItem(item.Kind) && item.ToolCall == nil {
		item.DetailAvailable = false
		item.ToolCallSummary = nil
		item.Payload = cloneRawMessage(item.Payload)
		return item
	}

	var titleTruncated bool
	item.Title, titleTruncated = truncateRunes(item.Title, maxToolSummaryFieldRunes)
	item.DetailAvailable = item.ToolCall != nil || len(item.Payload) > 0 || titleTruncated
	item.ToolCallSummary = summarizeToolCall(item.ToolCall)
	if item.ToolCallSummary != nil {
		item.ToolCallSummary.Truncated = item.ToolCallSummary.Truncated || titleTruncated
	}
	item.ToolCall = nil
	item.Payload = nil
	return item
}

func isToolItem(kind provider.ItemKind) bool {
	switch kind {
	case provider.ItemKindCommandExecution,
		provider.ItemKindFileChange,
		provider.ItemKindMCPToolCall,
		provider.ItemKindToolCall:
		return true
	default:
		return false
	}
}

func summarizeToolCall(call *provider.ToolCall) *ToolCallSummary {
	if call == nil {
		return nil
	}
	summary := &ToolCallSummary{
		Action:               call.Action,
		LocationCount:        len(call.Locations),
		ChangeCount:          len(call.Changes),
		AttachmentCount:      len(call.Attachments),
		ExitCode:             cloneIntPtr(call.ExitCode),
		DurationMilliseconds: cloneInt64Ptr(call.DurationMilliseconds),
	}
	summary.Name, summary.Truncated = boundedPreview(
		call.Name,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)
	summary.Namespace, summary.Truncated = boundedPreview(
		call.Namespace,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)
	summary.ProviderKind, summary.Truncated = boundedPreview(
		call.ProviderKind,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)
	summary.Cwd, summary.Truncated = boundedPreview(
		call.Cwd,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)
	summary.CommandPreview, summary.Truncated = boundedPreview(
		call.Command,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)
	summary.QueryPreview, summary.Truncated = boundedPreview(
		call.Query,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)
	summary.OutputPreview, summary.Truncated = boundedPreview(
		call.Output,
		maxToolSummaryOutputRunes,
		summary.Truncated,
	)
	summary.ErrorPreview, summary.Truncated = boundedPreview(
		call.Error,
		maxToolSummaryFieldRunes,
		summary.Truncated,
	)

	locationLimit := min(len(call.Locations), maxToolSummaryEntries)
	summary.Locations = make([]provider.ToolLocation, locationLimit)
	for index := range locationLimit {
		summary.Locations[index] = call.Locations[index]
		var truncated bool
		summary.Locations[index].Path, truncated = truncateRunes(
			call.Locations[index].Path,
			maxToolSummaryFieldRunes,
		)
		summary.Truncated = summary.Truncated || truncated
		summary.Locations[index].Line = cloneUint32Ptr(call.Locations[index].Line)
	}
	summary.Truncated = summary.Truncated || locationLimit < len(call.Locations)

	changeLimit := min(len(call.Changes), maxToolSummaryEntries)
	summary.Changes = make([]FileChangeSummary, changeLimit)
	for index := range changeLimit {
		change := call.Changes[index]
		path, pathTruncated := truncateRunes(change.Path, maxToolSummaryFieldRunes)
		movePath, movePathTruncated := truncateRunes(change.MovePath, maxToolSummaryFieldRunes)
		summary.Changes[index] = FileChangeSummary{
			Path:     path,
			Kind:     change.Kind,
			MovePath: movePath,
		}
		summary.Truncated = summary.Truncated || pathTruncated || movePathTruncated
	}
	summary.Truncated = summary.Truncated || changeLimit < len(call.Changes)

	attachmentLimit := min(len(call.Attachments), maxToolSummaryEntries)
	summary.Attachments = make([]ToolAttachmentSummary, attachmentLimit)
	for index := range attachmentLimit {
		attachment := call.Attachments[index]
		kind, kindTruncated := truncateRunes(attachment.Kind, maxToolSummaryFieldRunes)
		name, nameTruncated := truncateRunes(attachment.Name, maxToolSummaryFieldRunes)
		mimeType, mimeTypeTruncated := truncateRunes(
			attachment.MimeType,
			maxToolSummaryFieldRunes,
		)
		uri, truncated := truncateRunes(attachment.URI, maxToolSummaryFieldRunes)
		summary.Attachments[index] = ToolAttachmentSummary{
			Kind:     kind,
			Name:     name,
			MimeType: mimeType,
			URI:      uri,
		}
		summary.Truncated = summary.Truncated ||
			kindTruncated ||
			nameTruncated ||
			mimeTypeTruncated ||
			truncated
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
