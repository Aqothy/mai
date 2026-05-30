package client

import (
	"errors"
	"io"
	"sync"
)

type processStdio struct {
	r    io.ReadCloser
	w    io.WriteCloser
	once sync.Once
	err  error
}

func (s *processStdio) Read(p []byte) (int, error)  { return s.r.Read(p) }
func (s *processStdio) Write(p []byte) (int, error) { return s.w.Write(p) }
func (s *processStdio) Close() error {
	s.once.Do(func() {
		s.err = errors.Join(s.w.Close(), s.r.Close())
	})
	return s.err
}
