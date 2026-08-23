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
		watcher: watcher, watchedDir: make(map[string]struct{}),
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
	marker := sessionRegistration{
		BootID: f.bootID, InstanceID: "marker", Identity: "marker", Kind: "interactive",
		PID: 2, PIDStart: "test-boot:invalid", Phase: "starting",
		StartedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", "marker.json"), marker, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- f.conduit.run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	countScans := func() int { return strings.Count(f.logs.String(), "registration marker not verified") }
	if !waitForTest(time.Second, func() bool { return countScans() >= 1 }) {
		t.Fatal("initial scan did not complete")
	}
	if waitForTest(300*time.Millisecond, func() bool { return countScans() > 1 }) {
		t.Fatalf("scan fed its own fsnotify loop: %d scans", countScans())
	}
	for i := 0; i < 10; i++ {
		path := filepath.Join(f.runtime, "identities", fmt.Sprintf(".tmp-%d", i))
		if err := os.WriteFile(path, []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	time.Sleep(300 * time.Millisecond)
	if got := countScans(); got != 1 {
		t.Fatalf("dotfile events triggered scans: got %d want 1", got)
	}
	for i := 0; i < 10; i++ {
		path := filepath.Join(f.runtime, "identities", fmt.Sprintf("event-%d", i))
		if err := os.WriteFile(path, []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if !waitForTest(time.Second, func() bool { return countScans() >= 2 }) {
		t.Fatal("visible watcher burst did not trigger a scan")
	}
	time.Sleep(300 * time.Millisecond)
	if got := countScans(); got != 2 {
		t.Fatalf("watcher burst was not coalesced: got %d scans want 2", got)
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
