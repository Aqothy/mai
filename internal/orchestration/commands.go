package orchestration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Command is a change to the ledger, from a device, an agent (through maiD's
// MCP server) or the daemon, authorized by its actor. The engine's own
// transitions (starting a turn, sending a steer, settling) run only from
// reactors and provider events.
type Command struct {
	// Key makes the command idempotent: the same actor's command with the same
	// key returns the first one's result.
	Key   string
	Actor Actor
	Body  CommandBody
}

// CommandBody is exactly one of the command types below.
type CommandBody interface{ commandBody() }

// NewParticipant is an agent to add to a thread: an instance with settings,
// and an existing native session to import.
type NewParticipant struct {
	Instance provider.InstanceID              `json:"instance"`
	Settings []provider.ConfigOptionSelection `json:"settings,omitempty"`
	Session  string                           `json:"session,omitempty"`
}

// CreateThread is a new chat, or one imported from a native session.
type CreateThread struct {
	Title       string             `json:"title,omitempty"`
	Workspace   provider.Workspace `json:"workspace"`
	Participant NewParticipant     `json:"participant"`
	Prompt      *MessageBody       `json:"prompt,omitempty"`
}

type UpdateThread struct {
	Thread ThreadID    `json:"thread"`
	Title  *string     `json:"title,omitempty"`
	Policy *TreePolicy `json:"policy,omitempty"`
	// Read marks it read now, on every device, or, false, unread.
	Read *bool `json:"read,omitempty"`
}

// DeleteThread deletes a thread with its tree descendants. Native sessions
// stay with their providers (provider.Delete removes one).
type DeleteThread struct {
	Thread ThreadID `json:"thread"`
}

// ForkThread starts a new chat from a thread's conversation through a turn,
// in its own agents or, with Agent, another.
// ForkThread continues a thread through a turn in a new one, with its first
// message: a fork exists once something was said in it.
type ForkThread struct {
	Thread  ThreadID        `json:"thread"`
	Through TurnID          `json:"through,omitempty"`
	Agent   *NewParticipant `json:"agent,omitempty"`
	Prompt  MessageBody     `json:"prompt"`
}

// Spawn starts a child thread on a brief: an agent's spawn tool, or a
// person's "Hand this to …".
type Spawn struct {
	Parent ThreadID       `json:"parent"`
	Brief  string         `json:"brief"`
	Agent  NewParticipant `json:"agent"`
	// Access narrows the child's access; nil keeps the spawner's.
	Access *provider.AccessLevel `json:"access,omitempty"`
	// Context is the conversation the child starts from; nil gives it the
	// brief alone.
	Context      *ForkPoint      `json:"context,omitempty"`
	ResultSchema json.RawMessage `json:"resultSchema,omitempty"`
	Wake         WakeMode        `json:"wake,omitempty"`
	Title        string          `json:"title,omitempty"`
}

type AddParticipant struct {
	Thread ThreadID `json:"thread"`
	NewParticipant
}

// UpdateParticipant sets one of a participant's config options.
type UpdateParticipant struct {
	Participant ParticipantID                  `json:"participant"`
	Setting     provider.ConfigOptionSelection `json:"setting"`
}

// Deliver queues an input for a thread's participant: To, or the thread's
// address.
type Deliver struct {
	Thread ThreadID      `json:"thread"`
	To     ParticipantID `json:"to,omitempty"`
	Body   MessageBody   `json:"body"`
	Mode   DeliveryMode  `json:"mode,omitempty"`
	// WantsReply: an agent's message whose answer comes back to it.
	WantsReply bool `json:"wantsReply,omitempty"`
}

type CancelDelivery struct {
	Delivery DeliveryID `json:"delivery"`
}

// MoveDelivery moves a queued delivery before another; an empty Before moves
// it last.
type MoveDelivery struct {
	Delivery DeliveryID `json:"delivery"`
	Before   DeliveryID `json:"before,omitempty"`
}

// SteerDelivery sends a queued delivery into the running turn.
type SteerDelivery struct {
	Delivery DeliveryID `json:"delivery"`
}

// RetryDelivery sends again a delivery that didn't reach its agent.
type RetryDelivery struct {
	Delivery DeliveryID `json:"delivery"`
}

// Interrupt stops a thread's running turn; on a provider's own subagent it
// stops the subagent.
type Interrupt struct {
	Thread ThreadID `json:"thread"`
}

// Stop interrupts the tree under a thread and holds its queues.
type Stop struct {
	Thread ThreadID `json:"thread"`
}

// Continue releases a thread's hold, as far as the actor may.
type Continue struct {
	Thread ThreadID `json:"thread"`
}

type Respond struct {
	Thread  ThreadID            `json:"thread"`
	Request string              `json:"request"`
	Action  string              `json:"action"`
	Answers map[string][]string `json:"answers,omitempty"`
	// Why an agent answered, shown with the answer.
	Why string `json:"why,omitempty"`
}

// StopItem stops a background task without its turn.
type StopItem struct {
	Thread ThreadID `json:"thread"`
	Item   string   `json:"item"`
}

// Report records a spawned thread's result; agents only.
type Report struct{ Result json.RawMessage }

func (CreateThread) commandBody()      {}
func (UpdateThread) commandBody()      {}
func (DeleteThread) commandBody()      {}
func (ForkThread) commandBody()        {}
func (Spawn) commandBody()             {}
func (AddParticipant) commandBody()    {}
func (UpdateParticipant) commandBody() {}
func (Deliver) commandBody()           {}
func (CancelDelivery) commandBody()    {}
func (MoveDelivery) commandBody()      {}
func (SteerDelivery) commandBody()     {}
func (RetryDelivery) commandBody()     {}
func (Interrupt) commandBody()         {}
func (Stop) commandBody()              {}
func (Continue) commandBody()          {}
func (Respond) commandBody()           {}
func (StopItem) commandBody()          {}
func (Report) commandBody()            {}

// CommandResult is what a command made.
type CommandResult struct {
	Thread      ThreadID      `json:"thread,omitempty"`
	Participant ParticipantID `json:"participant,omitempty"`
	Delivery    DeliveryID    `json:"delivery,omitempty"`
}

// CommandError is a refusal an agent can act on.
type CommandError struct {
	Code    ErrorCode
	Message string
}

func (e *CommandError) Error() string { return e.Message }

// ErrorCode says why a command was refused.
type ErrorCode string

const (
	CodeOutOfScope        ErrorCode = "out_of_scope"
	CodeCeilingExceeded   ErrorCode = "ceiling_exceeded"
	CodeDepthExceeded     ErrorCode = "depth_exceeded"
	CodeAgentUnavailable  ErrorCode = "agent_unavailable"
	CodeNotFound          ErrorCode = "not_found"
	CodeNotRunning        ErrorCode = "not_running"
	CodePermissionRequest ErrorCode = "permission_request"
	CodeInvalid           ErrorCode = "invalid"
)

func refused(code ErrorCode, format string, args ...any) error {
	return &CommandError{Code: code, Message: fmt.Sprintf(format, args...)}
}

// Do runs a command and returns once its writes committed (or, for a fork,
// once the provider made it and its writes committed).
func (e *Engine) Do(ctx context.Context, command Command) (CommandResult, error) {
	if command.Actor.Kind == "" {
		return CommandResult{}, refused(CodeInvalid, "a command needs an actor")
	}
	type pending struct {
		result CommandResult
		async  chan asyncOutcome
	}
	out, err := call(ctx, e, func(s *step) (pending, error) {
		if command.Key != "" {
			if raw, ok, err := e.db.receipt(e.ctx, command.Actor, command.Key); err != nil {
				return pending{}, err
			} else if ok {
				var result CommandResult
				_ = json.Unmarshal(raw, &result)
				return pending{result: result}, nil
			}
		}
		result, async, err := e.do(s, command)
		if err == nil && async == nil && command.Key != "" {
			raw, _ := json.Marshal(result)
			s.tx.receipts = append(s.tx.receipts, receiptRow{actor: command.Actor, key: command.Key, result: raw})
		}
		return pending{result: result, async: async}, err
	})
	if err != nil {
		return CommandResult{}, err
	}
	if out.async == nil {
		return out.result, nil
	}
	select {
	case outcome := <-out.async:
		return outcome.result, outcome.err
	case <-ctx.Done():
		return CommandResult{}, ctx.Err()
	case <-e.done:
		return CommandResult{}, errClosed
	}
}

// asyncOutcome is how a command that needs a provider first (a fork) ends.
type asyncOutcome struct {
	result CommandResult
	err    error
}

func (e *Engine) do(s *step, command Command) (CommandResult, chan asyncOutcome, error) {
	actor := command.Actor
	switch body := command.Body.(type) {
	case CreateThread:
		result, err := e.createThread(s, actor, body)
		return result, nil, err
	case UpdateThread:
		return CommandResult{Thread: body.Thread}, nil, e.updateThread(s, actor, body)
	case DeleteThread:
		return CommandResult{Thread: body.Thread}, nil, e.deleteThread(s, actor, body.Thread)
	case ForkThread:
		return e.forkThread(s, command, body)
	case Spawn:
		return e.spawn(s, command, body)
	case AddParticipant:
		result, err := e.addParticipant(s, actor, body)
		return result, nil, err
	case UpdateParticipant:
		return CommandResult{Participant: body.Participant}, nil, e.updateParticipant(s, actor, body)
	case Deliver:
		result, err := e.deliver(s, actor, body)
		return result, nil, err
	case CancelDelivery:
		return CommandResult{Delivery: body.Delivery}, nil, e.cancelDelivery(s, actor, body.Delivery)
	case MoveDelivery:
		return CommandResult{Delivery: body.Delivery}, nil, e.moveDelivery(s, actor, body)
	case SteerDelivery:
		return CommandResult{Delivery: body.Delivery}, nil, e.steerDelivery(s, actor, body.Delivery)
	case RetryDelivery:
		result, err := e.retryDelivery(s, actor, body.Delivery)
		return result, nil, err
	case Interrupt:
		return CommandResult{Thread: body.Thread}, nil, e.interruptCommand(s, actor, body.Thread)
	case Stop:
		return CommandResult{Thread: body.Thread}, nil, e.stopTree(s, actor, body.Thread)
	case Continue:
		return CommandResult{Thread: body.Thread}, nil, e.continueThread(s, actor, body.Thread)
	case Respond:
		return CommandResult{Thread: body.Thread}, nil, e.respond(s, actor, body)
	case StopItem:
		return CommandResult{Thread: body.Thread}, nil, e.stopItem(s, actor, body)
	case Report:
		return CommandResult{Thread: actor.Thread}, nil, e.report(s, actor, body)
	default:
		return CommandResult{}, nil, refused(CodeInvalid, "unknown command %T", command.Body)
	}
}

// Authorization. A device is trusted with everything; an agent acts
// on its own thread and below, within scope and ceilings.

func (e *Engine) existing(id ThreadID) (*threadState, error) {
	thread := e.threads[id]
	if thread == nil {
		return nil, refused(CodeNotFound, "thread %q not found", id)
	}
	return thread, nil
}

// controls reports whether an agent may control a thread: interrupt it, stop
// it, answer its questions. Only a thread's ancestors may.
func (e *Engine) controls(actor Actor, thread *threadState) bool {
	return actor.Kind == ActorDevice || actor.Kind == ActorAgent && e.isAncestor(actor.Thread, thread)
}

func (e *Engine) requireDevice(actor Actor, what string) error {
	if actor.Kind != ActorDevice {
		return refused(CodeOutOfScope, "only a person can %s", what)
	}
	return nil
}

func (e *Engine) createThread(s *step, actor Actor, create CreateThread) (CommandResult, error) {
	if err := e.requireDevice(actor, "create a chat"); err != nil {
		return CommandResult{}, err
	}
	workspace, err := e.resolveWorkspace(create.Workspace)
	if err != nil {
		return CommandResult{}, err
	}
	if err := e.validateParticipant(create.Participant, workspace); err != nil {
		return CommandResult{}, err
	}
	if create.Prompt != nil {
		if err := e.checkPrompt(*create.Prompt); err != nil {
			return CommandResult{}, err
		}
	}
	if create.Participant.Session != "" {
		if id, ok := e.bySession[sessionKey{create.Participant.Instance, create.Participant.Session}]; ok {
			participant := e.participants[id]
			return CommandResult{Thread: participant.Thread, Participant: id}, nil
		}
	}
	title := strings.TrimSpace(create.Title)
	if title == "" && create.Prompt != nil {
		title = provider.PromptPreviewTitle(create.Prompt.Text)
		if runes := []rune(title); len(runes) > 80 {
			title = string(runes[:80])
		}
	}
	if title == "" {
		title = "Untitled thread"
	}
	thread := e.newThread(s, title, workspace, Origin{Kind: OriginUser})
	participant := e.newParticipant(s, thread, create.Participant)
	thread.Address = participant.ID
	s.putThread(thread)
	result := CommandResult{Thread: thread.ID, Participant: participant.ID}
	if create.Prompt != nil {
		delivery, err := e.deliver(s, actor, Deliver{Thread: thread.ID, To: participant.ID, Body: *create.Prompt, Mode: ModeQueue})
		if err != nil {
			return CommandResult{}, err
		}
		result.Delivery = delivery.Delivery
	}
	return result, nil
}

func (e *Engine) newThread(s *step, title string, workspace provider.Workspace, origin Origin) *threadState {
	thread := &threadState{
		Thread:   Thread{ID: ThreadID(newID()), Title: title, Workspace: workspace, Origin: origin, CreatedAt: s.now, UpdatedAt: s.now},
		requests: make(map[string]*pendingRequest),
	}
	e.threads[thread.ID] = thread
	if parent := e.threads[origin.Parent]; parent != nil {
		parent.children = append(parent.children, thread.ID)
		s.touch(parent.ID)
	}
	s.putThread(thread)
	return thread
}

func (e *Engine) newParticipant(s *step, thread *threadState, new NewParticipant) *participantState {
	participant := &participantState{Participant: Participant{
		ID: ParticipantID(newID()), Thread: thread.ID, Instance: new.Instance, Settings: slices.Clone(new.Settings), Session: new.Session,
	}}
	e.participants[participant.ID] = participant
	thread.participants = append(thread.participants, participant.ID)
	if participant.Session != "" {
		e.bySession[sessionKey{participant.Instance, participant.Session}] = participant.ID
	}
	s.putParticipant(participant)
	return participant
}

func (e *Engine) validateParticipant(new NewParticipant, workspace provider.Workspace) error {
	info, ok := e.cfg.Providers.Info(new.Instance)
	if !ok {
		return refused(CodeAgentUnavailable, "agent %q is not configured", new.Instance)
	}
	if len(workspace.AdditionalDirectories) > 0 && info.Status != provider.InstanceStatusConfigured && !info.Capabilities.AdditionalDirectories {
		return refused(CodeInvalid, "%s doesn't support additional directories", info.Name)
	}
	if new.Session != "" && info.Status != provider.InstanceStatusConfigured && !info.Capabilities.Resume {
		return refused(CodeInvalid, "%s can't open an existing session", info.Name)
	}
	return nil
}

// resolveWorkspace applies the daemon's cwd rule once: a thread's cwd
// defaults to the daemon's working directory and must be an existing
// absolute directory, and its additional roots are deduplicated.
func (e *Engine) resolveWorkspace(workspace provider.Workspace) (provider.Workspace, error) {
	cwd, err := e.resolveDirectory(workspace.Cwd)
	if err != nil {
		return provider.Workspace{}, err
	}
	resolved := provider.Workspace{Cwd: cwd}
	seen := map[string]bool{filepath.Clean(cwd): true}
	for _, directory := range workspace.AdditionalDirectories {
		if directory == "" {
			continue
		}
		root, err := e.resolveDirectory(directory)
		if err != nil {
			return provider.Workspace{}, err
		}
		root = filepath.Clean(root)
		if !seen[root] {
			seen[root] = true
			resolved.AdditionalDirectories = append(resolved.AdditionalDirectories, root)
		}
	}
	return resolved, nil
}

func (e *Engine) resolveDirectory(directory string) (string, error) {
	if directory == "" {
		directory = e.cfg.DefaultCwd
		if directory == "" {
			return "", refused(CodeInvalid, "a chat needs a working directory")
		}
	}
	if !filepath.IsAbs(directory) {
		return "", refused(CodeInvalid, "working directory %q must be an absolute path", directory)
	}
	info, err := os.Stat(directory)
	if err != nil {
		return "", refused(CodeInvalid, "working directory %q is not usable: %v", directory, err)
	}
	if !info.IsDir() {
		return "", refused(CodeInvalid, "working directory %q is not a directory", directory)
	}
	return directory, nil
}

func (e *Engine) updateThread(s *step, actor Actor, update UpdateThread) error {
	thread, err := e.existing(update.Thread)
	if err != nil {
		return err
	}
	if err := e.requireDevice(actor, "rename a chat or change its policy"); err != nil {
		return err
	}
	// Everything is checked before anything changes: a refused update
	// changes nothing.
	title := ""
	if update.Title != nil {
		if title = strings.TrimSpace(*update.Title); title == "" {
			return refused(CodeInvalid, "a chat's title can't be empty")
		}
	}
	if update.Policy != nil {
		if thread.Origin.Parent != "" {
			return refused(CodeInvalid, "only a root chat has a policy")
		}
		if policy := *update.Policy; policy.MaxDepth < 0 || policy.MaxRunning < 1 || policy.HopLimit < 1 {
			return refused(CodeInvalid, "a policy needs a depth of at least 0, and at least one running turn and one hop")
		}
	}
	if update.Title != nil {
		thread.Title = title
		// The name the user chose names the native sessions too, so it shows
		// in the providers' own tools.
		for _, id := range thread.participants {
			participant := e.participants[id]
			if participant.Session == "" || !e.instanceInfo(participant.Instance).Capabilities.Rename || thread.Origin.Kind == OriginNative {
				continue
			}
			session := participant.Session
			s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
				if err := instance.Rename(ctx, session, title); err != nil && !errors.Is(err, provider.ErrUnsupported) {
					e.logger.Warn("rename native session", "session", session, "error", err)
				}
				return nil
			}, func(*step, error) {})
		}
	}
	if update.Policy != nil {
		policy := *update.Policy
		thread.Policy = &policy
	}
	if update.Read != nil {
		thread.SeenAt = time.Time{}
		if *update.Read {
			thread.SeenAt = s.now
		}
	}
	s.putThread(thread)
	return nil
}

func (e *Engine) deleteThread(s *step, actor Actor, id ThreadID) error {
	thread, err := e.existing(id)
	if err != nil {
		return err
	}
	if err := e.requireDevice(actor, "delete a chat"); err != nil {
		return err
	}
	if thread.Origin.Kind == OriginNative {
		// It is part of its parent's session, which would show it again.
		return refused(CodeInvalid, "a provider's own subagent is deleted with the chat that started it")
	}
	doomed := append([]*threadState{thread}, e.descendants(thread)...)
	for _, victim := range doomed {
		for _, pid := range victim.participants {
			participant := e.participants[pid]
			if participant.live != nil && victim.Origin.Kind != OriginNative {
				session := participant.Session
				s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
					_ = instance.Release(ctx, session)
					return nil
				}, func(*step, error) {})
			}
			if participant.Session != "" {
				key := sessionKey{participant.Instance, participant.Session}
				delete(e.bySession, key)
				s.tx.sessions = append(s.tx.sessions, key)
			}
			delete(e.participants, pid)
		}
		delete(e.threads, victim.ID)
		e.forgetWaits(victim.ID)
	}
	if parent := e.threads[thread.Origin.Parent]; parent != nil {
		parent.children = slices.DeleteFunc(parent.children, func(child ThreadID) bool { return child == id })
		s.touch(parent.ID)
	}
	// Forks of deleted threads keep their conversation and lose the link.
	for _, other := range e.threads {
		if from := other.Origin.ForkedFrom; from != nil && slices.ContainsFunc(doomed, func(victim *threadState) bool { return victim.ID == from.Thread }) {
			other.Origin.ForkedFrom = nil
			s.putThread(other)
		}
	}
	s.tx.deleted = append(s.tx.deleted, id)
	for _, victim := range doomed {
		e.notifyRemoved(s, victim.ID)
	}
	return nil
}

func (e *Engine) addParticipant(s *step, actor Actor, add AddParticipant) (CommandResult, error) {
	thread, err := e.existing(add.Thread)
	if err != nil {
		return CommandResult{}, err
	}
	if err := e.requireDevice(actor, "add an agent to a chat"); err != nil {
		return CommandResult{}, err
	}
	if thread.Origin.Kind == OriginNative {
		return CommandResult{}, refused(CodeInvalid, "a provider's own subagent can't take other agents")
	}
	if err := e.validateParticipant(add.NewParticipant, thread.Workspace); err != nil {
		return CommandResult{}, err
	}
	participant := e.newParticipant(s, thread, add.NewParticipant)
	thread.Address = participant.ID
	s.putThread(thread)
	e.notifyParticipant(s, thread, participant)
	return CommandResult{Thread: thread.ID, Participant: participant.ID}, nil
}

func (e *Engine) updateParticipant(s *step, actor Actor, update UpdateParticipant) error {
	participant := e.participants[update.Participant]
	if participant == nil {
		return refused(CodeNotFound, "agent %q not found", update.Participant)
	}
	if err := e.requireDevice(actor, "change an agent's settings"); err != nil {
		return err
	}
	if update.Setting.OptionID == "" {
		return refused(CodeInvalid, "a setting needs an option")
	}
	thread := e.threads[participant.Thread]
	settings := slices.DeleteFunc(slices.Clone(participant.Settings), func(setting provider.ConfigOptionSelection) bool {
		return setting.OptionID == update.Setting.OptionID
	})
	participant.Settings = append(settings, update.Setting)
	s.putParticipant(participant)
	if participant.live != nil {
		session, setting := participant.Session, update.Setting
		id := participant.ID
		s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
			err := instance.Configure(ctx, session, setting)
			if err == nil {
				return nil
			}
			return func(s *step) {
				if participant := e.participants[id]; participant != nil {
					e.warning(s, e.threads[participant.Thread], participant, provider.Warning{Message: fmt.Sprintf("Couldn't change %s: %v", setting.OptionID, err)}, s.now)
				}
			}
		}, func(*step, error) {})
	}
	e.notifyParticipant(s, thread, participant)
	return nil
}

// checkPrompt refuses a message with nothing in it or an attachment that
// isn't stored. A quote with a comment is a message on its own.
func (e *Engine) checkPrompt(body MessageBody) error {
	if strings.TrimSpace(body.Text) == "" && len(body.Attachments) == 0 && !slices.ContainsFunc(body.Annotations, func(annotation provider.PromptAnnotation) bool {
		return strings.TrimSpace(annotation.Quote) != ""
	}) {
		return refused(CodeInvalid, "a message needs text, attachments or a quote")
	}
	if err := e.attachments.check(body.Attachments); err != nil {
		return refused(CodeInvalid, "%v", err)
	}
	return nil
}

// deliver queues an input. Hops bound conversations without a person: a
// person's delivery has none, an agent's message one more than the turn
// that sent it, a spawn's brief keeps them.
func (e *Engine) deliver(s *step, actor Actor, deliver Deliver) (CommandResult, error) {
	thread, err := e.existing(deliver.Thread)
	if err != nil {
		return CommandResult{}, err
	}
	to := deliver.To
	if to == "" {
		to = thread.Address
	}
	participant := e.participants[to]
	if participant == nil || participant.Thread != thread.ID {
		return CommandResult{}, refused(CodeNotFound, "agent %q isn't in this chat", to)
	}
	if thread.Origin.Kind == OriginNative && !thread.Origin.AcceptsInput {
		return CommandResult{}, refused(CodeInvalid, "this provider's own subagent takes no messages")
	}
	if err := e.checkPrompt(deliver.Body); err != nil {
		return CommandResult{}, err
	}
	mode := deliver.Mode
	switch mode {
	case "":
		mode = ModeQueue
	case ModeQueue, ModeSteer:
	default:
		return CommandResult{}, refused(CodeInvalid, "unknown delivery mode %q", mode)
	}
	delivery := &Delivery{
		ID: DeliveryID(newID()), Thread: thread.ID, To: to, From: actor, Mode: mode, Body: deliver.Body,
		State: DeliveryQueued, CreatedAt: s.now,
	}
	switch actor.Kind {
	case ActorDevice:
		delivery.Kind = KindPrompt
		thread.Address = to
		thread.Hold = HoldNone
	case ActorAgent:
		if err := e.mayTalk(actor, thread); err != nil {
			return CommandResult{}, err
		}
		if err := e.withinCeiling(actor, participant); err != nil {
			return CommandResult{}, err
		}
		delivery.Kind = KindMessage
		// A steer joins work already under way, so it never opens a reply.
		delivery.WantsReply = deliver.WantsReply && mode != ModeSteer
		delivery.Hops = e.actorHops(actor) + 1
		if e.controls(actor, thread) && (thread.Hold == HoldStoppedAgent || thread.Hold == HoldFailed) {
			thread.Hold = HoldNone
		}
	default:
		return CommandResult{}, refused(CodeOutOfScope, "the daemon delivers only replies and notices")
	}
	delivery.Position = e.nextPosition(thread)
	thread.queue = append(thread.queue, delivery)
	if mode == ModeSteer && actor.Kind == ActorDevice {
		e.makeWay(s, thread, delivery, actor)
	}
	thread.UpdatedAt = s.now
	s.putThread(thread)
	s.putDelivery(delivery)
	e.notifyDelivery(s, thread, delivery)
	return CommandResult{Thread: thread.ID, Participant: to, Delivery: delivery.ID}, nil
}

// makeWay puts a person's steer first and, when the running turn can't take
// it (its agent can't steer, or it is another agent's turn), stops that turn
// so the steer goes next, as Zed sends over an ACP agent's turn.
func (e *Engine) makeWay(s *step, thread *threadState, delivery *Delivery, actor Actor) {
	delivery.Position = e.frontPosition(thread)
	sortQueue(thread.queue)
	running := thread.runningTurn()
	if running == nil || thread.interrupting != nil {
		return
	}
	if running.Participant == delivery.To && e.instanceInfo(e.participants[delivery.To].Instance).Capabilities.Steer {
		return
	}
	e.interruptTurn(s, thread, actor, false)
}

// actorHops is the hops of the turn an agent acts in.
func (e *Engine) actorHops(actor Actor) int {
	thread := e.threads[actor.Thread]
	if thread == nil || thread.latest == nil {
		return 0
	}
	return thread.latest.Hops
}

// mayTalk applies an agent's scope: it messages anyone in its tree.
// Interrupting is the Interrupt command, which only an agent above may use.
func (e *Engine) mayTalk(actor Actor, thread *threadState) error {
	caller := e.threads[actor.Thread]
	if caller == nil {
		return refused(CodeOutOfScope, "the calling chat no longer exists")
	}
	if e.root(thread).ID != e.root(caller).ID {
		return refused(CodeOutOfScope, "chat %q is outside your tree", thread.ID)
	}
	return nil
}

// withinCeiling: an agent can't hand work to an agent allowed to do more
// than itself.
// An unmapped access level counts as full.
func (e *Engine) withinCeiling(actor Actor, target *participantState) error {
	caller := e.participants[actor.Participant]
	if caller == nil {
		return refused(CodeOutOfScope, "the calling agent no longer exists")
	}
	if e.accessLevel(target).Ceiling().Exceeds(e.accessLevel(caller).Ceiling()) {
		return refused(CodeCeilingExceeded, "that agent may do more than you; map its access modes in its settings, or ask the user")
	}
	return nil
}

func (e *Engine) accessLevel(participant *participantState) provider.AccessLevel {
	info := e.instanceInfo(participant.Instance)
	level := info.Access.Level(participant.Settings)
	if level == provider.AccessUnknown && info.Access != nil {
		// No setting chosen: the session runs the provider's current mode.
		if current, ok := provider.CurrentConfigString(participant.options, info.Access.Option); ok {
			level = info.Access.Levels[current]
		}
	}
	return level
}

func (e *Engine) queueEntry(actor Actor, id DeliveryID) (*threadState, *Delivery, error) {
	thread, delivery := e.deliveryInQueue(id)
	if delivery == nil {
		return nil, nil, refused(CodeNotFound, "delivery %q isn't waiting", id)
	}
	if actor.Kind == ActorAgent && !e.controls(actor, thread) && delivery.From.Participant != actor.Participant {
		return nil, nil, refused(CodeOutOfScope, "only the sender or an agent above the chat can change that delivery")
	}
	return thread, delivery, nil
}

func (e *Engine) cancelDelivery(s *step, actor Actor, id DeliveryID) error {
	thread, delivery, err := e.queueEntry(actor, id)
	if err != nil {
		return err
	}
	if delivery.State == DeliverySending {
		return refused(CodeInvalid, "it is on its way to the agent")
	}
	delivery.State = DeliveryCancelled
	s.putDelivery(delivery)
	thread.dropFromQueue(id)
	e.notifyDelivery(s, thread, delivery)
	return nil
}

func (e *Engine) moveDelivery(s *step, actor Actor, move MoveDelivery) error {
	thread, delivery, err := e.queueEntry(actor, move.Delivery)
	if err != nil {
		return err
	}
	if delivery.State != DeliveryQueued {
		return refused(CodeInvalid, "only a waiting delivery moves")
	}
	if move.Before == "" {
		delivery.Position = e.nextPosition(thread)
	} else {
		before := thread.queueDelivery(move.Before)
		if before == nil {
			return refused(CodeNotFound, "delivery %q isn't waiting", move.Before)
		}
		previous := before.Position - 1
		for _, other := range thread.queue {
			if other.Position < before.Position && other.ID != delivery.ID {
				previous = max(previous, other.Position)
			}
		}
		delivery.Position = (previous + before.Position) / 2
	}
	sortQueue(thread.queue)
	s.putDelivery(delivery)
	e.notifyDelivery(s, thread, delivery)
	return nil
}

func (e *Engine) steerDelivery(s *step, actor Actor, id DeliveryID) error {
	thread, delivery, err := e.queueEntry(actor, id)
	if err != nil {
		return err
	}
	if delivery.State != DeliveryQueued {
		return refused(CodeInvalid, "only a waiting delivery can be sent now")
	}
	delivery.Mode = ModeSteer
	if actor.Kind == ActorDevice {
		thread.Hold = HoldNone
		s.putThread(thread)
		e.makeWay(s, thread, delivery, actor)
	} else {
		delivery.Position = e.frontPosition(thread)
		sortQueue(thread.queue)
	}
	s.putDelivery(delivery)
	e.notifyDelivery(s, thread, delivery)
	return nil
}

func (e *Engine) retryDelivery(s *step, actor Actor, id DeliveryID) (CommandResult, error) {
	thread, delivery := e.deliveryInQueue(id)
	if delivery == nil || delivery.State != DeliveryRefused {
		return CommandResult{}, refused(CodeInvalid, "only a message that didn't reach the agent can be retried")
	}
	if err := e.mayRelease(actor, thread); err != nil {
		return CommandResult{}, err
	}
	delivery.State, delivery.Reason = DeliveryQueued, ""
	delivery.Position = e.frontPosition(thread)
	sortQueue(thread.queue)
	thread.Hold = HoldNone
	s.putThread(thread)
	s.putDelivery(delivery)
	e.notifyDelivery(s, thread, delivery)
	return CommandResult{Thread: thread.ID, Delivery: id}, nil
}

// mayRelease applies who may release a hold: a person any; an
// ancestor agent one an agent set or a failure.
func (e *Engine) mayRelease(actor Actor, thread *threadState) error {
	switch {
	case actor.Kind == ActorDevice, thread.Hold == HoldNone:
		return nil
	case actor.Kind == ActorAgent && e.controls(actor, thread) && (thread.Hold == HoldStoppedAgent || thread.Hold == HoldFailed):
		return nil
	}
	return refused(CodeOutOfScope, "only the user can release this chat")
}

func (e *Engine) interruptCommand(s *step, actor Actor, id ThreadID) error {
	thread, err := e.existing(id)
	if err != nil {
		return err
	}
	if !e.controls(actor, thread) {
		return refused(CodeOutOfScope, "only an agent above a chat can interrupt it")
	}
	if !thread.running() {
		return refused(CodeNotRunning, "nothing is running")
	}
	e.interruptTurn(s, thread, actor, false)
	return nil
}

// interruptTurn stops what a thread runs: its running turn, or a delivery
// still on its way, which then waits again.
func (e *Engine) interruptTurn(s *step, thread *threadState, actor Actor, hold bool) {
	interrupter := actor
	if running := thread.runningTurn(); running != nil {
		thread.interrupting = &interrupter
		participant := e.participants[running.Participant]
		session, ref := running.Session, running.Ref
		s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
			if err := instance.Interrupt(ctx, session, ref); err != nil {
				return func(s *step) {
					if thread := e.threads[participant.Thread]; thread != nil {
						thread.interrupting = nil
						e.warning(s, thread, participant, provider.Warning{Turn: ref, Message: "Couldn't stop the turn: " + err.Error()}, s.now)
					}
				}
			}
			return nil
		}, func(*step, error) {})
	}
	for _, delivery := range thread.queue {
		if delivery.State == DeliverySending && !e.dispatched[delivery.ID] && delivery.Mode != ModeSteer {
			// Its session is still opening: it waits instead.
			delivery.State = DeliveryQueued
			s.putDelivery(delivery)
			e.notifyDelivery(s, thread, delivery)
		}
	}
	if hold {
		thread.Hold = HoldStoppedPerson
		if actor.Kind == ActorAgent {
			thread.Hold = HoldStoppedAgent
		}
		s.putThread(thread)
	}
}

func (e *Engine) stopTree(s *step, actor Actor, id ThreadID) error {
	thread, err := e.existing(id)
	if err != nil {
		return err
	}
	if !e.controls(actor, thread) {
		return refused(CodeOutOfScope, "only an agent above a chat can stop it")
	}
	for _, target := range append([]*threadState{thread}, e.descendants(thread)...) {
		// An agent's stop never replaces a person's.
		if actor.Kind == ActorAgent && target.Hold == HoldStoppedPerson {
			continue
		}
		e.interruptTurn(s, target, actor, true)
	}
	return nil
}

func (e *Engine) continueThread(s *step, actor Actor, id ThreadID) error {
	thread, err := e.existing(id)
	if err != nil {
		return err
	}
	if thread.Hold == HoldNone {
		return nil
	}
	if err := e.mayRelease(actor, thread); err != nil {
		return err
	}
	if thread.Hold == HoldHops {
		// Continuing sends the held delivery as the person's.
		if queued := thread.queued(); len(queued) > 0 {
			queued[0].Hops = 0
			s.putDelivery(queued[0])
		}
	}
	thread.Hold = HoldNone
	s.putThread(thread)
	return nil
}

func (e *Engine) respond(s *step, actor Actor, respond Respond) error {
	thread, err := e.existing(respond.Thread)
	if err != nil {
		return err
	}
	request := thread.requests[respond.Request]
	if request == nil {
		return refused(CodeNotFound, "request %q isn't open", respond.Request)
	}
	if actor.Kind == ActorAgent {
		if !e.controls(actor, thread) {
			return refused(CodeOutOfScope, "only an agent above a chat can answer its questions")
		}
		// A child's permissions are its access level, fixed when it was
		// spawned: only a person grants more.
		if len(request.Ask.Questions) == 0 {
			return refused(CodePermissionRequest, "only the user answers permission requests")
		}
	}
	action, ok := request.Ask.Action(respond.Action)
	if !ok {
		return refused(CodeInvalid, "action %q wasn't offered", respond.Action)
	}
	if len(respond.Answers) > 0 && !action.Submit {
		return refused(CodeInvalid, "action %q takes no answers", respond.Action)
	}
	if err := validateAnswers(request.Ask, action, respond.Answers); err != nil {
		return refused(CodeInvalid, "%v", err)
	}
	if request.answering != "" {
		return refused(CodeInvalid, "it was already answered")
	}
	request.answering = action.ID
	participant := e.participants[request.Participant]
	session, requestID := participant.Session, request.ID
	answer := provider.RequestAnswer{Action: action, Answers: respond.Answers}
	s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
		if err := instance.Respond(ctx, session, requestID, answer); err != nil {
			return func(s *step) {
				thread := e.threads[participant.Thread]
				if request := thread.requests[requestID]; request != nil {
					// The answer was refused, so the question stays answerable.
					request.answering = ""
					e.notifyRequest(s, thread, request, nil)
					e.warning(s, thread, participant, provider.Warning{Message: "The answer wasn't taken: " + err.Error()}, s.now)
				}
			}
		}
		return nil
	}, func(*step, error) {})
	e.notifyRequest(s, thread, request, nil)
	return nil
}

func validateAnswers(ask provider.Request, action provider.RequestAction, answers map[string][]string) error {
	if !action.Submit {
		return nil
	}
	for _, question := range ask.Questions {
		values := answers[question.ID]
		if question.Required && len(values) == 0 {
			return fmt.Errorf("question %q needs an answer", firstNonEmpty(question.Title, question.ID))
		}
		if question.Kind == provider.QuestionKindChoice && !question.AllowsFreeText {
			for _, value := range values {
				if !slices.ContainsFunc(question.Options, func(option provider.QuestionOption) bool { return option.Value == value }) {
					return fmt.Errorf("%q isn't an option of question %q", value, firstNonEmpty(question.Title, question.ID))
				}
			}
		}
		if !question.MultiSelect && len(values) > 1 {
			return fmt.Errorf("question %q takes one answer", firstNonEmpty(question.Title, question.ID))
		}
	}
	return nil
}

func (e *Engine) stopItem(s *step, actor Actor, stop StopItem) error {
	thread, err := e.existing(stop.Thread)
	if err != nil {
		return err
	}
	if !e.controls(actor, thread) {
		return refused(CodeOutOfScope, "only an agent above a chat can stop its tasks")
	}
	entry, turn, err := e.findEntry(thread, stop.Item)
	if err != nil {
		return err
	}
	if entry.Tool == nil || !entry.Tool.Background || entry.Status != provider.ItemStatusInProgress {
		return refused(CodeInvalid, "%q isn't a running background task", stop.Item)
	}
	participant := e.participants[turn.Participant]
	session, item := turn.Session, stop.Item
	s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
		if err := instance.StopItem(ctx, session, item); err != nil {
			return func(s *step) {
				e.warning(s, e.threads[participant.Thread], participant, provider.Warning{Message: "Couldn't stop the task: " + err.Error()}, s.now)
			}
		}
		return nil
	}, func(*step, error) {})
	return nil
}

func (e *Engine) report(s *step, actor Actor, report Report) error {
	if actor.Kind != ActorAgent {
		return refused(CodeOutOfScope, "only a spawned agent reports")
	}
	thread, err := e.existing(actor.Thread)
	if err != nil {
		return err
	}
	if thread.Origin.Contract == nil {
		return refused(CodeInvalid, "only a spawned chat reports a result")
	}
	if !json.Valid(report.Result) {
		return refused("result_invalid", "the result isn't JSON")
	}
	turn := thread.latest
	if turn == nil {
		return refused(CodeNotRunning, "the chat has no turn to report in")
	}
	turn.Report = append(json.RawMessage(nil), report.Result...)
	s.putTurn(turn)
	return nil
}

// reportSince is the thread's last report made since a message: in the turn
// it started or after.
func (e *Engine) reportSince(thread *threadState, message *Delivery) json.RawMessage {
	since, ok, err := e.db.turn(e.ctx, message.Turn)
	if err != nil || !ok {
		return nil
	}
	turns, err := e.db.queryTurns(e.ctx, `SELECT `+turnColumns+` FROM turns WHERE thread_id = ? AND (started_at, turn_id) >= (?, ?) AND report IS NOT NULL ORDER BY started_at DESC, turn_id DESC LIMIT 1`,
		string(thread.ID), encodeTime(since.StartedAt), string(since.ID))
	if err != nil || len(turns) == 0 {
		return nil
	}
	return turns[0].Report
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
