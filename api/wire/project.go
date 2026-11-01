package wire

import "github.com/Aqothy/maiD/internal/orchestration"

// Projects are the folders the user added; every device shows the daemon's
// one list. The daemon works only in a project, a folder inside one, or a
// folder a chat already works in: thread creation, workspace.searchFiles with
// a cwd and provider.options.get refuse any other folder with invalid params.
// Importing a native session adds its folder as a project. Terminals aren't
// restricted.
const (
	// MethodProjectAdd adds an existing absolute directory, by its canonical
	// path (symlinks resolved), and returns the project. Adding one twice
	// returns the first.
	MethodProjectAdd = "project.add"
	// MethodProjectRemove removes a project by its listed path. Its chats
	// stay; removing a path that is no project succeeds.
	MethodProjectRemove = "project.remove"
	// MethodProjectSubscribeList returns the whole list and subscribes the
	// connection to MethodProjectList, which carries the whole list again
	// after every change.
	MethodProjectSubscribeList = "project.subscribeList"
	MethodProjectList          = "project.list"
)

type (
	Project     = orchestration.Project
	ProjectList = orchestration.ProjectList
)

type ProjectParams struct {
	Path string `json:"path"`
}
