package providerservice

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// fakeDriver opens fakeInstances, each a process of its own.
type fakeDriver struct {
	mu     sync.Mutex
	opened []*fakeInstance
	// gate, while set, holds Open until closed.
	gate chan struct{}
	// fail fails the next Open.
	fail error
}

type fakeInstance struct {
	provider.Unsupported
	spec provider.InstanceSpec
	host provider.Host
	mu   sync.Mutex
	shut bool
}

func (f *fakeInstance) Info() provider.InstanceInfo {
	f.mu.Lock()
	defer f.mu.Unlock()
	status := provider.InstanceStatusInitialized
	if f.shut {
		status = provider.InstanceStatusExited
	}
	return provider.InstanceInfo{InstanceID: f.spec.InstanceID, Name: f.spec.Name, Driver: f.spec.Driver, Status: status}
}

func (f *fakeInstance) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shut = true
	return nil
}

func (f *fakeInstance) closed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.shut
}

func (d *fakeDriver) driver() provider.Driver {
	return provider.Driver{Open: func(ctx context.Context, spec provider.InstanceSpec, host provider.Host) (provider.Instance, error) {
		d.mu.Lock()
		gate, fail := d.gate, d.fail
		d.fail = nil
		d.mu.Unlock()
		if gate != nil {
			select {
			case <-gate:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		if fail != nil {
			return nil, fail
		}
		instance := &fakeInstance{spec: spec, host: host}
		d.mu.Lock()
		d.opened = append(d.opened, instance)
		d.mu.Unlock()
		return instance, nil
	}}
}

func (d *fakeDriver) instances() []*fakeInstance {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]*fakeInstance(nil), d.opened...)
}

type sinkRecord struct {
	mu     sync.Mutex
	events []uint64 // generations
	gone   []uint64
}

func newService(t *testing.T, driver *fakeDriver) (*Service, *sinkRecord) {
	t.Helper()
	record := &sinkRecord{}
	service := New(map[provider.DriverKind]provider.Driver{"fake": driver.driver()}, nil, Sink{
		Event: func(_ provider.InstanceID, generation uint64, _ provider.Event) {
			record.mu.Lock()
			record.events = append(record.events, generation)
			record.mu.Unlock()
		},
		Gone: func(_ provider.InstanceID, generation uint64) {
			record.mu.Lock()
			record.gone = append(record.gone, generation)
			record.mu.Unlock()
		},
	}, nil)
	t.Cleanup(service.Close)
	return service, record
}

func spec(config string) provider.InstanceSpec {
	return provider.InstanceSpec{InstanceID: "agent", Name: "Agent", Driver: "fake", Config: json.RawMessage(config)}
}

// startRegistered registers a definition and starts its process.
func startRegistered(t *testing.T, service *Service, definition provider.InstanceSpec) {
	t.Helper()
	if err := service.RegisterInstance(definition); err != nil {
		t.Fatal(err)
	}
	if _, err := service.StartConfiguredInstance(context.Background(), definition.InstanceID, ""); err != nil {
		t.Fatal(err)
	}
}

// Concurrent starts of one instance launch one process.
func TestConcurrentStartsLaunchOneProcess(t *testing.T) {
	driver := &fakeDriver{gate: make(chan struct{})}
	service, _ := newService(t, driver)
	if err := service.RegisterInstance(spec(`{"a":1}`)); err != nil {
		t.Fatal(err)
	}
	var started sync.WaitGroup
	errs := make(chan error, 4)
	for range 4 {
		started.Go(func() {
			_, err := service.StartConfiguredInstance(context.Background(), "agent", "")
			errs <- err
		})
	}
	close(driver.gate)
	started.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if opened := len(driver.instances()); opened != 1 {
		t.Fatalf("opened %d processes, want 1", opened)
	}
}

// A running instance is on a definition however its JSON is written, and
// moves only onto another one.
func TestARunningInstanceMovesOnlyOntoAnotherDefinition(t *testing.T) {
	driver := &fakeDriver{}
	service, _ := newService(t, driver)
	startRegistered(t, service, spec(`{"a":1,"b":[1,2]}`))
	for _, step := range []struct {
		definition string
		opened     int
	}{
		{`{ "b": [1, 2], "a": 1 }`, 1},
		{`{"a":2}`, 2},
	} {
		if err := service.RegisterInstance(spec(step.definition)); err != nil {
			t.Fatal(err)
		}
		if err := service.ApplyPending(context.Background(), "agent"); err != nil {
			t.Fatal(err)
		}
		if opened := len(driver.instances()); opened != step.opened {
			t.Fatalf("after registering %s: opened %d processes, want %d", step.definition, opened, step.opened)
		}
	}
	if running := driver.instances()[1]; string(running.spec.Config) != `{"a":2}` || !driver.instances()[0].closed() {
		t.Fatalf("running on %s, old process closed %v; want the new definition and the old process closed", running.spec.Config, driver.instances()[0].closed())
	}
}

// A restart stamps the new process's events with a new generation and says
// the old one is gone; the old process's late events keep their own.
func TestRestartStampsGenerationsAndEndsTheOldProcess(t *testing.T) {
	driver := &fakeDriver{}
	service, record := newService(t, driver)
	startRegistered(t, service, spec(`{}`))
	if _, err := service.RestartInstance(context.Background(), "agent"); err != nil {
		t.Fatal(err)
	}
	old, current := driver.instances()[0], driver.instances()[1]
	if !old.closed() || current.closed() {
		t.Fatalf("closed old %v, new %v; want the old one closed", old.closed(), current.closed())
	}
	old.host.Emit(provider.Event{Session: "s", Body: provider.TitleChanged{Title: "late"}})
	current.host.Emit(provider.Event{Session: "s", Body: provider.TitleChanged{Title: "new"}})
	record.mu.Lock()
	defer record.mu.Unlock()
	if len(record.events) != 2 || record.events[0] == record.events[1] || len(record.gone) != 1 || record.gone[0] != record.events[0] {
		t.Fatalf("events of generations %v, gone %v; want the old generation's event stamped as such and it gone", record.events, record.gone)
	}
}

// A restart that can't start a new process leaves the old one running.
func TestFailedRestartKeepsTheRunningProcess(t *testing.T) {
	driver := &fakeDriver{}
	service, record := newService(t, driver)
	startRegistered(t, service, spec(`{}`))
	driver.mu.Lock()
	driver.fail = errors.New("no binary")
	driver.mu.Unlock()
	if _, err := service.RestartInstance(context.Background(), "agent"); err == nil {
		t.Fatal("restart succeeded")
	}
	instance, _, err := service.Instance(context.Background(), "agent", "")
	if err != nil || instance != driver.instances()[0] || driver.instances()[0].closed() {
		t.Fatalf("instance = %v, %v; want the first process still running", instance, err)
	}
	record.mu.Lock()
	defer record.mu.Unlock()
	if len(record.gone) != 0 {
		t.Fatalf("gone %v, want none", record.gone)
	}
}

// A caller can read a spec and then wait on the instance's start lock while a
// removal finishes. Its spec must not bring the instance back.
func TestARemovedInstanceStaysGone(t *testing.T) {
	driver := &fakeDriver{}
	s, _ := newService(t, driver)
	definition := spec(`{}`)
	startRegistered(t, s, definition)
	s.RemoveInstance(definition.InstanceID)
	if !driver.instances()[0].closed() {
		t.Fatal("removal left the process running")
	}
	if _, err := s.start(context.Background(), definition, "", false); !errors.Is(err, errNotInstalled) {
		t.Fatalf("start with the old spec = %v, want %v", err, errNotInstalled)
	}
	if opened := len(driver.instances()); opened != 1 {
		t.Fatalf("opened %d processes, want 1", opened)
	}
	if _, ok := s.Info(definition.InstanceID); ok {
		t.Fatal("the removed instance is still listed")
	}
}

// An instance whose process exited starts again when it's next needed, and
// its exit says its generation is gone.
func TestExitedInstanceRestartsWhenNeeded(t *testing.T) {
	driver := &fakeDriver{}
	service, record := newService(t, driver)
	startRegistered(t, service, spec(`{}`))
	exited := driver.instances()[0]
	_, generation, _ := service.Instance(context.Background(), "agent", "")
	_ = exited.Close()
	exited.host.Exited()
	instance, _, err := service.Instance(context.Background(), "agent", "")
	if err != nil || len(driver.instances()) != 2 || instance != driver.instances()[1] {
		t.Fatalf("instance = %v, %v after %d opens; want a new process", instance, err, len(driver.instances()))
	}
	record.mu.Lock()
	defer record.mu.Unlock()
	if len(record.gone) != 1 || record.gone[0] != generation {
		t.Fatalf("gone %v, want the exited generation %d", record.gone, generation)
	}
}

// A process that finishes starting while the service closes is closed, not
// kept: nothing would ever close it.
func TestStartFinishingDuringCloseIsClosed(t *testing.T) {
	driver := &fakeDriver{gate: make(chan struct{})}
	service, _ := newService(t, driver)
	if err := service.RegisterInstance(spec(`{}`)); err != nil {
		t.Fatal(err)
	}
	started := make(chan error, 1)
	go func() {
		_, err := service.StartConfiguredInstance(context.Background(), "agent", "")
		started <- err
	}()
	// Close once the start is inside Open.
	deadline := time.Now().Add(5 * time.Second)
	for {
		service.mu.Lock()
		launching := service.generation == 1
		service.mu.Unlock()
		if launching {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the start never reached Open")
		}
		time.Sleep(time.Millisecond)
	}
	service.Close()
	close(driver.gate)
	if err := <-started; err == nil {
		t.Fatal("a start that finished during close succeeded")
	}
	if instances := driver.instances(); len(instances) != 1 || !instances[0].closed() {
		t.Fatalf("instances = %d, closed %v; want the late process closed", len(instances), len(instances) == 1 && instances[0].closed())
	}
}
