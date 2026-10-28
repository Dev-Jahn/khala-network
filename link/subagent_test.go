package main

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// holdersForTest runs `runtime holders` and returns what it printed.
func holdersForTest(t *testing.T, identity string) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	runErr := runtimeHolders([]string{"--identity", identity})
	_ = w.Close()
	os.Stdout = old
	data, err := io.ReadAll(r)
	_ = r.Close()
	if err != nil {
		t.Fatal(err)
	}
	if runErr != nil {
		t.Fatalf("holders %s: %v", identity, runErr)
	}
	return string(data)
}

func TestRuntimeHoldersListsOnlyLiveRegistrationsOfTheName(t *testing.T) {
	f := newNotifierFixture(t)
	if got := holdersForTest(t, "ink"); got != "" {
		t.Fatalf("free name printed %q", got)
	}
	f.addRegistration("ink", "ink-live", "interactive", false, time.Now(), 1)
	writeRegistrationForTest(t, f.runtime, deadRegistration(f.bootID, "ink", "ink-dead", time.Now().Add(-time.Hour)))
	f.addRegistration("other", "other-live", "interactive", false, time.Now(), 1)
	lane := withHarness(t, f.addRegistration("ink", "ink-lane", "worker", false, time.Now(), 0), "codex")
	lane.SocketPath = ""
	writeRegistrationForTest(t, f.runtime, lane)
	pid := strconv.Itoa(os.Getpid())
	want := "ink-lane codex worker " + pid + "\nink-live claude interactive " + pid + "\n"
	if got := holdersForTest(t, "ink"); got != want {
		t.Fatalf("holders=%q want %q", got, want)
	}
	if err := runtimeHolders([]string{"--identity", "Bad_Name"}); err == nil {
		t.Fatal("an invalid name was accepted")
	}
}

// The registration the Claude plugin makes for a subagent (plugin/hooks/
// subagent.sh): a socketless Claude worker whose pid is the main Claude Code
// process. The main's Claude registry has that pid, so the registration must
// not adopt the main's socket; the conduit neither rings it nor logs it as a
// fault; while it lives no parent notice goes out, and once it is released the
// parent hears about later letters once.
func TestClaudeSubagentWorkerIsSilentAndHandsLateMailToItsParent(t *testing.T) {
	f := newNotifierFixture(t)
	main := f.addRegistration("main", "main-inst", "interactive", false, time.Now(), 1)
	f.writeLease("main", &main, "owned", 1)
	pid := strconv.Itoa(os.Getpid())
	err := registerForTest(t, "--identity", "sub", "--phase", "ready", "--harness", "claude", "--kind", "worker",
		"--receive-opt-in=false", "--socket", "", "--pid", pid, "--session-id", "agent-a0123456789abcdef",
		"--parent", "main@alpha")
	if err != nil {
		t.Fatal(err)
	}
	regs, err := loadRegistrations(f.runtime, f.bootID)
	if err != nil {
		t.Fatal(err)
	}
	var sub sessionRegistration
	for _, reg := range regs {
		if reg.Identity == "sub" {
			sub = reg
		}
	}
	if sub.InstanceID == "" || sub.SocketPath != "" || sub.Harness != "claude" || sub.Kind != "worker" || sub.ReceiveOptIn {
		t.Fatalf("subagent registration=%+v", sub)
	}
	if _, err := os.Stat(filepath.Join(f.runtime, "identities", "sub.lease")); !os.IsNotExist(err) {
		t.Fatalf("a worker without opt-in touched the lease (err=%v)", err)
	}
	if got := holdersForTest(t, "sub"); !strings.HasPrefix(got, sub.InstanceID+" claude worker ") {
		t.Fatalf("holders=%q", got)
	}

	f.stageMessageData("sub", "1700000000.1.1.ink@alpha", letterFor("sub"))
	f.notifier.parentGrace = testGrace
	for i := 0; i < 2; i++ {
		f.notifier.scan()
	}
	time.Sleep(2 * testGrace)
	f.notifier.scan()
	logs := f.logs.String()
	if strings.Contains(logs, "registration "+sub.InstanceID+" not verified") {
		t.Fatalf("the subagent worker was logged as a fault; logs=%s", logs)
	}
	if got := f.deliveries["main-inst"].Load(); got != 0 {
		t.Fatalf("the main was rung %d times for its subagent's letter", got)
	}
	if notices := spoolNotices(t, f.home, "alpha"); len(notices) != 0 {
		t.Fatalf("a parent notice went out while the subagent was live: %v", notices)
	}

	if err := runtimeRelease([]string{"--identity", "sub", "--instance", sub.InstanceID}); err != nil {
		t.Fatal(err)
	}
	if got := holdersForTest(t, "sub"); got != "" {
		t.Fatalf("a released subagent still holds its name: %q", got)
	}
	f.notifier.scan()
	time.Sleep(2 * testGrace)
	f.notifier.scan()
	f.notifier.scan()
	notices := spoolNotices(t, f.home, "alpha")
	if len(notices) != 1 {
		t.Fatalf("parent notices=%v want exactly one", notices)
	}
	data, err := os.ReadFile(notices[0])
	if err != nil || !strings.Contains(string(data), "To: main@alpha\n") ||
		!strings.Contains(string(data), "Subject: sub@alpha has 1 unread letter and no live session\n") {
		t.Fatalf("notice=%q err=%v", data, err)
	}
}
