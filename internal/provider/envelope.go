package provider

import (
	"strconv"
	"strings"
	"time"
)

// A message maiD sends a session is its envelopes, each a block
//
//	<orchestrator kind="message" id="…" from="…" thread="…">
//	…body…
//	</orchestrator>
//
// followed by a blank line, then a person's own text, as written. A tagged
// block is how the harnesses mark what they write into a conversation
// themselves (Claude Code's <task-notification>, Codex's
// <environment_context>): models read it as structure, not as the user's
// words, and it parses back out exactly, live and after a rebuild. Attribute
// values escape &, ", < and newlines as character references; a body escapes
// "</orchestrator>" as "<\/orchestrator>", so nothing inside ends it early.
// Adapters split envelopes back out of user messages (UserMessageEntries).
const (
	envelopeOpen    = "<orchestrator "
	envelopeClose   = "</orchestrator>"
	envelopeEscaped = `<\/orchestrator>`
)

// envelopeAttributes are an envelope's attributes in the order written.
var envelopeAttributes = []struct {
	name  string
	field func(*Envelope) *string
}{
	{"kind", func(e *Envelope) *string { return (*string)(&e.Kind) }},
	{"id", func(e *Envelope) *string { return &e.Delivery }},
	{"from", func(e *Envelope) *string { return &e.From }},
	{"thread", func(e *Envelope) *string { return &e.Thread }},
	{"covers", func(e *Envelope) *string { return &e.Covers }},
	{"answers", func(e *Envelope) *string { return &e.Answers }},
}

var attributeEscaper = strings.NewReplacer("&", "&amp;", `"`, "&quot;", "<", "&lt;", "\n", "&#10;")
var attributeUnescaper = strings.NewReplacer("&quot;", `"`, "&lt;", "<", "&#10;", "\n", "&amp;", "&")

// ComposeMessage is the text of a message: the envelopes, then text.
func ComposeMessage(envelopes []Envelope, text string) string {
	var message strings.Builder
	for _, envelope := range envelopes {
		message.WriteString(envelopeOpen[:len(envelopeOpen)-1])
		for _, attribute := range envelopeAttributes {
			if value := *attribute.field(&envelope); value != "" {
				message.WriteString(" " + attribute.name + `="` + attributeEscaper.Replace(value) + `"`)
			}
		}
		message.WriteString(">\n")
		message.WriteString(strings.ReplaceAll(envelope.Body, envelopeClose, envelopeEscaped))
		message.WriteString("\n" + envelopeClose + "\n\n")
	}
	message.WriteString(text)
	return message.String()
}

// SplitMessage undoes ComposeMessage: the leading envelopes of a message's
// text and the text after them.
func SplitMessage(text string) ([]Envelope, string) {
	var envelopes []Envelope
	rest := text
	for strings.HasPrefix(rest, envelopeOpen) {
		header, after, ok := strings.Cut(rest[len(envelopeOpen):], ">\n")
		if !ok {
			break
		}
		envelope, ok := parseEnvelopeAttributes(header)
		if !ok {
			break
		}
		body, remaining, ok := strings.Cut(after, "\n"+envelopeClose)
		if !ok {
			// An empty body has no line of its own.
			if remaining, ok = strings.CutPrefix(after, envelopeClose); !ok {
				break
			}
			body = ""
		}
		envelope.Body = strings.ReplaceAll(body, envelopeEscaped, envelopeClose)
		envelopes = append(envelopes, envelope)
		rest = strings.TrimPrefix(strings.TrimPrefix(remaining, "\n"), "\n")
	}
	if len(envelopes) == 0 {
		return nil, text
	}
	return envelopes, rest
}

func parseEnvelopeAttributes(header string) (Envelope, bool) {
	var envelope Envelope
	for header = strings.TrimSpace(header); header != ""; header = strings.TrimSpace(header) {
		name, after, ok := strings.Cut(header, `="`)
		if !ok {
			return Envelope{}, false
		}
		value, remaining, ok := strings.Cut(after, `"`)
		if !ok {
			return Envelope{}, false
		}
		header = remaining
		for _, attribute := range envelopeAttributes {
			if attribute.name == name {
				*attribute.field(&envelope) = attributeUnescaper.Replace(value)
			}
		}
	}
	return envelope, envelope.Kind != ""
}

// UserMessageEntries are the entries of a user message whose native ref is
// ref: an envelope entry for each envelope (ref#1, ref#2, …), then the
// person's text under ref itself, when there is any.
func UserMessageEntries(ref, turn, text string, attachments []Attachment, delivery string, at time.Time) []Entry {
	envelopes, rest := SplitMessage(text)
	var entries []Entry
	for index, envelope := range envelopes {
		envelope := envelope
		entries = append(entries, Entry{
			Ref: ref + "#" + strconv.Itoa(index+1), Turn: turn, Kind: ItemKindEnvelope, Status: ItemStatusCompleted,
			Envelope: &envelope, Delivery: firstNonEmpty(envelope.Delivery, delivery), At: at,
		})
	}
	if rest != "" || len(attachments) > 0 || len(envelopes) == 0 {
		entries = append(entries, Entry{
			Ref: ref, Turn: turn, Kind: ItemKindUserMessage, Status: ItemStatusCompleted,
			Text: rest, Attachments: attachments, Delivery: delivery, At: at,
		})
	}
	return entries
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
