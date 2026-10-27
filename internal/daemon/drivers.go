package daemon

import (
	"github.com/Aqothy/maiD/internal/adapters/acp"
	"github.com/Aqothy/maiD/internal/adapters/claudecode"
	"github.com/Aqothy/maiD/internal/adapters/codexapp"
	"github.com/Aqothy/maiD/internal/provider"
)

// drivers are the provider kinds the daemon runs; a new provider is a case
// here.
var drivers = map[provider.DriverKind]provider.Driver{
	acp.DriverKind:        acp.Driver,
	claudecode.DriverKind: claudecode.Driver,
	codexapp.DriverKind:   codexapp.Driver,
}
