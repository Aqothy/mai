package orchestration

import (
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
)

// A thread's provider selection is two orthogonal values with ONE
// representation each: Thread.ProviderInstanceID is WHO runs the thread (the
// identity used for routing, on the wire and in commands/events), and
// Thread.ModelSelection is WHAT it runs (model + options; it never repeats
// the instance id). Switching instances drops the old instance's
// model/options and invalidates the session; changing model/options replaces
// the selection wholesale.

// providerSelectionChange is the validated, RESOLVED form of a client-supplied
// provider/model patch: the complete post-application aggregate (instance +
// full model selection), recorded on the event payload. Emitting the whole
// aggregate is what lets clients and the projection apply selection events by
// replacement — a provider-only switch carries the new instance with NO
// modelSelection, so replacing clears the old instance's model instead of a
// patch rule silently keeping it.
type providerSelectionChange struct {
	ProviderInstanceID provider.InstanceID
	ModelSelection     *provider.ModelSelection
	ClearsSession      bool

	specified bool
}

func resolveProviderSelectionChange(thread Thread, providerInstanceID provider.InstanceID, selection *provider.ModelSelection) providerSelectionChange {
	change := providerSelectionChange{specified: providerInstanceID != "" || selection != nil}
	if !change.specified {
		return change
	}
	instance := thread.ProviderInstanceID
	if providerInstanceID != "" {
		instance = providerInstanceID
	}
	change.ProviderInstanceID = instance
	switch {
	case selection != nil:
		change.ModelSelection = cloneModelSelection(selection)
	case instance != thread.ProviderInstanceID:
		change.ModelSelection = nil // switching instances drops the old instance's model choice
	default:
		change.ModelSelection = cloneModelSelection(thread.ModelSelection)
	}
	change.ClearsSession = sessionBindingStaleFor(instance, thread.Session)
	return change
}

// changes reports whether applying the resolved aggregate would alter the
// thread's selection (a same-value patch is a no-op and never rejected).
func (change providerSelectionChange) changes(thread Thread) bool {
	return change.ProviderInstanceID != thread.ProviderInstanceID || !selectionEqual(change.ModelSelection, thread.ModelSelection)
}

func (change providerSelectionChange) validateMetaUpdate(thread Thread) error {
	turnID := activeTurnID(thread)
	if turnID == "" || !change.specified || !change.changes(thread) {
		return nil
	}
	return fmt.Errorf("cannot change provider/model selection while turn %q is active", turnID)
}

func (change providerSelectionChange) validateSteering(thread Thread) error {
	if !change.specified {
		return nil
	}
	turnID := activeTurnID(thread)
	if change.ProviderInstanceID != "" && change.ProviderInstanceID != thread.ProviderInstanceID {
		return fmt.Errorf("cannot change provider instance while turn %q is active", turnID)
	}
	if change.ModelSelection == nil {
		return nil
	}
	currentModel, currentOptions := "", ""
	if thread.ModelSelection != nil {
		currentModel, currentOptions = thread.ModelSelection.Model, string(thread.ModelSelection.Options)
	}
	if change.ModelSelection.Model != "" && change.ModelSelection.Model != currentModel {
		return fmt.Errorf("cannot change model while turn %q is active", turnID)
	}
	if len(change.ModelSelection.Options) != 0 && string(change.ModelSelection.Options) != currentOptions {
		return fmt.Errorf("cannot change model options while turn %q is active", turnID)
	}
	return nil
}

func selectionEqual(a, b *provider.ModelSelection) bool {
	if a == nil {
		a = &provider.ModelSelection{}
	}
	if b == nil {
		b = &provider.ModelSelection{}
	}
	return a.Model == b.Model && string(a.Options) == string(b.Options)
}

// applyThreadProviderSelectionPatch applies a selection EVENT. The payload
// carries the complete resolved aggregate (resolveProviderSelectionChange),
// so it is applied by REPLACEMENT — clients mirror the same rule (CLIENT_API
// §7): a present providerInstanceId replaces both the identity and the model
// selection (an absent modelSelection means "none" — a provider-only switch
// cleared the old instance's model); a payload with only modelSelection (a
// draft thread with no instance, or a config-derived model update) replaces
// just the model choice.
func applyThreadProviderSelectionPatch(thread *Thread, providerInstanceID provider.InstanceID, selection *provider.ModelSelection, sessionCleared bool) {
	if thread == nil {
		return
	}
	if providerInstanceID != "" {
		thread.ProviderInstanceID = providerInstanceID
		thread.ModelSelection = cloneModelSelection(selection)
	} else if selection != nil {
		thread.ModelSelection = cloneModelSelection(selection)
	}
	selectionSpecified := providerInstanceID != "" || selection != nil
	if sessionCleared || (selectionSpecified && sessionBindingStaleFor(thread.ProviderInstanceID, thread.Session)) {
		thread.Session = nil
	}
}

func sessionBindingStaleFor(desiredInstanceID provider.InstanceID, session *SessionBinding) bool {
	return session != nil && desiredInstanceID != "" && session.ProviderInstanceID != "" && session.ProviderInstanceID != desiredInstanceID
}

// modelSelectionFromConfigOptions derives the thread's model choice from a
// provider config-options update (a model-category option reporting its
// current value). Identity is untouched — the thread's provider instance is
// already bound.
func modelSelectionFromConfigOptions(thread Thread, options []provider.ConfigOption) *provider.ModelSelection {
	for _, option := range options {
		model, ok := option.CurrentValue.(string)
		if option.Category != provider.ConfigOptionCategoryModel || !ok || model == "" {
			continue
		}
		selection := cloneModelSelection(thread.ModelSelection)
		if selection == nil {
			selection = &provider.ModelSelection{}
		}
		selection.Model = model
		return selection
	}
	return nil
}
