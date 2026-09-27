package providerservice

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
)

func promptInputHash(text string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(text)))
}

func (s *Service) preparePromptPresentation(instance ProviderInstance, input provider.SendTurnInput) (provider.SendTurnInput, error) {
	identity, ok := instance.(ClientMessageIdentityProvider)
	if s.promptStore == nil || input.Presentation == nil || !ok || !identity.ReplaysClientMessageIDs() {
		return input, nil
	}
	route := s.routeForThread(input.ThreadID)
	if route.InstanceID != instance.Info().InstanceID {
		return input, fmt.Errorf("thread provider changed before prompt presentation could be saved")
	}
	if route.ProviderSessionID == "" {
		return input, fmt.Errorf("cannot preserve prompt presentation without a native session identity")
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return input, err
	}
	input.ClientMessageID = "maid:" + hex.EncodeToString(nonce[:])
	if err := s.promptStore.SavePrompt(route.InstanceID, route.ProviderSessionID, store.PromptRecord{
		ClientMessageID: input.ClientMessageID,
		InputHash:       promptInputHash(input.Input),
		Presentation:    *input.Presentation,
	}); err != nil {
		return input, err
	}
	// Save before dispatch. If the process dies after accepting the request,
	// the exact client ID still recovers its metadata on restart. An unsent
	// record cannot create a phantom message because only native replay rows
	// with that ID are enriched.
	return input, nil
}

func restorePromptPresentations(events []provider.RuntimeEvent, records map[string]store.PromptRecord) {
	usedMessageIDs := make(map[string]bool)
	for index := range events {
		event := &events[index]
		if event.Payload.ItemType != provider.ItemKindUserMessage {
			continue
		}
		record, ok := records[event.Payload.ClientMessageID]
		if !ok || record.InputHash != promptInputHash(event.Payload.Detail) {
			continue
		}
		presentation := record.Presentation
		presentation.Annotations = append([]provider.PromptAnnotation(nil), presentation.Annotations...)
		if usedMessageIDs[presentation.MessageID] {
			// A provider may retain both attempts of an explicitly retried
			// prompt. Keep both native items rather than concatenate them into
			// one local message; references keep pointing to the first attempt.
			presentation.MessageID = ""
		} else {
			usedMessageIDs[presentation.MessageID] = true
		}
		event.Payload.Presentation = &presentation
	}
}
