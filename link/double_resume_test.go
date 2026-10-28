package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// twoProcessesOneSession is `claude --resume S` open twice: the older process
// is this test, the newer a sleep child, each with its registry and socket.
type twoProcessesOneSession struct {
	older, newer             int
	olderSocket, newerSocket string
	olderRings, newerRings   <-chan string
}

func (f *notifierFixture) openTwice(session string) twoProcessesOneSession {
	f.t.Helper()
	sleeper := exec.Command("sleep", "60")
	if err := sleeper.Start(); err != nil {
		f.t.Fatal(err)
	}
	f.t.Cleanup(func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() })
	s := twoProcessesOneSession{
		older: os.Getpid(), newer: sleeper.Process.Pid,
		olderSocket: filepath.Join(f.runtime, "older.sock"), newerSocket: filepath.Join(f.runtime, "newer.sock"),
	}
	s.olderRings, s.newerRings = listenWhole(f.t, s.olderSocket), listenWhole(f.t, s.newerSocket)
	for name, registry := range map[string]map[string]any{
		"older": {"pid": s.older, "sessionId": session, "messagingSocketPath": s.olderSocket, "startedAt": 1793169591221},
		"newer": {"pid": s.newer, "sessionId": session, "messagingSocketPath": s.newerSocket, "startedAt": 1793169600000},
	} {
		if err := writeAtomicJSON(filepath.Join(f.registry, name+".json"), registry, 0600); err != nil {
			f.t.Fatal(err)
		}
	}
	return s
}

func TestNewestSessionRegistryNeedsALinkAndAWinner(t *testing.T) {
	f := newNotifierFixture(t)
	s := f.openTwice("twice")
	registries, err := loadClaudeRegistries()
	if err != nil {
		t.Fatal(err)
	}
	mixed := sessionRegistration{ClaudeSessionID: "twice", PID: s.older, SocketPath: s.newerSocket}
	if got, others, ok := newestSessionRegistry(mixed, registries); !ok || got.PID != s.newer || len(others) != 1 || others[0] != s.older {
		t.Fatalf("newest = %+v others=%v ok=%t", got, others, ok)
	}
	if _, _, ok := newestSessionRegistry(sessionRegistration{ClaudeSessionID: "twice", SocketPath: "/elsewhere.sock"}, registries); ok {
		t.Fatal("a registration that points nowhere into the session was moved into it")
	}
	explicit := sessionRegistration{ClaudeSessionID: "twice", PID: s.older, SocketPath: "/explicit.sock"}
	for _, only := range registries {
		if _, _, ok := newestSessionRegistry(explicit, []claudeRegistry{only}); ok {
			t.Fatal("a session open once overrode an explicit --socket")
		}
	}
	for i := range registries {
		registries[i].StartedAt = 1793169591221
	}
	if _, _, ok := newestSessionRegistry(mixed, registries); ok {
		t.Fatal("a tie on startedAt picked a winner")
	}
}

func TestRegisterAfterSecondResumeTakesTheNewProcess(t *testing.T) {
	f := newNotifierFixture(t)
	s := f.openTwice("twice")
	for _, step := range []struct {
		socket string
		pid    int
	}{{s.olderSocket, s.older}, {s.newerSocket, s.newer}} {
		// what SessionStart passes: its own socket, no pid
		if err := registerForTest(t, "--identity", "twice", "--session-id", "twice", "--pid", "0",
			"--socket", step.socket, "--kind", "interactive"); err != nil {
			t.Fatal(err)
		}
		registrations, err := loadRegistrations(f.runtime, f.bootID)
		if err != nil || len(registrations) != 1 {
			t.Fatalf("registrations=%v err=%v", registrations, err)
		}
		for _, reg := range registrations {
			lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "twice.lease"))
			if reg.PID != step.pid || reg.SocketPath != step.socket || lease.PID != step.pid || lease.PIDStart != reg.PIDStart {
				t.Fatalf("socket %s: registration %+v lease %+v", step.socket, reg, lease)
			}
		}
	}
}

func TestConduitRingsNewestOfDoublyResumedSession(t *testing.T) {
	f := newNotifierFixture(t)
	s := f.openTwice("twice")
	start, err := processStart(s.older, f.bootID)
	if err != nil {
		t.Fatal(err)
	}
	// what an earlier register left on a second resume: the old pid, the new socket
	reg := sessionRegistration{
		BootID: f.bootID, InstanceID: "twice-instance", Identity: "twice", PID: s.older, PIDStart: start,
		ClaudeSessionID: "twice", SocketPath: s.newerSocket, Kind: "interactive", Phase: "ready",
		StartedAt: time.Now().UTC().Format(time.RFC3339Nano), LeaseEpoch: 1,
	}
	writeRegistrationForTest(t, f.runtime, reg)
	f.writeLease("twice", &reg, "owned", 1)
	f.stageMessage("twice")
	f.notifier.scan()
	select {
	case <-s.newerRings:
	case <-time.After(2 * time.Second):
		t.Fatalf("newest process not rung; log:\n%s", f.logs.String())
	}
	time.Sleep(100 * time.Millisecond)
	if len(s.olderRings) != 0 {
		t.Fatal("older process rung")
	}
	var stored sessionRegistration
	if err := readJSON(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json"), &stored); err != nil {
		t.Fatal(err)
	}
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "twice.lease"))
	if stored.PID != s.newer || stored.SocketPath != s.newerSocket || lease.PID != s.newer || lease.PIDStart != stored.PIDStart {
		t.Fatalf("registration %+v lease %+v", stored, lease)
	}
	f.notifier.scan()
	pids := "pids " + strconv.Itoa(s.newer) + "," + strconv.Itoa(s.older) + ";"
	if got := strings.Count(f.logs.String(), pids); got != 1 {
		t.Fatalf("%q logged %d times:\n%s", pids, got, f.logs.String())
	}
}
