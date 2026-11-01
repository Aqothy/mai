package orchestration

import (
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// subagentSeen records a provider's own subagent as a child thread, the
// first time it is named, live or in replay. Its ID derives from its parent
// and its session, so seeing it twice upserts the same thread. It lives in
// its parent's session: maiD never opens or releases it.
func (e *Engine) subagentSeen(s *step, thread *threadState, participant *participantState, seen provider.SubagentSeen) {
	if seen.Session == "" {
		return
	}
	parentThread, parentParticipant := thread, participant
	if seen.Parent != "" && seen.Parent != participant.Session {
		// A subagent's own subagent: its parent is the subagent whose
		// session started it.
		if id, ok := e.bySession[sessionKey{participant.Instance, seen.Parent}]; ok {
			parentParticipant = e.participants[id]
			parentThread = e.threads[parentParticipant.Thread]
		}
	}
	id := ThreadID(derivedID(string(parentThread.ID), seen.Session))
	if existing := e.threads[id]; existing != nil {
		if existing.Origin.AcceptsInput != seen.AcceptsInput {
			existing.Origin.AcceptsInput = seen.AcceptsInput
			s.putThread(existing)
		}
		return
	}
	if _, taken := e.bySession[sessionKey{participant.Instance, seen.Session}]; taken {
		return
	}
	title := strings.TrimSpace(seen.Name)
	if title == "" {
		title = "Subagent"
	}
	child := &threadState{
		Thread: Thread{
			ID: id, Title: title, Workspace: parentThread.Workspace, CreatedAt: s.now, UpdatedAt: s.now,
			Origin: Origin{Kind: OriginNative, Parent: parentThread.ID, By: parentParticipant.ID, At: seen.Item, AcceptsInput: seen.AcceptsInput},
		},
		requests: make(map[string]*pendingRequest),
	}
	e.threads[id] = child
	parentThread.children = append(parentThread.children, id)
	s.putThread(child)
	s.touch(parentThread.ID)
	agent := e.newParticipant(s, child, NewParticipant{Instance: participant.Instance, Session: seen.Session})
	child.Address = agent.ID
	agent.live = participant.live
	if seen.Model != "" {
		agent.Settings = []provider.ConfigOptionSelection{{OptionID: "model", Value: seen.Model, Category: provider.ConfigOptionCategoryModel}}
		s.putParticipant(agent)
	}
}
