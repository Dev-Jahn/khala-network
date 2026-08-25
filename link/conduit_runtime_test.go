package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

type lockedLogBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *lockedLogBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *lockedLogBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

type conduitFixture struct {
	t          *testing.T
	home       string
	runtime    string
	registry   string
	bootID     string
	logs       *lockedLogBuffer
	conduit    *conduit
	listeners  []net.Listener
	deliveries map[string]*atomic.Int64
}

func newConduitFixture(t *testing.T) *conduitFixture {
	t.Helper()
	root, err := os.MkdirTemp(os.Getenv("HOME"), ".kct-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	home := filepath.Join(root, "home")
	runtimeRoot := filepath.Join(root, "runtime")
	registry := filepath.Join(root, "registry")
	for _, dir := range []string{
		filepath.Join(home, "inbox"), registry,
		filepath.Join(runtimeRoot, "sessions"), filepath.Join(runtimeRoot, "identities"),
		filepath.Join(runtimeRoot, "deliveries"), filepath.Join(runtimeRoot, "channels"),
	} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("KHALA_CLAUDE_SESSIONS_DIR", registry)
	t.Setenv("KHALA_RUNTIME_DIR", runtimeRoot)
	t.Setenv("KHALA_TEST_BOOT_ID", "test-boot")
	t.Setenv("KHALA_HOME", home)
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		t.Fatal(err)
	}
	logs := &lockedLogBuffer{}
	f := &conduitFixture{
		t: t, home: home, runtime: runtimeRoot, registry: registry, bootID: "test-boot",
		logs: logs, deliveries: make(map[string]*atomic.Int64),
	}
	f.conduit = &conduit{
		home: home, runtime: runtimeRoot, bootID: f.bootID, self: "alpha",
		logger: log.New(logs, "", 0), scanEvery: 10 * time.Second,
		backoff: []time.Duration{time.Second}, degradeAt: 3, states: make(map[string]*conduitState),
		verificationReasons: make(map[string]string),
		watcher:             watcher, watchedDir: make(map[string]struct{}),
	}
	t.Cleanup(func() {
		_ = watcher.Close()
		for _, listener := range f.listeners {
			_ = listener.Close()
		}
	})
	return f
}

func (f *conduitFixture) addRegistration(identity, instance, kind string, receiveOptIn bool, startedAt time.Time, epoch uint64) sessionRegistration {
	f.t.Helper()
	socketPath := filepath.Join(f.runtime, instance+".sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		f.t.Fatal(err)
	}
	f.listeners = append(f.listeners, listener)
	deliveries := &atomic.Int64{}
	f.deliveries[instance] = deliveries
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_, _ = bufio.NewReader(conn).ReadBytes('\n')
			deliveries.Add(1)
			_ = conn.Close()
		}
	}()
	pid := os.Getpid()
	pidStart, err := processStart(pid, f.bootID)
	if err != nil {
		f.t.Fatal(err)
	}
	sessionID := instance + "-session"
	registry := map[string]any{
		"pid": pid, "sessionId": sessionID, "name": instance, "version": "test",
		"messagingSocketPath": socketPath,
	}
	if err := writeAtomicJSON(filepath.Join(f.registry, instance+".json"), registry, 0600); err != nil {
		f.t.Fatal(err)
	}
	reg := sessionRegistration{
		BootID: f.bootID, InstanceID: instance, Identity: identity, PID: pid, PIDStart: pidStart,
		ClaudeSessionID: sessionID, SocketPath: socketPath, Kind: kind, ReceiveOptIn: receiveOptIn,
		Phase: "ready", CCVersion: "test", StartedAt: startedAt.UTC().Format(time.RFC3339Nano),
		LeaseEpoch: epoch, ConduitVerified: true, VerifiedAt: startedAt.UTC().Format(time.RFC3339Nano),
	}
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", instance+".json"), reg, 0600); err != nil {
		f.t.Fatal(err)
	}
	return reg
}

func (f *conduitFixture) writeLease(identity string, reg *sessionRegistration, state string, epoch uint64) {
	f.t.Helper()
	lease := identityLease{
		BootID: f.bootID, Identity: identity, Epoch: epoch,
		ClaimedAt: time.Now().UTC().Format(time.RFC3339Nano), State: state,
	}
	if reg != nil {
		lease.InstanceID = reg.InstanceID
		lease.PID = reg.PID
		lease.PIDStart = reg.PIDStart
		lease.ClaudeSessionID = reg.ClaudeSessionID
	}
	if err := writeAtomicJSON(filepath.Join(f.runtime, "identities", identity+".lease"), lease, 0600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *conduitFixture) stageLetter(identity string) {
	f.t.Helper()
	dir := filepath.Join(f.home, "inbox", identity, "new")
	if err := os.MkdirAll(dir, 0700); err != nil {
		f.t.Fatal(err)
	}
	content := "From: sender@alpha\nSubject: reclaim\n\nbody\n"
	if err := os.WriteFile(filepath.Join(dir, "1700000000.1.1.sender@alpha"), []byte(content), 0600); err != nil {
		f.t.Fatal(err)
	}
}

func readLeaseForTest(t *testing.T, path string) identityLease {
	t.Helper()
	var lease identityLease
	if err := readJSON(path, &lease); err != nil {
		t.Fatal(err)
	}
	return lease
}

func waitForTest(timeout time.Duration, condition func() bool) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return condition()
}

func TestCurrentBootIDPrefersDarwinBootSessionUUID(t *testing.T) {
	originalGOOS := bootIDGOOS
	originalReadFile := bootIDReadFile
	originalSysctl := bootIDSysctl
	originalFallbackLog := bootIDFallbackLog
	t.Cleanup(func() {
		bootIDGOOS = originalGOOS
		bootIDReadFile = originalReadFile
		bootIDSysctl = originalSysctl
		bootIDFallbackLog = originalFallbackLog
		bootIDFallbackOnce = sync.Once{}
	})
	t.Setenv("KHALA_TEST_BOOT_ID", "")

	t.Run("darwin uuid", func(t *testing.T) {
		bootIDGOOS = "darwin"
		bootIDReadFile = func(string) ([]byte, error) { return nil, os.ErrNotExist }
		var calls []string
		bootIDSysctl = func(name string) ([]byte, error) {
			calls = append(calls, name)
			switch name {
			case "kern.bootsessionuuid":
				return []byte("  7C31CC4D-59BA-4BBB-A613-789DA0AFB3A1\n"), nil
			case "kern.boottime":
				return []byte("{ sec = 1786350406, usec = 0 }\n"), nil
			default:
				return nil, fmt.Errorf("unexpected sysctl %s", name)
			}
		}
		got, err := currentBootID()
		if err != nil {
			t.Fatal(err)
		}
		if got != "7C31CC4D-59BA-4BBB-A613-789DA0AFB3A1" {
			t.Fatalf("boot id=%q, want bootsessionuuid; sysctl calls=%v", got, calls)
		}
		if len(calls) != 1 || calls[0] != "kern.bootsessionuuid" {
			t.Fatalf("sysctl calls=%v, want only kern.bootsessionuuid", calls)
		}
	})

	t.Run("darwin boottime fallback", func(t *testing.T) {
		bootIDFallbackOnce = sync.Once{}
		fallbackLogs := 0
		bootIDFallbackLog = func() { fallbackLogs++ }
		bootIDGOOS = "darwin"
		bootIDReadFile = func(string) ([]byte, error) { return nil, os.ErrNotExist }
		var calls []string
		bootIDSysctl = func(name string) ([]byte, error) {
			calls = append(calls, name)
			if name == "kern.bootsessionuuid" {
				return []byte(" \n"), nil
			}
			return []byte(" { sec = 1786350406, usec = 0 } \n"), nil
		}
		got, err := currentBootID()
		if err != nil {
			t.Fatal(err)
		}
		if got != "{ sec = 1786350406, usec = 0 }" {
			t.Fatalf("boot id=%q, want trimmed kern.boottime", got)
		}
		if want := []string{"kern.bootsessionuuid", "kern.boottime"}; strings.Join(calls, "|") != strings.Join(want, "|") {
			t.Fatalf("sysctl calls=%v, want %v", calls, want)
		}
		if _, err := currentBootID(); err != nil {
			t.Fatal(err)
		}
		if fallbackLogs != 1 {
			t.Fatalf("fallback log count=%d, want 1", fallbackLogs)
		}
	})

	t.Run("linux proc wins", func(t *testing.T) {
		bootIDGOOS = "linux"
		bootIDReadFile = func(path string) ([]byte, error) {
			if path != "/proc/sys/kernel/random/boot_id" {
				return nil, fmt.Errorf("unexpected path %s", path)
			}
			return []byte(" linux-boot-id\n"), nil
		}
		bootIDSysctl = func(name string) ([]byte, error) {
			t.Fatalf("sysctl called on linux: %s", name)
			return nil, nil
		}
		got, err := currentBootID()
		if err != nil {
			t.Fatal(err)
		}
		if got != "linux-boot-id" {
			t.Fatalf("boot id=%q, want linux-boot-id", got)
		}
	})
}

func deadRegistration(bootID, identity, instance string, startedAt time.Time) sessionRegistration {
	return sessionRegistration{
		BootID: bootID, InstanceID: instance, Identity: identity, PID: os.Getpid(),
		PIDStart: bootID + ":not-the-current-process-start", ClaudeSessionID: instance + "-session",
		Kind: "interactive", Phase: "ready", StartedAt: startedAt.UTC().Format(time.RFC3339Nano),
	}
}

func writeRegistrationForTest(t *testing.T, root string, reg sessionRegistration) {
	t.Helper()
	if err := writeAtomicJSON(filepath.Join(root, "sessions", reg.InstanceID+".json"), reg, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestRegistrationReappearsAndReclaimsAfterBootIDChange(t *testing.T) {
	f := newConduitFixture(t)
	old := deadRegistration("boot-A", "ink", "old", time.Now().Add(-time.Hour))
	writeRegistrationForTest(t, f.runtime, old)
	regs, err := loadRegistrations(f.runtime, f.bootID)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := regs[old.InstanceID]; ok {
		t.Fatalf("registration under boot id A was visible under boot id B: %+v", regs)
	}
	staleLease := identityLease{
		BootID: old.BootID, Identity: old.Identity, InstanceID: old.InstanceID, Epoch: 7,
		PID: old.PID, PIDStart: old.PIDStart, ClaudeSessionID: old.ClaudeSessionID,
		ClaimedAt: time.Now().Add(-time.Hour).UTC().Format(time.RFC3339Nano), State: "owned",
	}
	if err := writeAtomicJSON(filepath.Join(f.runtime, "identities", "ink.lease"), staleLease, 0600); err != nil {
		t.Fatal(err)
	}
	fresh := f.addRegistration("ink", "fresh", "interactive", false, time.Now(), 0)
	f.conduit.scan()
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "ink.lease"))
	if lease.BootID != f.bootID || lease.InstanceID != fresh.InstanceID || lease.State != "owned" || lease.Epoch == 0 {
		t.Fatalf("fresh boot-B registration did not reclaim stale boot-A lease: %+v", lease)
	}
}

func TestConduitReapsOnlyEligibleDeadRegistrations(t *testing.T) {
	f := newConduitFixture(t)
	old := deadRegistration(f.bootID, "stale", "dead-old", time.Now().Add(-11*time.Minute))
	fresh := deadRegistration(f.bootID, "fresh", "dead-fresh", time.Now().Add(-9*time.Minute))
	foreign := deadRegistration("other-boot", "foreign", "dead-foreign", time.Now().Add(-time.Hour))
	owned := deadRegistration(f.bootID, "owned", "dead-owned", time.Now().Add(-time.Hour))
	for _, reg := range []sessionRegistration{old, fresh, foreign, owned} {
		writeRegistrationForTest(t, f.runtime, reg)
	}
	f.writeLease(owned.Identity, &owned, "owned", 1)

	f.conduit.scan()
	f.conduit.scan()
	for instance, wantExists := range map[string]bool{
		old.InstanceID: false, fresh.InstanceID: true, foreign.InstanceID: true, owned.InstanceID: true,
	} {
		_, err := os.Stat(filepath.Join(f.runtime, "sessions", instance+".json"))
		if gotExists := err == nil; gotExists != wantExists {
			t.Fatalf("registration %s exists=%t want %t (err=%v)", instance, gotExists, wantExists, err)
		}
	}
	wantLog := "reaped dead registration dead-old (stale)"
	if got := strings.Count(f.logs.String(), wantLog); got != 1 {
		t.Fatalf("reap log count=%d want 1; logs=%s", got, f.logs.String())
	}
}

func TestConduitReclaimsBeforeReapingDeadLeaseOwner(t *testing.T) {
	f := newConduitFixture(t)
	dead := deadRegistration(f.bootID, "shared", "dead-owner", time.Now().Add(-time.Hour))
	writeRegistrationForTest(t, f.runtime, dead)
	f.writeLease(dead.Identity, &dead, "owned", 3)
	live := f.addRegistration("shared", "live-candidate", "interactive", false, time.Now(), 0)

	f.conduit.scan()
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "shared.lease"))
	if lease.InstanceID != live.InstanceID || lease.State != "owned" {
		t.Fatalf("live registration did not reclaim lease: %+v", lease)
	}
	if _, err := os.Stat(filepath.Join(f.runtime, "sessions", dead.InstanceID+".json")); !os.IsNotExist(err) {
		t.Fatalf("dead former owner still exists after reclaim: %v", err)
	}
	logs := f.logs.String()
	reclaimedAt := strings.Index(logs, "reclaimed lease shared for instance live-candidate")
	reapedAt := strings.Index(logs, "reaped dead registration dead-owner (shared)")
	if reclaimedAt < 0 || reapedAt < 0 || reclaimedAt > reapedAt {
		t.Fatalf("reclaim did not precede reap; logs=%s", logs)
	}
}

func TestConduitVerificationLogsOnlyStateChanges(t *testing.T) {
	f := newConduitFixture(t)
	reg := f.addRegistration("ink", "state", "interactive", false, time.Now(), 0)
	reg.Phase = "starting"
	reg.ConduitVerified = false
	reg.VerifiedAt = ""
	writeRegistrationForTest(t, f.runtime, reg)

	for i := 0; i < 3; i++ {
		f.conduit.scan()
	}
	phaseLog := "registration state not verified: phase is not ready"
	if got := strings.Count(f.logs.String(), phaseLog); got != 1 {
		t.Fatalf("unchanged reason log count=%d want 1; logs=%s", got, f.logs.String())
	}
	if err := os.Remove(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json")); err != nil {
		t.Fatal(err)
	}
	f.conduit.scan()
	writeRegistrationForTest(t, f.runtime, reg)
	f.conduit.scan()
	if got := strings.Count(f.logs.String(), phaseLog); got != 2 {
		t.Fatalf("reason was not logged after registration disappeared and returned: got %d; logs=%s", got, f.logs.String())
	}

	reg.Phase = "ready"
	reg.Kind = "worker"
	reg.ReceiveOptIn = false
	writeRegistrationForTest(t, f.runtime, reg)
	for i := 0; i < 2; i++ {
		f.conduit.scan()
	}
	reasonLog := "registration state not verified: non-interactive registration lacks opt-in"
	if got := strings.Count(f.logs.String(), reasonLog); got != 1 {
		t.Fatalf("changed reason log count=%d want 1; logs=%s", got, f.logs.String())
	}

	reg.Kind = "interactive"
	writeRegistrationForTest(t, f.runtime, reg)
	for i := 0; i < 2; i++ {
		f.conduit.scan()
	}
	if got := strings.Count(f.logs.String(), "registration state verified"); got != 1 {
		t.Fatalf("recovery log count=%d want 1; logs=%s", got, f.logs.String())
	}
}

func TestWithRuntimeLockDoesNotRewriteUnchangedBootID(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".leases.lock")
	if err := withRuntimeLock(path, "test-boot", func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	old := time.Unix(1_700_000_000, 123456789)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if err := withRuntimeLock(path, "test-boot", func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("unchanged lock content was rewritten: before=%q after=%q", before, after)
	}
	if !info.ModTime().Equal(old) {
		t.Fatalf("unchanged lock mtime changed: got %s want %s", info.ModTime(), old)
	}
}

func TestHealLeaseAlreadyCurrentDoesNotAcquireRuntimeLock(t *testing.T) {
	f := newConduitFixture(t)
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &reg, "owned", 3)
	lockPath := filepath.Join(f.runtime, "identities", ".leases.lock")
	content := []byte("{\"bootId\":\"test-boot\"}\n")
	if err := os.WriteFile(lockPath, content, 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Unix(1_700_000_000, 123456789)
	if err := os.Chtimes(lockPath, old, old); err != nil {
		t.Fatal(err)
	}
	f.conduit.healLease(reg)
	info, err := os.Stat(lockPath)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(old) {
		t.Fatalf("already-current heal touched runtime lock: got %s want %s", info.ModTime(), old)
	}
}

func TestConduitWatcherDoesNotSelfFeedAndDebounces(t *testing.T) {
	f := newConduitFixture(t)
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &reg, "owned", 3)
	markerPID := os.Getpid()
	markerStart, err := processStart(markerPID, f.bootID)
	if err != nil {
		t.Fatal(err)
	}
	markerSocket := filepath.Join(f.runtime, "marker.sock")
	marker := sessionRegistration{
		BootID: f.bootID, InstanceID: "marker", Identity: "marker", Kind: "interactive",
		PID: markerPID, PIDStart: markerStart, ClaudeSessionID: "marker-session",
		SocketPath: markerSocket, Phase: "ready",
		StartedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", "marker.json"), marker, 0600); err != nil {
		t.Fatal(err)
	}
	markerRegistry := map[string]any{
		"pid": markerPID, "sessionId": marker.ClaudeSessionID, "name": marker.InstanceID,
		"version": "test", "messagingSocketPath": markerSocket,
	}
	if err := writeAtomicJSON(filepath.Join(f.registry, "marker.json"), markerRegistry, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- f.conduit.run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	countStates := func() int { return strings.Count(f.logs.String(), "registration marker ") }
	if !waitForTest(time.Second, func() bool { return countStates() >= 1 }) {
		t.Fatal("initial scan did not complete")
	}
	if waitForTest(300*time.Millisecond, func() bool { return countStates() > 1 }) {
		t.Fatalf("scan fed its own fsnotify loop: %d state changes", countStates())
	}
	markerListener, err := net.Listen("unix", markerSocket)
	if err != nil {
		t.Fatal(err)
	}
	f.listeners = append(f.listeners, markerListener)
	for i := 0; i < 10; i++ {
		path := filepath.Join(f.runtime, "identities", fmt.Sprintf(".tmp-%d", i))
		if err := os.WriteFile(path, []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	time.Sleep(300 * time.Millisecond)
	if got := countStates(); got != 1 {
		t.Fatalf("dotfile events triggered a verification state change: got %d want 1", got)
	}
	for i := 0; i < 10; i++ {
		if i%2 == 0 {
			if err := markerListener.Close(); err != nil {
				t.Fatal(err)
			}
			_ = os.Remove(markerSocket)
		} else {
			markerListener, err = net.Listen("unix", markerSocket)
			if err != nil {
				t.Fatal(err)
			}
			f.listeners = append(f.listeners, markerListener)
		}
		path := filepath.Join(f.runtime, "identities", fmt.Sprintf("event-%d", i))
		if err := os.WriteFile(path, []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !waitForTest(time.Second, func() bool { return countStates() >= 2 }) {
		t.Fatal("visible watcher burst did not trigger a scan")
	}
	time.Sleep(300 * time.Millisecond)
	if got := countStates(); got != 2 {
		t.Fatalf("watcher burst was not coalesced: got %d state changes want 2", got)
	}
}

func TestConduitReclaimsReleasedLeaseAndAttemptsDelivery(t *testing.T) {
	f := newConduitFixture(t)
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", nil, "released", 3)
	f.stageLetter("ink")
	if letters := f.conduit.pending("ink"); len(letters) != 1 {
		t.Fatalf("pending fixture has %d letters, want 1", len(letters))
	}
	f.conduit.scan()
	leasePath := filepath.Join(f.runtime, "identities", "ink.lease")
	lease := readLeaseForTest(t, leasePath)
	if lease.State != "owned" || lease.InstanceID != reg.InstanceID || lease.Epoch != 4 {
		t.Fatalf("released lease was not reclaimed: %+v", lease)
	}
	var updated sessionRegistration
	if err := readJSON(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json"), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.LeaseEpoch != lease.Epoch {
		t.Fatalf("registration epoch=%d lease epoch=%d", updated.LeaseEpoch, lease.Epoch)
	}
	wantLog := "reclaimed lease ink for instance owner"
	if got := strings.Count(f.logs.String(), wantLog); got != 1 {
		t.Fatalf("reclaim log count=%d want 1; logs=%s", got, f.logs.String())
	}
	if !waitForTest(time.Second, func() bool { return f.deliveries[reg.InstanceID].Load() == 1 }) {
		entries, journalErr := os.ReadDir(filepath.Join(f.runtime, "deliveries", "ink", reg.InstanceID))
		t.Fatalf("pending letter did not receive a doorbell attempt after reclaim; pending=%d logs=%s journal entries=%d err=%v",
			len(f.conduit.pending("ink")), f.logs.String(), len(entries), journalErr)
	}
	entries, err := os.ReadDir(filepath.Join(f.runtime, "deliveries", "ink", reg.InstanceID))
	if err != nil || len(entries) != 1 {
		t.Fatalf("delivery attempt was not journaled: entries=%d err=%v", len(entries), err)
	}
}

func TestConduitDoesNotReclaimLiveOwner(t *testing.T) {
	f := newConduitFixture(t)
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &reg, "owned", 3)
	leasePath := filepath.Join(f.runtime, "identities", "ink.lease")
	before, err := os.ReadFile(leasePath)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		f.conduit.scan()
	}
	after, err := os.ReadFile(leasePath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("live owner lease changed: before=%s after=%s", before, after)
	}
	if strings.Contains(f.logs.String(), "reclaimed lease") {
		t.Fatalf("live owner was reclaimed: %s", f.logs.String())
	}
}

func TestConduitReclaimChoosesNewestRegistrationWithoutFlapping(t *testing.T) {
	f := newConduitFixture(t)
	older := f.addRegistration("shared", "older", "interactive", false, time.Now().Add(-2*time.Hour), 7)
	newer := f.addRegistration("shared", "newer", "interactive", false, time.Now().Add(-time.Hour), 7)
	_ = older
	f.writeLease("shared", nil, "released", 7)
	for i := 0; i < 3; i++ {
		f.conduit.scan()
		lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "shared.lease"))
		if lease.InstanceID != newer.InstanceID || lease.Epoch != 8 || lease.State != "owned" {
			t.Fatalf("scan %d selected unstable reclaim owner: %+v", i+1, lease)
		}
	}
	if got := strings.Count(f.logs.String(), "reclaimed lease shared for instance newer"); got != 1 {
		t.Fatalf("stable reclaim logged %d times, want 1; logs=%s", got, f.logs.String())
	}
}

func TestForkSessionAncestorCannotTakeOverLiveInteractiveOwner(t *testing.T) {
	f := newConduitFixture(t)
	owner := f.addRegistration("shared", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("shared", &owner, "owned", 3)

	processDir := t.TempDir()
	claudePath := filepath.Join(processDir, "claude")
	hostPath := filepath.Join(processDir, "bg-pty-host")
	if err := os.Symlink("/bin/sleep", claudePath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/bin/sh", hostPath); err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("%q 30 & child=$!; printf '%%s\\n' \"$child\"; wait \"$child\"", claudePath)
	cmd := exec.Command(hostPath, "-c", script, "--fork-session")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() {
		_ = cmd.Process.Kill()
		t.Fatalf("fork fixture did not report child pid: %v", scanner.Err())
	}
	childPID, err := strconv.Atoi(scanner.Text())
	if err != nil {
		_ = cmd.Process.Kill()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(childPID, syscall.SIGTERM)
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})

	kind := detectSessionKind(childPID)
	if kind != "worker" {
		t.Fatalf("fork session under bg-pty-host detected as %q, want worker", kind)
	}
	workerStart, err := processStart(childPID, f.bootID)
	if err != nil {
		t.Fatal(err)
	}
	worker := sessionRegistration{
		BootID: f.bootID, InstanceID: "worker", Identity: "shared", PID: childPID,
		PIDStart: workerStart, ClaudeSessionID: "worker-session", Kind: kind,
		ReceiveOptIn: true, Phase: "ready", StartedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	claimed, _, claimErr := claimLease(f.runtime, f.bootID, &worker, true)
	if claimErr == nil || claimed {
		t.Fatalf("fork worker takeover succeeded: claimed=%t err=%v", claimed, claimErr)
	}
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "shared.lease"))
	if lease.InstanceID != owner.InstanceID || lease.State != "owned" || lease.Epoch != 3 {
		t.Fatalf("fork worker changed live owner: %+v", lease)
	}
}

func TestRuntimeReleaseOnlyClearsOwnedLeaseAndLogs(t *testing.T) {
	f := newConduitFixture(t)
	owner := f.addRegistration("shared", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	worker := f.addRegistration("shared", "worker", "worker", true, time.Now().Add(-30*time.Minute), 3)
	f.writeLease("shared", &owner, "owned", 3)
	leasePath := filepath.Join(f.runtime, "identities", "shared.lease")
	if err := runtimeRelease([]string{"--identity", "shared", "--instance", worker.InstanceID}); err != nil {
		t.Fatal(err)
	}
	lease := readLeaseForTest(t, leasePath)
	if lease.InstanceID != owner.InstanceID || lease.State != "owned" {
		t.Fatalf("non-owner release cleared owner lease: %+v", lease)
	}
	if strings.Contains(f.logs.String(), "released lease") {
		t.Fatalf("non-owner release was logged as a lease release: %s", f.logs.String())
	}
	if err := runtimeRelease([]string{"--identity", "shared", "--instance", owner.InstanceID}); err != nil {
		t.Fatal(err)
	}
	lease = readLeaseForTest(t, leasePath)
	if lease.InstanceID != "" || lease.State != "released" || lease.Epoch != 3 {
		t.Fatalf("owner release did not preserve epoch and clear ownership: %+v", lease)
	}
	logPath := filepath.Join(f.home, "log", "conduit.log")
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	want := "released lease shared for instance owner"
	if got := strings.Count(string(data), want); got != 1 {
		t.Fatalf("release log count=%d want 1; log=%s", got, data)
	}
}
