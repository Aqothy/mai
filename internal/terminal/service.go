package terminal

import (
	"sync"
	"time"
)

// terminateGrace bounds how long a process group gets to exit after SIGTERM
// before it is killed.
const terminateGrace = 3 * time.Second

// Service owns every live terminal session for one daemon run. It knows
// nothing about RPC clients, rendering, or persistence.
type Service struct {
	mu       sync.Mutex
	sessions map[string]*Session
	closed   bool
}

// NewService creates an empty terminal service.
func NewService() *Service {
	return &Service{sessions: make(map[string]*Session)}
}

// Start spawns the login shell for terminalID. A terminal has at most one
// live run; starting over an ended run replaces it, starting over a live run
// fails with ErrAlreadyRunning.
func (svc *Service) Start(terminalID string, spec SpawnSpec, events Events) (*Session, error) {
	svc.mu.Lock()
	defer svc.mu.Unlock()
	if svc.closed {
		return nil, ErrServiceClosed
	}
	if existing, ok := svc.sessions[terminalID]; ok {
		if status := existing.Status(); status == StatusStarting || status == StatusRunning {
			return nil, ErrAlreadyRunning
		}
	}
	session, err := startSession(terminalID, spec, events)
	if err != nil {
		return nil, err
	}
	svc.sessions[terminalID] = session
	return session, nil
}

// Get returns the live session for terminalID.
func (svc *Service) Get(terminalID string) (*Session, error) {
	svc.mu.Lock()
	defer svc.mu.Unlock()
	session, ok := svc.sessions[terminalID]
	if !ok {
		return nil, ErrNotFound
	}
	return session, nil
}

// Terminate kills the live run and keeps the session's final state available.
func (svc *Service) Terminate(terminalID string) error {
	session, err := svc.Get(terminalID)
	if err != nil {
		return err
	}
	session.Terminate(terminateGrace)
	return nil
}

// Remove terminates the run if necessary and forgets the session.
func (svc *Service) Remove(terminalID string) error {
	svc.mu.Lock()
	session, ok := svc.sessions[terminalID]
	delete(svc.sessions, terminalID)
	svc.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	session.Terminate(terminateGrace)
	return nil
}

// Close terminates every live session and waits for their process groups to
// be cleaned up. The service accepts no new sessions afterward.
func (svc *Service) Close() {
	svc.mu.Lock()
	if svc.closed {
		sessions := svc.sessions
		svc.mu.Unlock()
		for _, session := range sessions {
			<-session.Done()
		}
		return
	}
	svc.closed = true
	sessions := make([]*Session, 0, len(svc.sessions))
	for _, session := range svc.sessions {
		sessions = append(sessions, session)
	}
	svc.mu.Unlock()

	var wg sync.WaitGroup
	for _, session := range sessions {
		wg.Add(1)
		go func(s *Session) {
			defer wg.Done()
			s.Terminate(terminateGrace)
		}(session)
	}
	wg.Wait()
}
