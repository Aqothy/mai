package codexapp

import "encoding/json"

// These DTOs model only the stable fields consumed by the adapter; unknown
// fields are ignored, and appItem keeps its raw JSON for the generic fallback.

type initializeParams struct {
	ClientInfo   appClientInfo         `json:"clientInfo"`
	Capabilities appClientCapabilities `json:"capabilities,omitempty"`
}

type appClientInfo struct {
	Name    string `json:"name"`
	Title   string `json:"title,omitempty"`
	Version string `json:"version"`
}

type appClientCapabilities struct {
	ExperimentalAPI    bool `json:"experimentalApi"`
	RequestAttestation bool `json:"requestAttestation"`
}

type threadStartResponse struct {
	Thread          appThread `json:"thread"`
	Model           string    `json:"model,omitempty"`
	ServiceTier     string    `json:"serviceTier,omitempty"`
	Cwd             string    `json:"cwd,omitempty"`
	ReasoningEffort string    `json:"reasoningEffort,omitempty"`
}

type threadListResponse struct {
	Data       []appThread `json:"data"`
	NextCursor *string     `json:"nextCursor"`
}

type appThread struct {
	ID        string    `json:"id"`
	Preview   string    `json:"preview,omitempty"`
	CreatedAt float64   `json:"createdAt,omitempty"`
	UpdatedAt float64   `json:"updatedAt,omitempty"`
	Cwd       string    `json:"cwd,omitempty"`
	Name      *string   `json:"name,omitempty"`
	Turns     []appTurn `json:"turns"`
}

type appTurn struct {
	ID          string        `json:"id"`
	Items       []appItem     `json:"items"`
	Status      string        `json:"status,omitempty"`
	Error       *appTurnError `json:"error,omitempty"`
	StartedAt   *float64      `json:"startedAt,omitempty"`
	CompletedAt *float64      `json:"completedAt,omitempty"`
}

type appTurnError struct {
	Message           string  `json:"message,omitempty"`
	AdditionalDetails *string `json:"additionalDetails,omitempty"`
}

// appUserInput is the stable v2 UserInput union represented as a tolerant flat
// struct. TextElements deliberately uses the protocol's snake_case spelling.
type appUserInput struct {
	Type         string           `json:"type"`
	Text         string           `json:"text,omitempty"`
	TextElements []appTextElement `json:"text_elements"`
	Detail       string           `json:"detail,omitempty"`
	URL          string           `json:"url,omitempty"`
	Path         string           `json:"path,omitempty"`
	Name         string           `json:"name,omitempty"`
}

func (value appUserInput) MarshalJSON() ([]byte, error) {
	switch value.Type {
	case "text":
		elements := value.TextElements
		if elements == nil {
			elements = []appTextElement{}
		}
		return json.Marshal(struct {
			Type         string           `json:"type"`
			Text         string           `json:"text"`
			TextElements []appTextElement `json:"text_elements"`
		}{Type: value.Type, Text: value.Text, TextElements: elements})
	case "image", "audio":
		return json.Marshal(struct {
			Type   string `json:"type"`
			Detail string `json:"detail,omitempty"`
			URL    string `json:"url"`
		}{Type: value.Type, Detail: value.Detail, URL: value.URL})
	case "localImage", "localAudio":
		return json.Marshal(struct {
			Type   string `json:"type"`
			Detail string `json:"detail,omitempty"`
			Path   string `json:"path"`
		}{Type: value.Type, Detail: value.Detail, Path: value.Path})
	case "skill", "mention":
		return json.Marshal(struct {
			Type string `json:"type"`
			Name string `json:"name"`
			Path string `json:"path"`
		}{Type: value.Type, Name: value.Name, Path: value.Path})
	default:
		return json.Marshal(struct {
			Type string `json:"type"`
		}{Type: value.Type})
	}
}

type appTextElement struct {
	ByteRange   appByteRange `json:"byteRange"`
	Placeholder *string      `json:"placeholder"`
}

type appByteRange struct {
	Start int `json:"start"`
	End   int `json:"end"`
}

// appItem covers the stable ThreadItem variants. The flat representation lets
// newer variants decode without failing; Type and Raw remain available for a
// generic timeline fallback.
type appItem struct {
	Type             string         `json:"type"`
	ID               string         `json:"id,omitempty"`
	ClientID         *string        `json:"clientId,omitempty"`
	Content          []appUserInput `json:"-"`
	ReasoningContent []string       `json:"-"`
	Text             string         `json:"text,omitempty"`
	Summary          []string       `json:"summary,omitempty"`

	Command          string             `json:"command,omitempty"`
	Cwd              string             `json:"cwd,omitempty"`
	Status           string             `json:"status,omitempty"`
	CommandActions   []appCommandAction `json:"commandActions,omitempty"`
	AggregatedOutput *string            `json:"aggregatedOutput,omitempty"`
	ExitCode         *int               `json:"exitCode,omitempty"`
	DurationMS       *int64             `json:"durationMs,omitempty"`

	Changes []appFileUpdateChange `json:"changes,omitempty"`

	Server       string             `json:"server,omitempty"`
	Tool         string             `json:"tool,omitempty"`
	Namespace    *string            `json:"namespace,omitempty"`
	Arguments    json.RawMessage    `json:"arguments,omitempty"`
	ReadOnlyHint *bool              `json:"readOnlyHint,omitempty"`
	Result       json.RawMessage    `json:"result,omitempty"`
	Error        *appMCPError       `json:"error,omitempty"`
	ContentItems []appOutputContent `json:"contentItems,omitempty"`
	Success      *bool              `json:"success,omitempty"`

	ReceiverThreadIDs []string `json:"receiverThreadIds,omitempty"`
	Prompt            *string  `json:"prompt,omitempty"`
	Model             *string  `json:"model,omitempty"`
	ReasoningEffort   *string  `json:"reasoningEffort,omitempty"`
	Kind              string   `json:"kind,omitempty"`
	AgentThreadID     string   `json:"agentThreadId,omitempty"`

	Query  string        `json:"query,omitempty"`
	Action *appWebAction `json:"action,omitempty"`
	Path   string        `json:"path,omitempty"`

	RevisedPrompt *string         `json:"revisedPrompt,omitempty"`
	SavedPath     *string         `json:"savedPath,omitempty"`
	Review        string          `json:"review,omitempty"`
	Raw           json.RawMessage `json:"-"`
}

func (value *appItem) UnmarshalJSON(data []byte) error {
	type plain appItem
	var wire struct {
		*plain
		Content json.RawMessage `json:"content"`
	}
	wire.plain = (*plain)(value)
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	switch value.Type {
	case "userMessage":
		if len(wire.Content) > 0 && string(wire.Content) != "null" {
			if err := json.Unmarshal(wire.Content, &value.Content); err != nil {
				return err
			}
		}
	case "reasoning":
		if len(wire.Content) > 0 && string(wire.Content) != "null" {
			if err := json.Unmarshal(wire.Content, &value.ReasoningContent); err != nil {
				return err
			}
		}
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appCommandAction struct {
	Type    string  `json:"type,omitempty"`
	Command string  `json:"command,omitempty"`
	Name    string  `json:"name,omitempty"`
	Path    *string `json:"path,omitempty"`
	Query   *string `json:"query,omitempty"`
}

type appFileUpdateChange struct {
	Path string             `json:"path"`
	Kind appPatchChangeKind `json:"kind"`
	Diff string             `json:"diff,omitempty"`
}

type appPatchChangeKind struct {
	Type     string  `json:"type,omitempty"`
	MovePath *string `json:"move_path,omitempty"`
}

type appMCPResult struct {
	Content           []json.RawMessage `json:"content,omitempty"`
	StructuredContent json.RawMessage   `json:"structuredContent,omitempty"`
	Meta              json.RawMessage   `json:"_meta,omitempty"`
}

type appMCPError struct {
	Message string `json:"message,omitempty"`
}

type appOutputContent struct {
	Type     string `json:"type,omitempty"`
	Text     string `json:"text,omitempty"`
	ImageURL string `json:"imageUrl,omitempty"`
	AudioURL string `json:"audioUrl,omitempty"`
}

type appWebAction struct {
	Type    string   `json:"type,omitempty"`
	Query   *string  `json:"query,omitempty"`
	Queries []string `json:"queries,omitempty"`
	URL     *string  `json:"url,omitempty"`
	Pattern *string  `json:"pattern,omitempty"`
}

type modelListResponse struct {
	Data       []appModel `json:"data"`
	NextCursor *string    `json:"nextCursor"`
}

type appModel struct {
	ID                        string                     `json:"id,omitempty"`
	Model                     string                     `json:"model,omitempty"`
	DisplayName               string                     `json:"displayName,omitempty"`
	Description               string                     `json:"description,omitempty"`
	Hidden                    bool                       `json:"hidden,omitempty"`
	SupportedReasoningEfforts []appReasoningEffortOption `json:"supportedReasoningEfforts,omitempty"`
	DefaultReasoningEffort    string                     `json:"defaultReasoningEffort,omitempty"`
	ServiceTiers              []appModelServiceTier      `json:"serviceTiers,omitempty"`
	DefaultServiceTier        string                     `json:"defaultServiceTier,omitempty"`
	IsDefault                 bool                       `json:"isDefault,omitempty"`
}

type appModelServiceTier struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
}

type appReasoningEffortOption struct {
	ReasoningEffort string `json:"reasoningEffort"`
	Description     string `json:"description,omitempty"`
}

type skillsListResponse struct {
	Data []appSkillsListEntry `json:"data"`
}

type appSkillsListEntry struct {
	Skills []appSkill `json:"skills,omitempty"`
}

type appSkill struct {
	Name             string             `json:"name"`
	Description      string             `json:"description,omitempty"`
	ShortDescription string             `json:"shortDescription,omitempty"`
	Interface        *appSkillInterface `json:"interface,omitempty"`
	Path             string             `json:"path,omitempty"`
	Scope            string             `json:"scope,omitempty"`
	Enabled          bool               `json:"enabled"`
}

type appSkillInterface struct {
	DisplayName      string `json:"displayName,omitempty"`
	ShortDescription string `json:"shortDescription,omitempty"`
}

type appPlanStep struct {
	Step   string `json:"step"`
	Status string `json:"status"`
}

func cloneRawJSON(data []byte) json.RawMessage {
	return append(json.RawMessage(nil), data...)
}
