// Package elicitation converts MCP-style elicitations into provider-neutral
// user-input requests and converts the user's answers back. ACP agents,
// Claude Code (for MCP servers) and Codex app-server all ask with the same
// shape: a message plus either a flat form schema or a URL to open.
package elicitation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strconv"

	"github.com/Aqothy/maiD/internal/provider"
)

// Action is the response action every protocol shares.
type Action string

const (
	ActionAccept  Action = "accept"
	ActionDecline Action = "decline"
	ActionCancel  Action = "cancel"
)

// ActionFor maps the user's decision to a response action.
func ActionFor(decision provider.ApprovalDecision) Action {
	switch decision {
	case provider.ApprovalDecisionAccept:
		return ActionAccept
	case provider.ApprovalDecisionDecline:
		return ActionDecline
	default:
		return ActionCancel
	}
}

// Decision is the decision an action records on the request.
func (a Action) Decision() provider.ApprovalDecision {
	switch a {
	case ActionAccept:
		return provider.ApprovalDecisionAccept
	case ActionDecline:
		return provider.ApprovalDecisionDecline
	default:
		return provider.ApprovalDecisionCancel
	}
}

// Form is a form-mode request's schema, kept to convert answers back.
type Form struct {
	properties map[string]property
	order      []string
	required   []string
}

// Confirms reports whether the form asks for nothing, only yes or no. A URL
// elicitation has no form.
func (f *Form) Confirms() bool {
	return f != nil && len(f.order) == 0
}

type property struct {
	Type        string          `json:"type"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	Enum        []string        `json:"enum"`
	EnumNames   []string        `json:"enumNames"`
	OneOf       []titledOption  `json:"oneOf"`
	Items       *items          `json:"items"`
	Default     json.RawMessage `json:"default"`
	Minimum     *float64        `json:"minimum"`
	Maximum     *float64        `json:"maximum"`
	MinLength   *int            `json:"minLength"`
	MaxLength   *int            `json:"maxLength"`
	MinItems    *int            `json:"minItems"`
	MaxItems    *int            `json:"maxItems"`
}

type items struct {
	Enum  []string       `json:"enum"`
	AnyOf []titledOption `json:"anyOf"`
}

type titledOption struct {
	Const       string `json:"const"`
	Title       string `json:"title"`
	Description string `json:"description"`
}

// RequestPayload is how a parsed elicitation opens. A form that asks for
// nothing only asks yes or no: MCP servers confirm actions this way, and
// Codex asks every MCP tool approval this way (codex-rs/core/src/
// mcp_tool_call.rs, build_mcp_tool_approval_elicitation_request). It opens as
// a permission request whose args are the raw request, like other approvals,
// offering Allow, then the harness's ways to keep allowing (remember), then
// Decline. Anything else opens as questions.
func RequestPayload(request provider.UserInputRequest, form *Form, raw json.RawMessage, remember ...provider.ApprovalOption) provider.RuntimeEventPayload {
	if !form.Confirms() {
		return provider.RuntimeEventPayload{UserInput: &request}
	}
	options := []provider.ApprovalOption{{ID: string(ActionAccept), Name: "Allow", Kind: "allow_once"}}
	options = append(options, remember...)
	options = append(options, provider.ApprovalOption{ID: string(ActionDecline), Name: "Decline", Kind: "reject_once"})
	return provider.RuntimeEventPayload{Args: append(json.RawMessage(nil), raw...), Options: options}
}

// Parse converts an elicitation into a user-input request. Form mode returns
// the form needed to convert answers; URL mode accepts only http(s) URLs.
func Parse(message, mode, rawURL string, requestedSchema json.RawMessage) (provider.UserInputRequest, *Form, error) {
	request := provider.UserInputRequest{Message: message}
	switch mode {
	case "url":
		target, err := url.Parse(rawURL)
		if err != nil || (target.Scheme != "https" && target.Scheme != "http") || target.Host == "" {
			return request, nil, fmt.Errorf("elicitation URL must be an http(s) URL")
		}
		request.URL = target.String()
		return request, nil, nil
	case "form", "":
		form, err := parseForm(requestedSchema)
		if err != nil {
			return request, nil, err
		}
		for _, id := range form.order {
			question, err := form.question(id)
			if err != nil {
				return request, nil, err
			}
			request.Questions = append(request.Questions, question)
		}
		return request, form, nil
	default:
		return request, nil, fmt.Errorf("elicitation mode %q is not supported", mode)
	}
}

func parseForm(raw json.RawMessage) (*Form, error) {
	var schema struct {
		Properties map[string]property `json:"properties"`
		Required   []string            `json:"required"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &schema) != nil {
		return nil, fmt.Errorf("form elicitation requires a requestedSchema object")
	}
	return &Form{properties: schema.Properties, order: propertyOrder(raw), required: schema.Required}, nil
}

// propertyOrder lists the schema's property names in the order they were
// written; Go maps don't keep it.
func propertyOrder(raw json.RawMessage) []string {
	var schema struct {
		Properties json.RawMessage `json:"properties"`
	}
	if json.Unmarshal(raw, &schema) != nil {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(schema.Properties))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil
	}
	var keys []string
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return keys
		}
		key, _ := token.(string)
		keys = append(keys, key)
		var skip json.RawMessage
		if decoder.Decode(&skip) != nil {
			return keys
		}
	}
	return keys
}

func (f *Form) question(id string) (provider.Question, error) {
	p := f.properties[id]
	question := provider.Question{ID: id, Title: p.Title, Description: p.Description, Required: slices.Contains(f.required, id)}
	if question.Title == "" {
		question.Title = id
	}
	switch p.Type {
	case "string":
		question.Kind = provider.QuestionKindText
		if options := p.options(); len(options) > 0 {
			question.Kind = provider.QuestionKindChoice
			question.Options = options
		}
		var value string
		if json.Unmarshal(p.Default, &value) == nil {
			question.Default = []string{value}
		}
	case "number", "integer":
		question.Kind = provider.QuestionKindNumber
		if p.Type == "integer" {
			question.Kind = provider.QuestionKindInteger
		}
		var value float64
		if json.Unmarshal(p.Default, &value) == nil {
			question.Default = []string{strconv.FormatFloat(value, 'f', -1, 64)}
		}
	case "boolean":
		question.Kind = provider.QuestionKindChoice
		question.Options = []provider.QuestionOption{{Value: "true", Label: "Yes"}, {Value: "false", Label: "No"}}
		var value bool
		if json.Unmarshal(p.Default, &value) == nil {
			question.Default = []string{strconv.FormatBool(value)}
		}
	case "array":
		question.Kind = provider.QuestionKindChoice
		question.MultiSelect = true
		question.Options = p.options()
		var values []string
		if json.Unmarshal(p.Default, &values) == nil {
			question.Default = values
		}
	default:
		return question, fmt.Errorf("property %q has unsupported type %q", id, p.Type)
	}
	if question.Kind == provider.QuestionKindChoice && len(question.Options) == 0 {
		return question, fmt.Errorf("choice property %q offers no options", id)
	}
	return question, nil
}

// options lists a choice property's options from any of MCP's enum forms:
// enum (optionally titled by the legacy enumNames), oneOf, or for arrays
// items.enum / items.anyOf.
func (p property) options() []provider.QuestionOption {
	values, titled := p.Enum, p.OneOf
	if p.Type == "array" {
		if p.Items == nil {
			return nil
		}
		values, titled = p.Items.Enum, p.Items.AnyOf
	}
	options := make([]provider.QuestionOption, 0, len(values)+len(titled))
	for index, value := range values {
		label := value
		if p.Type != "array" && index < len(p.EnumNames) {
			label = p.EnumNames[index]
		}
		options = append(options, provider.QuestionOption{Value: value, Label: label})
	}
	for _, option := range titled {
		options = append(options, provider.QuestionOption{Value: option.Const, Label: option.Title, Description: option.Description})
	}
	return options
}

// Content converts answers into the typed content the form asked for,
// validating them so a bad answer is reported to the user instead of being
// sent to the agent.
func (f *Form) Content(answers map[string][]string) (map[string]any, error) {
	content := make(map[string]any, len(answers))
	for _, id := range f.order {
		p := f.properties[id]
		values := slices.DeleteFunc(slices.Clone(answers[id]), func(value string) bool { return value == "" })
		if len(values) == 0 {
			if slices.Contains(f.required, id) {
				return nil, fmt.Errorf("%q is required", p.label(id))
			}
			continue
		}
		value, err := p.value(values)
		if err != nil {
			return nil, fmt.Errorf("%q: %w", p.label(id), err)
		}
		content[id] = value
	}
	return content, nil
}

func (p property) label(id string) string {
	if p.Title != "" {
		return p.Title
	}
	return id
}

func (p property) value(values []string) (any, error) {
	options := p.options()
	if p.Type == "array" {
		for _, value := range values {
			if !hasOption(options, value) {
				return nil, fmt.Errorf("%q is not one of the choices", value)
			}
		}
		if p.MinItems != nil && len(values) < *p.MinItems {
			return nil, fmt.Errorf("choose at least %d", *p.MinItems)
		}
		if p.MaxItems != nil && len(values) > *p.MaxItems {
			return nil, fmt.Errorf("choose at most %d", *p.MaxItems)
		}
		return values, nil
	}
	if len(values) != 1 {
		return nil, fmt.Errorf("takes a single answer")
	}
	value := values[0]
	switch p.Type {
	case "string":
		if len(options) > 0 && !hasOption(options, value) {
			return nil, fmt.Errorf("%q is not one of the choices", value)
		}
		length := len([]rune(value))
		if p.MinLength != nil && length < *p.MinLength {
			return nil, fmt.Errorf("must be at least %d characters", *p.MinLength)
		}
		if p.MaxLength != nil && length > *p.MaxLength {
			return nil, fmt.Errorf("must be at most %d characters", *p.MaxLength)
		}
		return value, nil
	case "boolean":
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return nil, fmt.Errorf("must be yes or no")
		}
		return parsed, nil
	case "number", "integer":
		number, err := strconv.ParseFloat(value, 64)
		if err != nil {
			return nil, fmt.Errorf("must be a number")
		}
		if p.Minimum != nil && number < *p.Minimum {
			return nil, fmt.Errorf("must be at least %v", *p.Minimum)
		}
		if p.Maximum != nil && number > *p.Maximum {
			return nil, fmt.Errorf("must be at most %v", *p.Maximum)
		}
		if p.Type == "integer" {
			integer, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("must be a whole number")
			}
			return integer, nil
		}
		return number, nil
	default:
		return nil, fmt.Errorf("unsupported type %q", p.Type)
	}
}

func hasOption(options []provider.QuestionOption, value string) bool {
	return slices.ContainsFunc(options, func(option provider.QuestionOption) bool { return option.Value == value })
}
