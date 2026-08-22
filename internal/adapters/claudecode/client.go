package claudecode

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
)

const maxMessageBytes = 64 << 20

// streamClient speaks newline-delimited stream-json over one CLI process's
// stdin/stdout, including the bidirectional control protocol. It carries no
// provider-contract knowledge; the adapter owns all event mapping.
type streamClient struct {
	writeMu sync.Mutex
	stdin   io.Writer

	mu       sync.Mutex
	pending  map[string]chan controlResponse
	closed   bool
	closeErr error

	nextID atomic.Uint64

	// onMessage receives every non-control stdout line in read order on the
	// single reader goroutine. onControlRequest receives CLI-initiated control
	// requests (can_use_tool, hook_callback, ...); onControlCancel receives
	// control_cancel_request for requests the CLI no longer needs answered.
	onMessage        func(sdkMessage)
	onControlRequest func(requestID string, request controlRequestBody, raw json.RawMessage)
	onControlCancel  func(requestID string)

	done chan struct{}
}

func newStreamClient(stdout io.Reader, stdin io.Writer) *streamClient {
	client := &streamClient{
		stdin:   stdin,
		pending: make(map[string]chan controlResponse),
		done:    make(chan struct{}),
	}
	go client.run(stdout)
	return client
}

func (c *streamClient) run(stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 1<<20), maxMessageBytes)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var message sdkMessage
		if err := json.Unmarshal(line, &message); err != nil {
			continue
		}
		message.Raw = append(json.RawMessage(nil), line...)
		switch message.Type {
		case "control_response":
			var response controlResponse
			if len(message.Response) > 0 && json.Unmarshal(message.Response, &response) == nil {
				c.mu.Lock()
				waiter := c.pending[response.RequestID]
				delete(c.pending, response.RequestID)
				c.mu.Unlock()
				if waiter != nil {
					waiter <- response
				}
			}
		case "control_request":
			var request controlRequestBody
			if len(message.Request) > 0 && json.Unmarshal(message.Request, &request) == nil {
				if c.onControlRequest != nil {
					c.onControlRequest(message.RequestID, request, message.Request)
				}
			}
		case "control_cancel_request":
			if c.onControlCancel != nil {
				c.onControlCancel(message.RequestID)
			}
		default:
			if c.onMessage != nil {
				c.onMessage(message)
			}
		}
	}
	c.fail(firstError(scanner.Err(), io.EOF))
}

// send writes one JSON line to the CLI's stdin.
func (c *streamClient) send(value any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.closed {
		err := c.closeErr
		c.mu.Unlock()
		return fmt.Errorf("Claude Code process is closed: %w", err)
	}
	c.mu.Unlock()
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if _, err := c.stdin.Write(append(encoded, '\n')); err != nil {
		return err
	}
	return nil
}

// control issues a host→CLI control request and waits for its response.
func (c *streamClient) control(ctx context.Context, request map[string]any, result any) error {
	requestID := fmt.Sprintf("maid-%d", c.nextID.Add(1))
	waiter := make(chan controlResponse, 1)
	c.mu.Lock()
	if c.closed {
		err := c.closeErr
		c.mu.Unlock()
		return fmt.Errorf("Claude Code process is closed: %w", err)
	}
	c.pending[requestID] = waiter
	c.mu.Unlock()
	err := c.send(map[string]any{
		"type":       "control_request",
		"request_id": requestID,
		"request":    request,
	})
	if err != nil {
		c.mu.Lock()
		delete(c.pending, requestID)
		c.mu.Unlock()
		return err
	}
	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, requestID)
		c.mu.Unlock()
		return ctx.Err()
	case response := <-waiter:
		if response.Subtype == "error" {
			return fmt.Errorf("Claude Code control request %q failed: %s", requestID, trimmedOrDefault(response.Error, "unknown error"))
		}
		if result != nil && len(response.Response) > 0 {
			return json.Unmarshal(response.Response, result)
		}
		return nil
	case <-c.done:
		c.mu.Lock()
		err := c.closeErr
		c.mu.Unlock()
		return fmt.Errorf("Claude Code process exited: %w", err)
	}
}

// respondControl answers a CLI-initiated control request.
func (c *streamClient) respondControl(requestID string, payload any) error {
	return c.send(map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "success",
			"request_id": requestID,
			"response":   payload,
		},
	})
}

func (c *streamClient) respondControlError(requestID, message string) error {
	return c.send(map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "error",
			"request_id": requestID,
			"error":      message,
		},
	})
}

// fail unblocks every pending control call and rejects future sends.
func (c *streamClient) fail(err error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.closeErr = err
	pending := c.pending
	c.pending = make(map[string]chan controlResponse)
	c.mu.Unlock()
	for id, waiter := range pending {
		waiter <- controlResponse{Subtype: "error", RequestID: id, Error: err.Error()}
	}
	close(c.done)
}

func firstError(err error, fallback error) error {
	if err != nil {
		return err
	}
	return fallback
}
