package orchestration

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Aqothy/maiD/internal/provider"
)

// attachmentStore keeps attachment data as files named by their content, so
// the same image is stored once however many messages carry it. Entries and
// deliveries name attachments by ID; snapshots never carry their data.
type attachmentStore struct {
	dir string
}

func openAttachmentStore(dataDir string) (*attachmentStore, error) {
	if dataDir == "" {
		return nil, errors.New("orchestration needs a data directory for attachments")
	}
	dir := filepath.Join(dataDir, "attachments")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create attachment store: %w", err)
	}
	return &attachmentStore{dir: dir}, nil
}

func attachmentID(data string) string {
	sum := sha256.Sum256([]byte(data))
	return hex.EncodeToString(sum[:])
}

func (a *attachmentStore) path(id string) (string, error) {
	if len(id) != sha256.Size*2 {
		return "", fmt.Errorf("attachment %q not found", id)
	}
	if _, err := hex.DecodeString(id); err != nil {
		return "", fmt.Errorf("attachment %q not found", id)
	}
	return filepath.Join(a.dir, id), nil
}

// write stores data and returns its ID.
func (a *attachmentStore) write(data string) (string, error) {
	id := attachmentID(data)
	path, _ := a.path(id)
	if _, err := os.Stat(path); err == nil {
		return id, nil
	}
	temporary, err := os.CreateTemp(a.dir, ".upload-*")
	if err != nil {
		return "", fmt.Errorf("store attachment: %w", err)
	}
	if _, err := temporary.WriteString(data); err != nil {
		temporary.Close()
		os.Remove(temporary.Name())
		return "", fmt.Errorf("store attachment: %w", err)
	}
	if err := temporary.Close(); err != nil {
		os.Remove(temporary.Name())
		return "", fmt.Errorf("store attachment: %w", err)
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		os.Remove(temporary.Name())
		return "", fmt.Errorf("store attachment: %w", err)
	}
	return id, nil
}

func (a *attachmentStore) read(id string) (string, error) {
	path, err := a.path(id)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("attachment %q not found", id)
	}
	if err != nil {
		return "", fmt.Errorf("read attachment: %w", err)
	}
	return string(data), nil
}

// strip moves an entry's attachment data into the store, leaving IDs. A
// failed write keeps the data inline: the entry still shows it.
func (a *attachmentStore) strip(entry *provider.Entry) {
	stripAll := func(attachments []provider.Attachment) []provider.Attachment {
		if len(attachments) == 0 {
			return attachments
		}
		stripped := make([]provider.Attachment, len(attachments))
		for index, attachment := range attachments {
			if attachment.Data != "" {
				if id, err := a.write(attachment.Data); err == nil {
					attachment.ID, attachment.Data = id, ""
				}
			}
			stripped[index] = attachment
		}
		return stripped
	}
	entry.Attachments = stripAll(entry.Attachments)
	if entry.Tool != nil && len(entry.Tool.Attachments) > 0 {
		tool := *entry.Tool
		tool.Attachments = stripAll(tool.Attachments)
		entry.Tool = &tool
	}
}

// stripTurns strips the entries of history turns.
func (a *attachmentStore) stripTurns(turns []provider.HistoryTurn) {
	for turn := range turns {
		for entry := range turns[turn].Entries {
			a.strip(&turns[turn].Entries[entry])
		}
	}
}

// check makes a delivery's attachments refer to stored data, storing what
// arrived inline.
func (a *attachmentStore) check(attachments []provider.Attachment) error {
	for index := range attachments {
		attachment := &attachments[index]
		if attachment.Data != "" {
			id, err := a.write(attachment.Data)
			if err != nil {
				return err
			}
			attachment.ID, attachment.Data = id, ""
			continue
		}
		if attachment.Kind == provider.AttachmentResourceLink {
			continue
		}
		path, err := a.path(attachment.ID)
		if err != nil {
			return err
		}
		if _, err := os.Stat(path); err != nil {
			return fmt.Errorf("attachment %q was not uploaded", attachment.ID)
		}
	}
	return nil
}

// load is attachments with their data, for a provider.
func (a *attachmentStore) load(attachments []provider.Attachment) ([]provider.Attachment, error) {
	loaded := make([]provider.Attachment, len(attachments))
	for index, attachment := range attachments {
		if attachment.Data == "" && attachment.ID != "" && attachment.Kind != provider.AttachmentResourceLink {
			data, err := a.read(attachment.ID)
			if err != nil {
				return nil, err
			}
			attachment.Data = data
		}
		loaded[index] = attachment
	}
	return loaded, nil
}
