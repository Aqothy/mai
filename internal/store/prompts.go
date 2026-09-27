package store

import (
	"encoding/json"
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
)

func (s *SQLite) SavePrompt(instanceID provider.InstanceID, sessionID string, record PromptRecord) error {
	if instanceID == "" || sessionID == "" || record.ClientMessageID == "" || record.InputHash == "" || record.Presentation.MessageID == "" {
		return fmt.Errorf("store: prompt presentation requires complete session/message identity")
	}
	data, err := json.Marshal(record.Presentation)
	if err != nil {
		return fmt.Errorf("store: encode prompt presentation: %w", err)
	}
	// Random dispatch IDs are immutable. An accidental collision must fail the
	// send rather than replace a different message's annotation provenance.
	_, err = s.db.Exec(`INSERT INTO prompt_presentations
		(instance_id, provider_session_id, client_message_id, input_hash, presentation)
		VALUES (?, ?, ?, ?, ?)`, instanceID, sessionID, record.ClientMessageID, record.InputHash, string(data))
	if err != nil {
		return fmt.Errorf("store: save prompt presentation: %w", err)
	}
	return nil
}

func (s *SQLite) LoadPrompts(instanceID provider.InstanceID, sessionID string) (map[string]PromptRecord, error) {
	rows, err := s.db.Query(`SELECT client_message_id, input_hash, presentation FROM prompt_presentations
		WHERE instance_id = ? AND provider_session_id = ?`, instanceID, sessionID)
	if err != nil {
		return nil, fmt.Errorf("store: load prompt presentations: %w", err)
	}
	defer rows.Close()
	result := make(map[string]PromptRecord)
	for rows.Next() {
		var record PromptRecord
		var data string
		if err := rows.Scan(&record.ClientMessageID, &record.InputHash, &data); err != nil {
			return nil, fmt.Errorf("store: scan prompt presentation: %w", err)
		}
		if err := json.Unmarshal([]byte(data), &record.Presentation); err != nil {
			return nil, fmt.Errorf("store: decode prompt presentation: %w", err)
		}
		result[record.ClientMessageID] = record
	}
	return result, rows.Err()
}

func (s *SQLite) ForkPrompts(instanceID provider.InstanceID, sourceSessionID, destinationSessionID string) error {
	if instanceID == "" || sourceSessionID == "" || destinationSessionID == "" || sourceSessionID == destinationSessionID {
		return fmt.Errorf("store: fork prompt presentations requires distinct sessions")
	}
	// A single statement copies an immutable snapshot, or rolls it all back on
	// a collision. No source records or unrelated destination rows are changed.
	_, err := s.db.Exec(`INSERT INTO prompt_presentations
		(instance_id, provider_session_id, client_message_id, input_hash, presentation)
		SELECT instance_id, ?, client_message_id, input_hash, presentation FROM prompt_presentations
		WHERE instance_id = ? AND provider_session_id = ?`, destinationSessionID, instanceID, sourceSessionID)
	if err != nil {
		return fmt.Errorf("store: fork prompt presentations: %w", err)
	}
	return nil
}

func (s *SQLite) DeletePrompts(instanceID provider.InstanceID, sessionID string) error {
	_, err := s.db.Exec(`DELETE FROM prompt_presentations WHERE instance_id = ? AND provider_session_id = ?`, instanceID, sessionID)
	return err
}
