package codexapp

import "encoding/json"

// These DTOs intentionally model only the stable fields consumed by the
// adapter. Unknown fields are retained on the main catalog/history values so
// an app-server upgrade does not make otherwise usable responses undecodable.

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

type initializeResponse struct {
	UserAgent string          `json:"userAgent,omitempty"`
	Raw       json.RawMessage `json:"-"`
}

func (value *initializeResponse) UnmarshalJSON(data []byte) error {
	type plain initializeResponse
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type threadStartResponse struct {
	Thread          appThread       `json:"thread"`
	Model           string          `json:"model,omitempty"`
	ModelProvider   string          `json:"modelProvider,omitempty"`
	ServiceTier     string          `json:"serviceTier,omitempty"`
	Cwd             string          `json:"cwd,omitempty"`
	ReasoningEffort string          `json:"reasoningEffort,omitempty"`
	Raw             json.RawMessage `json:"-"`
}

func (value *threadStartResponse) UnmarshalJSON(data []byte) error {
	type plain threadStartResponse
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type threadListResponse struct {
	Data            []appThread     `json:"data"`
	NextCursor      *string         `json:"nextCursor"`
	BackwardsCursor *string         `json:"backwardsCursor"`
	Raw             json.RawMessage `json:"-"`
}

func (value *threadListResponse) UnmarshalJSON(data []byte) error {
	type plain threadListResponse
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appThread struct {
	ID             string          `json:"id"`
	SessionID      string          `json:"sessionId,omitempty"`
	ForkedFromID   *string         `json:"forkedFromId,omitempty"`
	ParentThreadID *string         `json:"parentThreadId,omitempty"`
	Preview        string          `json:"preview,omitempty"`
	Ephemeral      bool            `json:"ephemeral,omitempty"`
	ModelProvider  string          `json:"modelProvider,omitempty"`
	CreatedAt      float64         `json:"createdAt,omitempty"`
	UpdatedAt      float64         `json:"updatedAt,omitempty"`
	RecencyAt      *float64        `json:"recencyAt,omitempty"`
	Status         appThreadStatus `json:"status,omitempty"`
	Path           *string         `json:"path,omitempty"`
	Cwd            string          `json:"cwd,omitempty"`
	CLIVersion     string          `json:"cliVersion,omitempty"`
	Source         json.RawMessage `json:"source,omitempty"`
	Name           *string         `json:"name,omitempty"`
	Turns          []appTurn       `json:"turns"`
	Raw            json.RawMessage `json:"-"`
}

func (value *appThread) UnmarshalJSON(data []byte) error {
	type plain appThread
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appThreadStatus struct {
	Type        string          `json:"type,omitempty"`
	ActiveFlags []string        `json:"activeFlags,omitempty"`
	Raw         json.RawMessage `json:"-"`
}

func (value *appThreadStatus) UnmarshalJSON(data []byte) error {
	type plain appThreadStatus
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appTurn struct {
	ID          string          `json:"id"`
	Items       []appItem       `json:"items"`
	ItemsView   json.RawMessage `json:"itemsView,omitempty"`
	Status      string          `json:"status,omitempty"`
	Error       *appTurnError   `json:"error,omitempty"`
	StartedAt   *float64        `json:"startedAt,omitempty"`
	CompletedAt *float64        `json:"completedAt,omitempty"`
	DurationMS  *int64          `json:"durationMs,omitempty"`
	Raw         json.RawMessage `json:"-"`
}

func (value *appTurn) UnmarshalJSON(data []byte) error {
	type plain appTurn
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appTurnError struct {
	Message           string          `json:"message,omitempty"`
	AdditionalDetails *string         `json:"additionalDetails,omitempty"`
	CodexErrorInfo    json.RawMessage `json:"codexErrorInfo,omitempty"`
}

type turnInterruptParams struct {
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId"`
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
	Raw          json.RawMessage  `json:"-"`
}

func (value *appUserInput) UnmarshalJSON(data []byte) error {
	type plain appUserInput
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
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
		if len(value.Raw) > 0 {
			return cloneRawJSON(value.Raw), nil
		}
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
	Type             string            `json:"type"`
	ID               string            `json:"id,omitempty"`
	ClientID         *string           `json:"clientId,omitempty"`
	Content          []appUserInput    `json:"-"`
	ReasoningContent []string          `json:"-"`
	Text             string            `json:"text,omitempty"`
	Phase            *string           `json:"phase,omitempty"`
	Summary          []string          `json:"summary,omitempty"`
	Fragments        []json.RawMessage `json:"fragments,omitempty"`

	PluginID         *string            `json:"pluginId,omitempty"`
	ScriptPath       *string            `json:"scriptPath,omitempty"`
	Command          string             `json:"command,omitempty"`
	Cwd              string             `json:"cwd,omitempty"`
	ProcessID        *string            `json:"processId,omitempty"`
	Source           string             `json:"source,omitempty"`
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
	AppContext   *appMCPAppContext  `json:"appContext,omitempty"`
	ReadOnlyHint *bool              `json:"readOnlyHint,omitempty"`
	Result       json.RawMessage    `json:"result,omitempty"`
	Error        *appMCPError       `json:"error,omitempty"`
	ContentItems []appOutputContent `json:"contentItems,omitempty"`
	Success      *bool              `json:"success,omitempty"`

	SenderThreadID    string                    `json:"senderThreadId,omitempty"`
	ReceiverThreadIDs []string                  `json:"receiverThreadIds,omitempty"`
	Prompt            *string                   `json:"prompt,omitempty"`
	Model             *string                   `json:"model,omitempty"`
	ReasoningEffort   *string                   `json:"reasoningEffort,omitempty"`
	AgentsStates      map[string]appCollabState `json:"agentsStates,omitempty"`
	Kind              string                    `json:"kind,omitempty"`
	AgentThreadID     string                    `json:"agentThreadId,omitempty"`
	AgentPath         string                    `json:"agentPath,omitempty"`

	Query   string            `json:"query,omitempty"`
	Action  *appWebAction     `json:"action,omitempty"`
	Results []json.RawMessage `json:"results,omitempty"`
	Path    string            `json:"path,omitempty"`

	RevisedPrompt         *string         `json:"revisedPrompt,omitempty"`
	TransparentBackground *bool           `json:"transparentBackground,omitempty"`
	SavedPath             *string         `json:"savedPath,omitempty"`
	Review                string          `json:"review,omitempty"`
	Raw                   json.RawMessage `json:"-"`
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

type appMCPAppContext struct {
	ConnectorID string  `json:"connectorId,omitempty"`
	LinkID      *string `json:"linkId,omitempty"`
	ResourceURI *string `json:"resourceUri,omitempty"`
	AppName     *string `json:"appName,omitempty"`
	ActionName  *string `json:"actionName,omitempty"`
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
	Type     string          `json:"type,omitempty"`
	Text     string          `json:"text,omitempty"`
	ImageURL string          `json:"imageUrl,omitempty"`
	AudioURL string          `json:"audioUrl,omitempty"`
	Raw      json.RawMessage `json:"-"`
}

func (value *appOutputContent) UnmarshalJSON(data []byte) error {
	type plain appOutputContent
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appCollabState struct {
	Status  string  `json:"status,omitempty"`
	Message *string `json:"message,omitempty"`
}

type appWebAction struct {
	Type    string   `json:"type,omitempty"`
	Query   *string  `json:"query,omitempty"`
	Queries []string `json:"queries,omitempty"`
	URL     *string  `json:"url,omitempty"`
	Pattern *string  `json:"pattern,omitempty"`
}

type modelListResponse struct {
	Data       []appModel      `json:"data"`
	NextCursor *string         `json:"nextCursor"`
	Raw        json.RawMessage `json:"-"`
}

func (value *modelListResponse) UnmarshalJSON(data []byte) error {
	type plain modelListResponse
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
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
	InputModalities           []string                   `json:"inputModalities,omitempty"`
	IsDefault                 bool                       `json:"isDefault,omitempty"`
	Raw                       json.RawMessage            `json:"-"`
}

type appModelServiceTier struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
}

func (value *appModel) UnmarshalJSON(data []byte) error {
	type plain appModel
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appReasoningEffortOption struct {
	ReasoningEffort string `json:"reasoningEffort"`
	Description     string `json:"description,omitempty"`
}

type skillsListParams struct {
	Cwds        []string `json:"cwds,omitempty"`
	ForceReload bool     `json:"forceReload,omitempty"`
}

type skillsListResponse struct {
	Data []appSkillsListEntry `json:"data"`
	Raw  json.RawMessage      `json:"-"`
}

func (value *skillsListResponse) UnmarshalJSON(data []byte) error {
	type plain skillsListResponse
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appSkillsListEntry struct {
	Cwd    string          `json:"cwd,omitempty"`
	Skills []appSkill      `json:"skills,omitempty"`
	Errors []appSkillError `json:"errors,omitempty"`
	Raw    json.RawMessage `json:"-"`
}

func (value *appSkillsListEntry) UnmarshalJSON(data []byte) error {
	type plain appSkillsListEntry
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appSkill struct {
	Name             string             `json:"name"`
	Description      string             `json:"description,omitempty"`
	ShortDescription string             `json:"shortDescription,omitempty"`
	Interface        *appSkillInterface `json:"interface,omitempty"`
	Path             string             `json:"path,omitempty"`
	Scope            string             `json:"scope,omitempty"`
	Enabled          bool               `json:"enabled"`
	Raw              json.RawMessage    `json:"-"`
}

func (value *appSkill) UnmarshalJSON(data []byte) error {
	type plain appSkill
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appSkillInterface struct {
	DisplayName      string `json:"displayName,omitempty"`
	ShortDescription string `json:"shortDescription,omitempty"`
	DefaultPrompt    string `json:"defaultPrompt,omitempty"`
}

type appSkillError struct {
	Path    string          `json:"path,omitempty"`
	Message string          `json:"message,omitempty"`
	Raw     json.RawMessage `json:"-"`
}

func (value *appSkillError) UnmarshalJSON(data []byte) error {
	type plain appSkillError
	if err := json.Unmarshal(data, (*plain)(value)); err != nil {
		return err
	}
	value.Raw = cloneRawJSON(data)
	return nil
}

type appPlanStep struct {
	Step   string `json:"step"`
	Status string `json:"status"`
}

func cloneRawJSON(data []byte) json.RawMessage {
	return append(json.RawMessage(nil), data...)
}
