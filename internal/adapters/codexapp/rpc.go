package codexapp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
)

const maxMessageBytes = 64 << 20

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *rpcError) Error() string {
	if e == nil {
		return "<nil>"
	}
	return fmt.Sprintf("codex app-server error %d: %s", e.Code, e.Message)
}

type rpcResponse struct {
	result json.RawMessage
	err    error
}

// rpcClient implements app-server's JSONL transport. The protocol resembles
// JSON-RPC but deliberately omits the jsonrpc member.
type rpcClient struct {
	input  io.Reader
	output io.Writer

	nextID   atomic.Uint64
	writeMu  sync.Mutex
	mu       sync.Mutex
	pending  map[string]chan rpcResponse
	closed   bool
	closeErr error

	onNotification func(string, json.RawMessage)
	onRequest      func(json.RawMessage, string, json.RawMessage)
	closeOnce      sync.Once
}

func newRPCClient(input io.Reader, output io.Writer) *rpcClient {
	return &rpcClient{
		input: input, output: output,
		pending: make(map[string]chan rpcResponse),
	}
}

func (c *rpcClient) run() {
	scanner := bufio.NewScanner(c.input)
	scanner.Buffer(make([]byte, 64*1024), maxMessageBytes)
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		if len(line) == 0 {
			continue
		}
		var envelope struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
			Error  *rpcError       `json:"error"`
		}
		if err := json.Unmarshal(line, &envelope); err != nil {
			c.fail(fmt.Errorf("decode Codex app-server message: %w", err))
			return
		}
		if envelope.Method != "" {
			if len(envelope.ID) > 0 && string(envelope.ID) != "null" {
				if c.onRequest != nil {
					c.onRequest(append(json.RawMessage(nil), envelope.ID...), envelope.Method, envelope.Params)
				} else {
					_ = c.respondError(envelope.ID, -32601, "method not found")
				}
			} else if c.onNotification != nil {
				c.onNotification(envelope.Method, envelope.Params)
			}
			continue
		}
		if len(envelope.ID) == 0 {
			continue
		}
		key := string(envelope.ID)
		c.mu.Lock()
		response := c.pending[key]
		delete(c.pending, key)
		c.mu.Unlock()
		if response == nil {
			continue
		}
		if envelope.Error != nil {
			response <- rpcResponse{err: envelope.Error}
		} else {
			response <- rpcResponse{result: append(json.RawMessage(nil), envelope.Result...)}
		}
	}
	err := scanner.Err()
	if err == nil {
		err = io.EOF
	}
	c.fail(err)
}

func (c *rpcClient) call(ctx context.Context, method string, params any, result any) error {
	id := c.nextID.Add(1)
	idRaw := json.RawMessage(fmt.Sprintf("%d", id))
	key := string(idRaw)
	response := make(chan rpcResponse, 1)
	c.mu.Lock()
	if c.closed {
		err := c.closeErr
		c.mu.Unlock()
		if err == nil {
			err = io.ErrClosedPipe
		}
		return err
	}
	c.pending[key] = response
	c.mu.Unlock()
	if err := c.write(struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params any             `json:"params,omitempty"`
	}{ID: idRaw, Method: method, Params: params}); err != nil {
		c.mu.Lock()
		delete(c.pending, key)
		c.mu.Unlock()
		return err
	}
	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, key)
		c.mu.Unlock()
		return ctx.Err()
	case reply := <-response:
		if reply.err != nil {
			return reply.err
		}
		if result == nil || len(reply.result) == 0 || string(reply.result) == "null" {
			return nil
		}
		if err := json.Unmarshal(reply.result, result); err != nil {
			return fmt.Errorf("decode %s response: %w", method, err)
		}
		return nil
	}
}

func (c *rpcClient) notify(method string, params any) error {
	return c.write(struct {
		Method string `json:"method"`
		Params any    `json:"params,omitempty"`
	}{Method: method, Params: params})
}

func (c *rpcClient) respond(id json.RawMessage, result any) error {
	return c.write(struct {
		ID     json.RawMessage `json:"id"`
		Result any             `json:"result"`
	}{ID: id, Result: result})
}

func (c *rpcClient) respondError(id json.RawMessage, code int, message string) error {
	return c.write(struct {
		ID    json.RawMessage `json:"id"`
		Error *rpcError       `json:"error"`
	}{ID: id, Error: &rpcError{Code: code, Message: message}})
}

func (c *rpcClient) write(value any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.mu.Lock()
	closed := c.closed
	closeErr := c.closeErr
	c.mu.Unlock()
	if closed {
		if closeErr != nil {
			return closeErr
		}
		return io.ErrClosedPipe
	}
	_, err = c.output.Write(encoded)
	return err
}

func (c *rpcClient) fail(err error) {
	if err == nil {
		err = io.ErrClosedPipe
	}
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		c.closeErr = err
		pending := c.pending
		c.pending = make(map[string]chan rpcResponse)
		c.mu.Unlock()
		for _, response := range pending {
			response <- rpcResponse{err: err}
		}
	})
}

func isRPCMethodNotFound(err error) bool {
	var rpcErr *rpcError
	return errors.As(err, &rpcErr) && rpcErr.Code == -32601
}
