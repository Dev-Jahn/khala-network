package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func withHarness(t *testing.T, reg sessionRegistration, harness string) sessionRegistration {
	t.Helper()
	data, err := json.Marshal(reg)
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	object["harness"] = harness
	data, err = json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &reg); err != nil {
		t.Fatal(err)
	}
	return reg
}

func TestCodexChannelWithoutClaudeSocket(t *testing.T) {
	f := newNotifierFixture(t)
	reg := withHarness(t, f.addRegistration("codex", "codex-owner", "interactive", false, time.Now(), 1), "codex")
	f.addChannel(&reg)
	reg.ChannelVerified = true
	reg.SocketPath = ""
	reg.CCVersion = "0.153.4"
	resolved, verified, reason := f.notifier.verifyRegistration(reg, nil)
	if !verified {
		t.Fatalf("Codex channel rejected: %s", reason)
	}
	f.writeLease("codex", &resolved, "owned", 1)
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "codex.lease"))
	row, err := f.notifier.buildListenerIdentityBase("codex", []sessionRegistration{resolved}, lease)
	if err != nil {
		t.Fatal(err)
	}
	if !row.Listening || row.Route != "channel" || row.CCVersion != "codex:0.153.4" {
		t.Fatalf("wrong Codex ear: %+v", row)
	}
	for _, bad := range []string{"unverified", "pid", "socket", "session"} {
		t.Run(bad, func(t *testing.T) {
			broken := reg
			switch bad {
			case "unverified":
				broken.ChannelVerified = false
			case "pid":
				broken.ChannelPIDStart = "wrong"
			case "socket":
				broken.ChannelSocket = "/missing.sock"
			case "session":
				broken.ClaudeSessionID = ""
			}
			_, ok, why := f.notifier.verifyRegistration(broken, nil)
			if ok {
				t.Fatal("invalid Codex channel verified")
			}
			if _, known := listenerReason(why); !known {
				t.Fatalf("unmapped ear reason %q", why)
			}
		})
	}
}

// A Codex worker is never rung (D18), so lacking a receive opt-in is not logged
// as a fault; it still is not verified, and any other worker still logs it.
func TestCodexWorkerWithoutOptInIsNotLoggedAsFault(t *testing.T) {
	f := newNotifierFixture(t)
	lane := withHarness(t, f.addRegistration("lane", "codex-worker", "worker", false, time.Now(), 0), "codex")
	lane.SocketPath = ""
	writeRegistrationForTest(t, f.runtime, lane)
	f.addRegistration("helper", "claude-worker", "worker", false, time.Now(), 0)
	for i := 0; i < 2; i++ {
		f.notifier.scan()
	}
	logs := f.logs.String()
	if strings.Contains(logs, "registration codex-worker not verified") {
		t.Fatalf("Codex worker logged as a fault; logs=%s", logs)
	}
	if got := strings.Count(logs, "registration claude-worker not verified: non-interactive registration lacks opt-in"); got != 1 {
		t.Fatalf("other worker opt-in log count=%d want 1; logs=%s", got, logs)
	}
	var stored sessionRegistration
	if err := readJSON(filepath.Join(f.runtime, "sessions", "codex-worker.json"), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.ConduitVerified {
		t.Fatal("the quiet Codex worker was verified")
	}
	if _, verified, reason := f.notifier.verifyRegistration(stored, nil); verified || reason != "non-interactive registration lacks opt-in" {
		t.Fatalf("verification changed: verified=%v reason=%q", verified, reason)
	}
}

func TestCodexChannelFailureNeverUsesClaudeSocket(t *testing.T) {
	f := newNotifierFixture(t)
	reg := withHarness(t, f.addRegistration("codex", "codex-owner", "interactive", false, time.Now(), 1), "codex")
	f.addChannel(&reg)
	reg.ChannelVerified = true
	reg.ChannelPIDStart = "dead-channel"
	f.writeLease("codex", &reg, "owned", 1)
	lease := readLeaseForTest(t, filepath.Join(f.runtime, "identities", "codex.lease"))
	f.stageMessageData("codex", "1700000000.1.1.ink@alpha", "From: ink@alpha\nType: message\nSubject: test\n\nbody\n")
	f.notifier.maybeNotify("codex", lease, reg, f.notifier.pending("codex"))
	time.Sleep(30 * time.Millisecond)
	if count := f.deliveries[reg.InstanceID].Load(); count != 0 {
		t.Fatalf("Codex channel failure wrote %d Claude socket frames", count)
	}
}

func TestLegacyClaudeStillRequiresItsSocketAndRegistry(t *testing.T) {
	f := newNotifierFixture(t)
	reg := f.addRegistration("ink", "claude-owner", "interactive", false, time.Now(), 1)
	f.addChannel(&reg)
	reg.ChannelVerified = true
	reg.SocketPath = ""
	for _, harness := range []string{"", "claude"} {
		legacy := withHarness(t, reg, harness)
		if _, verified, _ := f.notifier.verifyRegistration(legacy, nil); verified {
			t.Fatal("Claude channel must not bypass the existing socket/registry contract")
		}
	}
}

// Only a Codex registration may attach a channel (D18 r3); a Claude session's
// one route is its inbox socket. Everything else about the call is valid.
func TestRegisterChannelRefusesClaudeRegistration(t *testing.T) {
	f := newNotifierFixture(t)
	for _, harness := range []string{"", "claude", "codex"} {
		instance := "harness-" + firstNonempty(harness, "none")
		reg := withHarness(t, f.addRegistration("ink-"+firstNonempty(harness, "none"), instance, "interactive", false, time.Now(), 1), harness)
		f.addChannel(&reg)
		registered := reg
		registered.ChannelSocket, registered.ChannelPID, registered.ChannelPIDStart = "", 0, ""
		writeRegistrationForTest(t, f.runtime, registered)
		err := runtimeRegisterChannel([]string{"--instance", instance, "--session-id", reg.ClaudeSessionID,
			"--channel-socket", reg.ChannelSocket, "--caller-pid", strconv.Itoa(os.Getpid()), "--verified"})
		var stored sessionRegistration
		if readErr := readJSON(filepath.Join(f.runtime, "sessions", instance+".json"), &stored); readErr != nil {
			t.Fatal(readErr)
		}
		if harness == "codex" {
			if err != nil || stored.ChannelSocket != reg.ChannelSocket || !stored.ChannelVerified {
				t.Fatalf("Codex register-channel err=%v stored=%+v", err, stored)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), "a Claude session receives through its inbox socket") {
			t.Fatalf("harness %q register-channel err=%v", harness, err)
		}
		if stored.ChannelSocket != "" || stored.ChannelVerified {
			t.Fatalf("refused Claude registration was changed: %+v", stored)
		}
	}
}

func TestCodexRuntimeRegisterAndRelease(t *testing.T) {
	f := newNotifierFixture(t)
	args := []string{"--identity", "codex", "--instance", "codex-owned", "--session-id", "codex-thread", "--harness", "codex", "--kind", "interactive", "--pid", strconv.Itoa(os.Getpid())}
	if err := runtimeRegister(args, false); err != nil {
		t.Fatal(err)
	}
	var reg sessionRegistration
	if err := readJSON(filepath.Join(f.runtime, "sessions", "codex-owned.json"), &reg); err != nil {
		t.Fatal(err)
	}
	if reg.ClaudeSessionID != "codex-thread" || reg.SocketPath != "" {
		t.Fatalf("wrong registration: %+v", reg)
	}
	if err := runtimeRelease([]string{"--identity", "codex", "--instance", "codex-owned", "--session-id", "codex-thread"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(f.runtime, "sessions", "codex-owned.json")); !os.IsNotExist(err) {
		t.Fatal("registration not released")
	}
}

func TestCodexWatchReadyUsesChannel(t *testing.T) {
	f := newNotifierFixture(t)
	reg := withHarness(t, f.addRegistration("codex", "codex-watch", "interactive", false, time.Now(), 1), "codex")
	f.addChannel(&reg)
	reg.ChannelVerified = true
	reg.SocketPath = ""
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json"), reg, 0600); err != nil {
		t.Fatal(err)
	}
	f.writeLease("codex", &reg, "owned", 1)
	args := []string{"--identity", "codex", "--instance", reg.InstanceID, "--session-id", reg.ClaudeSessionID}
	if err := runtimeWatchReady(args); err != nil {
		t.Fatalf("Codex channel registration is not watch-ready: %v", err)
	}
	unverified := reg
	unverified.ChannelVerified = false
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json"), unverified, 0600); err != nil {
		t.Fatal(err)
	}
	if err := runtimeWatchReady(args); err == nil {
		t.Fatal("unverified Codex channel passed watch-ready")
	}
	legacy := withHarness(t, reg, "claude")
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json"), legacy, 0600); err != nil {
		t.Fatal(err)
	}
	if err := runtimeWatchReady(args); err == nil {
		t.Fatal("Claude registration without its socket passed watch-ready")
	}
}

func TestHarnessSessionIDEnvPrecedesClaudeVars(t *testing.T) {
	f := newNotifierFixture(t)
	reg := withHarness(t, f.addRegistration("codex", "codex-env", "interactive", false, time.Now(), 1), "codex")
	f.addChannel(&reg)
	reg.ChannelVerified = true
	reg.SocketPath = ""
	if err := writeAtomicJSON(filepath.Join(f.runtime, "sessions", reg.InstanceID+".json"), reg, 0600); err != nil {
		t.Fatal(err)
	}
	f.writeLease("codex", &reg, "owned", 1)
	// The caller is not a descendant of the registered pid in the fixture's
	// sense only when ancestry is broken; here the ownership test must come
	// from the session id alone, so pass a foreign caller pid.
	t.Setenv("CLAUDE_CODE_SESSION_ID", "some-claude-session")
	t.Setenv("KHALA_CLAUDE_SESSION_ID", "")
	t.Setenv("KHALA_HARNESS_SESSION_ID", reg.ClaudeSessionID)
	if err := runtimeWatchReady([]string{"--identity", "codex", "--caller-pid", "1"}); err != nil {
		t.Fatalf("KHALA_HARNESS_SESSION_ID did not identify the Codex session: %v", err)
	}
	t.Setenv("KHALA_HARNESS_SESSION_ID", "")
	if err := runtimeWatchReady([]string{"--identity", "codex", "--caller-pid", "1"}); err == nil {
		t.Fatal("a foreign Claude session id passed ownership")
	}
}
