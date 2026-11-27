package orchestration

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"time"
)

// Project is a folder the user added to work in. The daemon works only in
// workspaces a project allows (allowsRoot).
type Project struct {
	// Path is canonical (canonicalDirectory).
	Path    string    `json:"path"`
	AddedAt time.Time `json:"addedAt"`
}

// ProjectList is every project, newest first. Subscribers get the whole list
// on subscribing and after every change.
type ProjectList struct {
	Projects []Project `json:"projects"`
}

// canonicalDirectory validates path as an existing absolute directory and
// returns it with symlinks resolved, so every alias of a folder is one
// project, one workspace and one search index.
func canonicalDirectory(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", refused(CodeInvalid, "folder %q must be an absolute path", path)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", refused(CodeInvalid, "folder %q is not usable: %v", path, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", refused(CodeInvalid, "folder %q is not usable: %v", path, err)
	}
	if !info.IsDir() {
		return "", refused(CodeInvalid, "folder %q is not a directory", path)
	}
	return resolved, nil
}

// AddProject adds a folder as a project. Adding one twice keeps the first.
func (e *Engine) AddProject(ctx context.Context, path string) (Project, error) {
	canonical, err := canonicalDirectory(path)
	if err != nil {
		return Project{}, err
	}
	return call(ctx, e, func(s *step) (Project, error) {
		return e.addProject(s, canonical), nil
	})
}

// RemoveProject removes a project by its listed path; its chats stay.
// Removing a path that is no project does nothing.
func (e *Engine) RemoveProject(ctx context.Context, path string) error {
	_, err := call(ctx, e, func(s *step) (struct{}, error) {
		if _, ok := e.projects[path]; ok {
			delete(e.projects, path)
			s.tx.removedProjects = append(s.tx.removedProjects, path)
			e.publishProjects(s)
		}
		return struct{}{}, nil
	})
	return err
}

// WorkspaceRoot returns path's canonical form when the daemon may work
// there (allowsRoot), and refuses it otherwise. A chat's own cwd is already
// one.
func (e *Engine) WorkspaceRoot(ctx context.Context, path string) (string, error) {
	canonical, err := canonicalDirectory(path)
	if err != nil {
		return "", err
	}
	return call(ctx, e, func(s *step) (string, error) {
		if !e.allowsRoot(canonical) {
			return "", notInProject(canonical)
		}
		return canonical, nil
	})
}

// Projects subscribes to the project list and returns it.
func (sub *Subscription) Projects(ctx context.Context) (ProjectList, error) {
	e := sub.e
	return call(ctx, e, func(s *step) (ProjectList, error) {
		subscriber := e.subscribers[sub.id]
		if subscriber == nil {
			return ProjectList{}, errClosed
		}
		subscriber.projects = true
		return e.projectList(), nil
	})
}

func (e *Engine) addProject(s *step, canonical string) Project {
	if added, ok := e.projects[canonical]; ok {
		return Project{Path: canonical, AddedAt: added}
	}
	project := Project{Path: canonical, AddedAt: s.now}
	e.projects[canonical] = project.AddedAt
	s.tx.addedProjects = append(s.tx.addedProjects, project)
	e.publishProjects(s)
	return project
}

// allowsRoot is the rule for where the daemon works: in a project or a
// folder inside one, or where a chat already works. canonical is a
// canonicalDirectory result.
func (e *Engine) allowsRoot(canonical string) bool {
	for project := range e.projects {
		if rel, err := filepath.Rel(project, canonical); err == nil && filepath.IsLocal(rel) {
			return true
		}
	}
	for _, thread := range e.threads {
		if thread.Workspace.Cwd == canonical {
			return true
		}
	}
	return false
}

func notInProject(canonical string) error {
	return refused(CodeInvalid, "%s isn't in a project; add it as a project to work in it", canonical)
}

func (e *Engine) projectList() ProjectList {
	projects := make([]Project, 0, len(e.projects))
	for path, added := range e.projects {
		projects = append(projects, Project{Path: path, AddedAt: added})
	}
	slices.SortFunc(projects, func(a, b Project) int { return b.AddedAt.Compare(a.AddedAt) })
	return ProjectList{Projects: projects}
}

// publishProjects sends the whole list to its subscribers once the step
// committed.
func (e *Engine) publishProjects(s *step) {
	s.after(func() {
		list := e.projectList()
		for _, subscriber := range e.subscribers {
			if subscriber.projects {
				subscriber.sink.ProjectList(list)
			}
		}
	})
}
