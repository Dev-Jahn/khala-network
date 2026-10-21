package main

import (
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testGrace = 150 * time.Millisecond

func registerForTest(t *testing.T, args ...string) error {
	t.Helper()
	old := os.Stdout
	devnull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = devnull
	defer func() {
		os.Stdout = old
		_ = devnull.Close()
	}()
	return runtimeRegister(args, false)
}

func (f *notifierFixture) writeParent(identity, parent string) {
	f.t.Helper()
	if err := recordParent(f.home, identity, parent); err != nil {
		f.t.Fatal(err)
	}
}

// noticePass is one conduit pass over the parent records, as scan runs it.
func (f *notifierFixture) noticePass(n *notifier) {
	f.t.Helper()
	regs, err := loadRegistrations(f.runtime, f.bootID)
	if err != nil {
		f.t.Fatal(err)
	}
	n.noticeParents(regs)
}

// restartedNotifier is a fresh conduit over the same home: nothing in memory.
func (f *notifierFixture) restartedNotifier() *notifier {
	return &notifier{home: f.home, runtime: f.runtime, bootID: f.bootID, self: "alpha",
		logger: log.New(f.logs, "", 0), parentGrace: testGrace}
}

func spoolNotices(t *testing.T, home, node string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(home, "spool", "for", node))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	var paths []string
	for _, entry := range entries {
		paths = append(paths, filepath.Join(home, "spool", "for", node, entry.Name()))
	}
	return paths
}

func letterFor(identity string) string {
	return "Khala: 0.1\nFrom: ink@alpha\nTo: " + identity + "@alpha\nType: message\nSubject: answer\n\nbody\n"
}

func TestParentRecordIsValidatedWrittenOnceAndKept(t *testing.T) {
	f := newNotifierFixture(t)
	pid := strconv.Itoa(os.Getpid())
	base := []string{"--identity", "lane", "--harness", "codex", "--kind", "worker", "--pid", pid, "--session-id", "thread-1"}
	for _, bad := range []string{"main", "main@", "@alpha", "Main@alpha", "main@alpha@beta", "conduit@alpha", "lane@alpha", ""} {
		if err := registerForTest(t, append(base, "--parent", bad)...); err == nil || !strings.Contains(err.Error(), "invalid parent") {
			t.Errorf("parent %q err=%v", bad, err)
		}
	}
	if regs, _ := loadRegistrations(f.runtime, f.bootID); len(regs) != 0 {
		t.Fatalf("a refused parent still registered: %+v", regs)
	}
	if _, err := os.Stat(parentRecordPath(f.home, "lane")); !os.IsNotExist(err) {
		t.Fatalf("a refused parent was recorded (err=%v)", err)
	}

	t.Setenv("KHALA_PARENT", "main@alpha")
	if err := registerForTest(t, base...); err != nil {
		t.Fatal(err)
	}
	path := parentRecordPath(f.home, "lane")
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "main@alpha\n" {
		t.Fatalf("record=%q err=%v", data, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("record mode=%v err=%v", info.Mode(), err)
	}
	old := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if err := registerForTest(t, base...); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(path); !info.ModTime().Equal(old) {
		t.Fatal("an unchanged parent was rewritten")
	}
	if err := registerForTest(t, append(base, "--parent", "eddy@beta")...); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "eddy@beta\n" {
		t.Fatalf("--parent did not take precedence over KHALA_PARENT: %q", data)
	}
	t.Setenv("KHALA_PARENT", "")
	if err := registerForTest(t, base...); err != nil {
		t.Fatal(err)
	}
	regs, _ := loadRegistrations(f.runtime, f.bootID)
	for _, reg := range regs {
		if err := runtimeRelease([]string{"--identity", "lane", "--instance", reg.InstanceID}); err != nil {
			t.Fatal(err)
		}
	}
	if data, _ := os.ReadFile(path); string(data) != "eddy@beta\n" {
		t.Fatalf("registration without a parent or release changed the record: %q", data)
	}
}

func TestCodexWorkerRegistrationIsNeverRungButKeepsTheIdentityAlive(t *testing.T) {
	f := newNotifierFixture(t)
	f.notifier.parentGrace = time.Millisecond
	t.Setenv("KHALA_RECEIVE", "1")
	pid := strconv.Itoa(os.Getpid())
	args := []string{"--identity", "lane", "--harness", "codex", "--kind", "worker", "--receive-opt-in=false",
		"--pid", pid, "--caller-pid", pid, "--session-id", "thread-1", "--parent", "main@alpha"}
	if err := registerForTest(t, "--identity", "lane", "--harness", "codex", "--kind", "worker", "--receive-opt-in",
		"--pid", pid, "--session-id", "thread-0"); err == nil || !strings.Contains(err.Error(), "cannot opt in") {
		t.Fatalf("explicit opt-in for a Codex worker err=%v", err)
	}
	if err := registerForTest(t, args...); err != nil {
		t.Fatalf("Codex worker without a channel refused: %v", err)
	}
	regs, err := loadRegistrations(f.runtime, f.bootID)
	if err != nil || len(regs) != 1 {
		t.Fatalf("registrations=%+v err=%v", regs, err)
	}
	var reg sessionRegistration
	for _, only := range regs {
		reg = only
	}
	if reg.Harness != "codex" || reg.Kind != "worker" || reg.ReceiveOptIn || reg.SocketPath != "" || reg.ChannelSocket != "" {
		t.Fatalf("worker registration=%+v", reg)
	}
	f.stageMessageData("lane", "1700000000.1.1.ink@alpha", letterFor("lane"))
	for i := 0; i < 3; i++ {
		f.notifier.scan()
		time.Sleep(5 * time.Millisecond)
	}
	var lease identityLease
	if err := readJSON(filepath.Join(f.runtime, "identities", "lane.lease"), &lease); err == nil && lease.State == "owned" {
		t.Fatalf("a Codex worker took the lease: %+v", lease)
	}
	if _, err := os.Stat(filepath.Join(f.runtime, "deliveries", "lane")); !os.IsNotExist(err) {
		t.Fatalf("the notifier attempted a doorbell for a worker (err=%v)", err)
	}
	for _, word := range []string{"doorbell", "native-degraded", "parent notice"} {
		if strings.Contains(f.logs.String(), word) {
			t.Fatalf("log mentions %q: %s", word, f.logs.String())
		}
	}
	if !identityLive(regs, "lane", f.bootID) || len(spoolNotices(t, f.home, "alpha")) != 0 {
		t.Fatal("a live worker registration did not count as alive")
	}
}

func TestParentNoticeWaitsGraceThenOncePerPendingSet(t *testing.T) {
	f := newNotifierFixture(t)
	f.notifier.parentGrace = testGrace
	f.writeParent("lane", "main@alpha")
	f.stageMessageData("lane", "1700000000.1.1.ink@alpha", letterFor("lane"))
	f.stageMessageData("lane", "1700000000.1.2.ink@alpha", letterFor("lane"))
	f.noticePass(f.notifier)
	if got := spoolNotices(t, f.home, "alpha"); len(got) != 0 {
		t.Fatalf("notice before the grace period: %v", got)
	}
	time.Sleep(testGrace + 20*time.Millisecond)
	f.noticePass(f.notifier)
	notices := spoolNotices(t, f.home, "alpha")
	if len(notices) != 1 {
		t.Fatalf("notices after grace=%v", notices)
	}
	data, err := os.ReadFile(notices[0])
	if err != nil {
		t.Fatal(err)
	}
	notice := string(data)
	header, body, _ := strings.Cut(notice, "\n\n")
	id := filepath.Base(notices[0])
	for _, want := range []string{"Khala: 0.1\nId: " + id + "\nFrom: conduit@alpha\nTo: main@alpha\nDate: ",
		"\nType: notice\nUrgency: urgent\nSubject: lane@alpha has 2 unread letters and no live session\nExpires: "} {
		if !strings.Contains(header, want) {
			t.Fatalf("header lacks %q:\n%s", want, notice)
		}
	}
	for _, want := range []string{"lane@alpha has 2 unread letters (oldest ", "khala inbox list --as lane",
		"khala inbox read <Id> --as lane", "khala inbox ack-read --as lane <Id>", "resume the lane"} {
		if !strings.Contains(body, want) {
			t.Fatalf("body lacks %q:\n%s", want, body)
		}
	}
	if !validMessageID(id) || !strings.HasSuffix(id, ".conduit@alpha") {
		t.Fatalf("notice Id %q", id)
	}
	if _, err := os.Stat(filepath.Join(f.home, "run", "reconcile.trigger")); err != nil {
		t.Fatalf("local notice left no reconcile trigger: %v", err)
	}

	// The same set never notices again — in this conduit or a restarted one.
	f.noticePass(f.notifier)
	restarted := f.restartedNotifier()
	f.noticePass(restarted)
	time.Sleep(testGrace + 20*time.Millisecond)
	f.noticePass(restarted)
	f.noticePass(f.notifier)
	if got := spoolNotices(t, f.home, "alpha"); len(got) != 1 {
		t.Fatalf("the same pending set noticed %d times", len(got))
	}
	// The record, not the receiver's Id dedup, is what keeps the restart quiet.
	if got := strings.Count(f.logs.String(), "parent notice lane -> main@alpha"); got != 1 {
		t.Fatalf("parent notices queued=%d want 1; logs=%s", got, f.logs.String())
	}
	record, err := os.ReadFile(parentNoticePath(f.home, "lane"))
	if err != nil || !strings.HasPrefix(string(record), "notice 1 ") ||
		!strings.HasSuffix(string(record), " "+id+" main@alpha\n1700000000.1.1.ink@alpha\n1700000000.1.2.ink@alpha\n") {
		t.Fatalf("record=%q err=%v", record, err)
	}
	// A letter read meanwhile shrinks the set; still nothing new to tell.
	if err := os.Remove(filepath.Join(f.home, "inbox", "lane", "new", "1700000000.1.1.ink@alpha")); err != nil {
		t.Fatal(err)
	}
	f.noticePass(restarted)
	if got := spoolNotices(t, f.home, "alpha"); len(got) != 1 {
		t.Fatalf("a shrinking set noticed again: %d", len(got))
	}
	// A new letter is a new set: one more notice once it has waited the grace.
	f.stageMessageData("lane", "1700000001.1.1.eddy@beta", letterFor("lane"))
	f.noticePass(restarted)
	if got := spoolNotices(t, f.home, "alpha"); len(got) != 1 {
		t.Fatalf("a new letter noticed before its grace: %d", len(got))
	}
	time.Sleep(testGrace + 20*time.Millisecond)
	f.noticePass(restarted)
	f.noticePass(restarted)
	if got := spoolNotices(t, f.home, "alpha"); len(got) != 2 {
		t.Fatalf("a new pending set noticed %d times in total, want 2", len(got))
	}
	if !strings.Contains(f.logs.String(), "parent notice lane -> main@alpha: 2 unread") {
		t.Fatalf("logs=%s", f.logs.String())
	}
}

func TestParentNoticeNeverWhileAliveNorWithoutParent(t *testing.T) {
	f := newNotifierFixture(t)
	f.notifier.parentGrace = time.Millisecond
	reg := f.addRegistration("lane", "lane-claude", "interactive", false, time.Now().Add(-time.Hour), 1)
	f.writeParent("lane", "main@beta")
	f.stageMessageData("lane", "1700000000.1.1.ink@alpha", letterFor("lane"))
	f.stageMessageData("orphan", "1700000000.1.1.ink@alpha", letterFor("orphan"))
	// Notices alone are not letters: a parent notice never cascades upwards.
	f.writeParent("relay", "main@alpha")
	f.stageMessageData("relay", "1700000000.0.1.conduit@alpha", "From: conduit@alpha\nType: notice\nUrgency: urgent\n\nx\n")
	for i := 0; i < 3; i++ {
		f.noticePass(f.notifier)
		time.Sleep(5 * time.Millisecond)
	}
	if got := append(spoolNotices(t, f.home, "beta"), spoolNotices(t, f.home, "alpha")...); len(got) != 0 {
		t.Fatalf("notices while alive, without a parent, or for notices: %v", got)
	}
	// The registered process goes away: the identity is no longer alive.
	reg.PIDStart = "gone"
	writeRegistrationForTest(t, f.runtime, reg)
	f.noticePass(f.notifier)
	time.Sleep(5 * time.Millisecond)
	f.noticePass(f.notifier)
	notices := spoolNotices(t, f.home, "beta")
	if len(notices) != 1 {
		t.Fatalf("remote parent notices=%v", notices)
	}
	if _, err := os.Stat(filepath.Join(f.home, "run", "reconcile.trigger")); !os.IsNotExist(err) {
		t.Fatalf("a remote notice left a local reconcile trigger (err=%v)", err)
	}
	if data, err := os.ReadFile(notices[0]); err != nil || !strings.Contains(string(data), "\nTo: main@beta\n") {
		t.Fatalf("notice=%s err=%v", data, err)
	}
}

func TestClaudeBindRefusedInsideCodex(t *testing.T) {
	f := newNotifierFixture(t)
	t.Setenv("CODEX_THREAD_ID", "019a-thread")
	pid := strconv.Itoa(os.Getpid())
	for _, publicBind := range []bool{false, true} {
		for _, harness := range []string{"", "claude"} {
			args := []string{"--identity", "main", "--pid", pid, "--session-id", "s", "--socket", filepath.Join(f.runtime, "x.sock")}
			if harness != "" {
				args = append(args, "--harness", harness)
			}
			if err := runtimeRegister(args, publicBind); err == nil || err.Error() != "this is a codex session; use khala-codex" {
				t.Errorf("bind=%t harness=%q err=%v", publicBind, harness, err)
			}
		}
	}
	if regs, _ := loadRegistrations(f.runtime, f.bootID); len(regs) != 0 {
		t.Fatalf("refused binds registered: %+v", regs)
	}
	if err := registerForTest(t, "--identity", "lane", "--harness", "codex", "--kind", "worker", "--pid", pid, "--session-id", "019a-thread"); err != nil {
		t.Fatalf("the Codex path was refused too: %v", err)
	}
}

func TestShortAge(t *testing.T) {
	for d, want := range map[time.Duration]string{-time.Second: "0s", 45 * time.Second: "45s", 14 * time.Minute: "14m",
		3 * time.Hour: "3h", 47 * time.Hour: "47h", 72 * time.Hour: "3d"} {
		if got := shortAge(d); got != want {
			t.Errorf("shortAge(%s)=%q want %q", d, got, want)
		}
	}
}
