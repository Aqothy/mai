package providerservice

import (
	"context"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

// A registry update changes the next launch, not the process owning live
// sessions. The ordinary start and lazy recovery paths must agree on that.
func TestManifestUpdatePreservesRunningProcessAndAppliesOnNextLaunch(t *testing.T) {
	for _, startAgain := range []bool{false, true} {
		name := "lazy session recovery"
		if startAgain {
			name = "ordinary registry start"
		}
		t.Run(name, func(t *testing.T) {
			adapter := &fakeAdapter{}
			service := newFakeService(t, adapter)
			old := provider.InstanceSpec{InstanceID: "registry-agent", Name: "Agent", Driver: "fake", Config: fakeInstanceConfig([]string{"agent@1"})}
			updated := old
			updated.Config = fakeInstanceConfig([]string{"agent@2"})
			first, err := service.StartManifestInstance(context.Background(), old, false)
			if err != nil {
				t.Fatal(err)
			}
			mustStartSession(t, service, "thread", provider.StartSessionInput{ProviderInstanceID: old.InstanceID})
			if err := service.RegisterManifestInstance(updated); err != nil {
				t.Fatal(err)
			}
			if startAgain {
				current, err := service.StartManifestInstance(context.Background(), updated, false)
				if err != nil {
					t.Fatalf("start with pending update: %v", err)
				}
				if current.PID != first.PID {
					t.Fatal("ordinary start replaced the running process")
				}
			}
			if err := service.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread", Input: "continue"}); err != nil {
				t.Fatal(err)
			}
			original := adapter.instance(0)
			count := len(adapter.launchConfigs())
			original.mu.Lock()
			closed := original.closed
			sends := len(original.sendTurns)
			original.mu.Unlock()
			if count != 1 || closed || sends != 1 {
				t.Fatalf("update disrupted process: count=%d closed=%t sends=%d", count, closed, sends)
			}
			original.mu.Lock()
			original.info.Status = provider.InstanceStatusExited
			original.mu.Unlock()
			mustStartSession(t, service, "thread", provider.StartSessionInput{ProviderInstanceID: old.InstanceID})
			if configs := adapter.launchConfigs(); len(configs) != 2 || configs[1] != string(updated.Config) {
				t.Fatalf("launch configs = %v, want old then updated", configs)
			}
		})
	}
}

func TestManifestDefaultDoesNotOverrideCustomLaunchOnRecovery(t *testing.T) {
	adapter := &fakeAdapter{}
	service := newFakeService(t, adapter)
	configured := provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake"}
	if err := service.RegisterManifestInstance(configured); err != nil {
		t.Fatal(err)
	}
	pinned := configured
	pinned.Config = fakeInstanceConfig([]string{"/custom/pinned-codex"})
	mustStartInstance(t, service, pinned, false)
	current := adapter.instance(0)
	current.mu.Lock()
	current.info.Status = provider.InstanceStatusExited
	current.mu.Unlock()
	mustStartSession(t, service, "thread", provider.StartSessionInput{ProviderInstanceID: pinned.InstanceID})
	if configs := adapter.launchConfigs(); len(configs) != 2 || configs[1] != string(pinned.Config) {
		t.Fatalf("configs=%v, want explicit custom launch preserved", configs)
	}
}

func TestManifestUpdateDuringLaunchIsNotOverwritten(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	adapter := &fakeAdapter{beforeLaunch: func(_ context.Context, n int) error {
		if n == 1 {
			close(entered)
			<-release
		}
		return nil
	}}
	service := newFakeService(t, adapter)
	old := provider.InstanceSpec{InstanceID: "registry-agent", Name: "Agent", Driver: "fake", Config: fakeInstanceConfig([]string{"agent@1"})}
	updated := old
	updated.Config = fakeInstanceConfig([]string{"agent@2"})
	started := make(chan error, 1)
	go func() { _, err := service.StartManifestInstance(context.Background(), old, false); started <- err }()
	<-entered
	registered := make(chan error, 1)
	go func() { registered <- service.RegisterManifestInstance(updated) }()
	close(release)
	if err := <-started; err != nil {
		t.Fatal(err)
	}
	if err := <-registered; err != nil {
		t.Fatal(err)
	}
	first := adapter.instance(0)
	first.mu.Lock()
	first.info.Status = provider.InstanceStatusExited
	first.mu.Unlock()
	mustStartSession(t, service, "thread", provider.StartSessionInput{ProviderInstanceID: old.InstanceID})
	if configs := adapter.launchConfigs(); len(configs) != 2 || configs[1] != string(updated.Config) {
		t.Fatalf("configs=%v, want in-flight update preserved", configs)
	}
}
