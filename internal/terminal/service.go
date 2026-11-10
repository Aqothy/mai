package terminal

import (
	"sync"
	"time"
)

// terminateGrace bounds how long a process group gets to exit after SIGHUP
// and SIGTERM before it is killed. Shells exit on SIGHUP at once; the grace
// is for a program that saves its state on hangup.
const terminateGrace = time.Second

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

// Start spawns the login shell for terminalID. A shell that ends removes its
// terminal, so an existing session is never replaced.
func (svc *Service) Start(terminalID string, spec SpawnSpec, events Events) (*Session, error) {
	svc.mu.Lock()
	defer svc.mu.Unlock()
	if svc.closed {
		return nil, ErrServiceClosed
	}
	if svc.sessions[terminalID] != nil {
		return nil, ErrAlreadyExists
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
	session.Release()
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
			s.Release()
		}(session)
	}
	wg.Wait()
}
