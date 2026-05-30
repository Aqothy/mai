package protocol

const ProtocolVersion = 1

type ClientCapabilities struct {
	FS       FileSystemCapabilities `json:"fs"`
	Terminal bool                   `json:"terminal"`
}

type FileSystemCapabilities struct {
	ReadTextFile  bool `json:"readTextFile"`
	WriteTextFile bool `json:"writeTextFile"`
}

type Implementation struct {
	Name    string `json:"name"`
	Title   string `json:"title,omitempty"`
	Version string `json:"version,omitempty"`
}

type InitializeRequest struct {
	ProtocolVersion    int                `json:"protocolVersion"`
	ClientCapabilities ClientCapabilities `json:"clientCapabilities"`
	ClientInfo         *Implementation    `json:"clientInfo,omitempty"`
}

type InitializeResponse struct {
	ProtocolVersion   int             `json:"protocolVersion"`
	AgentCapabilities map[string]any  `json:"agentCapabilities,omitempty"`
	AgentInfo         *Implementation `json:"agentInfo,omitempty"`
	AuthMethods       []any           `json:"authMethods"`
	Meta              map[string]any  `json:"_meta,omitempty"`
}
