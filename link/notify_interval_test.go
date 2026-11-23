package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// intervalFixture is one ready session "ink" whose notifier passes are driven by
// hand; written notifications are counted from the delivery journal, which the
// notifier writes synchronously.
type intervalFixture struct {
	*notifierFixture
	reg  sessionRegistration
	next int
}

func newIntervalFixture(t *testing.T, interval string) *intervalFixture {
	t.Helper()
	// Far beyond the test's duration: only the interval or a drain can let a
	// second notification through, unless a test moves nextAttempt itself.
	t.Setenv("KHALA_CONDUIT_TEST_REWRITE_AFTER", "1h")
	f := &intervalFixture{notifierFixture: newNotifierFixture(t)}
	f.notifier.backoff = []time.Duration{time.Millisecond}
	if err := os.MkdirAll(filepath.Join(f.runtime, "ears"), 0700); err != nil {
		t.Fatal(err)
	}
	f.reg = f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &f.reg, "owned", 3)
	if interval != "" {
		dir := filepath.Join(f.home, "notify-interval")
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "ink"), []byte(interval), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

// stage installs one unread message with the given extra headers and returns its id.
func (f *intervalFixture) stage(headers string) string {
	f.next++
	id := fmt.Sprintf("1700000000.1.%d.sender@alpha", f.next)
	f.stageMessageData("ink", id, "From: sender@alpha\n"+headers+"Subject: s\n\nbody\n")
	return id
}

// pass is one notifier scan; the 2 ms pause outlasts the 1 ms failure backoff
// that also spaces a new queue digest from the previous attempt.
func (f *intervalFixture) pass(n *notifier) {
	time.Sleep(2 * time.Millisecond)
	n.scan()
}

// drain is what `khala inbox --drain` leaves behind: nothing unread and a
// newer inbox-read marker. The following pass sees the empty inbox.
func (f *intervalFixture) drain(n *notifier) {
	f.t.Helper()
	newDir := filepath.Join(f.home, "inbox", "ink", "new")
	curDir := filepath.Join(f.home, "inbox", "ink", "cur")
	if err := os.MkdirAll(curDir, 0700); err != nil {
		f.t.Fatal(err)
	}
	entries, err := os.ReadDir(newDir)
	if err != nil {
		f.t.Fatal(err)
	}
	for _, entry := range entries {
		if err := os.Rename(filepath.Join(newDir, entry.Name()), filepath.Join(curDir, entry.Name())); err != nil {
			f.t.Fatal(err)
		}
	}
	f.writeInboxReadMarker("ink", time.Now().Unix()+1)
	f.pass(n)
}

// written returns the letter ids of each written notification, oldest first.
func (f *intervalFixture) written() [][]string {
	f.t.Helper()
	dir := filepath.Join(f.runtime, "deliveries", "ink", f.reg.InstanceID)
	entries, err := os.ReadDir(dir)
	if err != nil && !os.IsNotExist(err) {
		f.t.Fatal(err)
	}
	var journals []deliveryJournal
	for _, entry := range entries {
		var journal deliveryJournal
		if err := readJSON(filepath.Join(dir, entry.Name()), &journal); err != nil {
			f.t.Fatal(err)
		}
		if journal.Status == "written" {
			journals = append(journals, journal)
		}
	}
	sort.Slice(journals, func(i, j int) bool { return journals[i].AttemptedAt < journals[j].AttemptedAt })
	ids := make([][]string, 0, len(journals))
	for _, journal := range journals {
		ids = append(ids, journal.LetterIDs)
	}
	return ids
}

func (f *intervalFixture) wantWritten(n int, context string) {
	f.t.Helper()
	if got := f.written(); len(got) != n {
		f.t.Fatalf("%s: %d notifications written, want %d: %v\nlogs: %s", context, len(got), n, got, f.logs.String())
	}
}

// restarted is a fresh conduit over the same home and runtime: nothing in memory.
func (f *intervalFixture) restarted() *notifier {
	old := f.notifier
	return &notifier{
		home: old.home, runtime: old.runtime, bootID: old.bootID, self: old.self, logger: old.logger,
		scanEvery: old.scanEvery, backoff: old.backoff, degradeAt: old.degradeAt,
		states: make(map[string]*notifierState), verificationReasons: make(map[string]string),
		watcher: old.watcher, watchedDir: make(map[string]struct{}),
	}
}

// expire moves the notifier's memory of its last notification to ink back by age.
func expire(t *testing.T, n *notifier, age time.Duration) {
	t.Helper()
	n.statesMu.Lock()
	defer n.statesMu.Unlock()
	state := n.states["ink"]
	if state == nil {
		t.Fatal("no notifier state for ink")
	}
	state.lastWritten = time.Now().Add(-age)
}

// Without a (valid) interval a drained session is rung again by the very next letter.
func TestNotifyIntervalOffRingsEveryLetterAfterDrain(t *testing.T) {
	for name, content := range map[string]string{"unset": "", "below minimum": "59\n", "not a number": "soon\n", "no newline": "60"} {
		t.Run(name, func(t *testing.T) {
			f := newIntervalFixture(t, content)
			f.stage("")
			f.pass(f.notifier)
			f.wantWritten(1, "first letter")
			f.drain(f.notifier)
			f.stage("")
			f.pass(f.notifier)
			f.pass(f.notifier)
			f.wantWritten(2, "letter after drain")
			wantLogs := 1
			if content == "" {
				wantLogs = 0
			}
			if got := strings.Count(f.logs.String(), "malformed notify interval ignored"); got != wantLogs {
				t.Fatalf("malformed interval logged %d times, want %d", got, wantLogs)
			}
		})
	}
}

// Ordinary letters inside the interval write nothing, across a conduit restart
// too; when the interval ends one notification names all of them.
func TestNotifyIntervalCoalescesOrdinaryMailUntilWindowEnd(t *testing.T) {
	f := newIntervalFixture(t, "60\n")
	f.stage("")
	f.pass(f.notifier)
	f.wantWritten(1, "first letter after a quiet period")
	f.drain(f.notifier)

	second := f.stage("")
	f.pass(f.notifier)
	third := f.stage("Priority: later\n")
	f.pass(f.notifier)
	f.wantWritten(1, "ordinary letters inside the interval")

	conduit := f.restarted()
	f.pass(conduit)
	f.pass(conduit)
	f.wantWritten(1, "conduit restart inside the interval")

	expire(t, conduit, 61*time.Second)
	f.pass(conduit)
	f.pass(conduit)
	f.wantWritten(2, "interval end")
	if got := f.written()[1]; len(got) != 2 || got[0] != second || got[1] != third {
		t.Fatalf("interval-end notification names %v, want [%s %s]", got, second, third)
	}
}

// An urgent letter and an urgent notice each pass the interval at once, and only
// once: still unread, they do not pass it again, in memory or after a restart.
func TestNotifyIntervalUrgentBypassesOnce(t *testing.T) {
	// due lets the outstanding-notification schedule allow a re-ring, so that
	// only the interval can be what withholds it.
	due := func(n *notifier) {
		n.statesMu.Lock()
		n.states["ink"].nextAttempt = time.Now().Add(-time.Millisecond)
		n.statesMu.Unlock()
	}
	for name, headers := range map[string]string{
		"letter": "Priority: urgent\n",
		"notice": "Type: notice\nUrgency: urgent\n",
	} {
		t.Run(name, func(t *testing.T) {
			f := newIntervalFixture(t, "60\n")
			f.stage("")
			f.pass(f.notifier)
			f.drain(f.notifier)
			f.stage("")
			f.pass(f.notifier)
			f.wantWritten(1, "ordinary letter inside the interval")

			f.stage(headers)
			f.pass(f.notifier)
			f.wantWritten(2, "urgent arrival inside the interval")

			due(f.notifier)
			f.stage("")
			f.pass(f.notifier)
			f.wantWritten(2, "announced urgent message, still unread")

			conduit := f.restarted()
			f.pass(conduit)
			due(conduit)
			f.pass(conduit)
			f.wantWritten(2, "announced urgent message after a conduit restart")

			// With the interval over, the unread inbox re-rings on the old schedule.
			due(conduit)
			expire(t, conduit, 61*time.Second)
			f.pass(conduit)
			f.wantWritten(3, "re-ring after the interval")
		})
	}
}

func TestUrgentLetterNeverYieldsLaterPriority(t *testing.T) {
	f := newNotifierFixture(t)
	f.stageMessageData("ink", "1.later", "From: a@alpha\nPriority: later\nSubject: wait\n\nbody\n")
	if got := notificationPriority(f.notifier.pending("ink")); got != "later" {
		t.Fatalf("later-only priority=%q want later", got)
	}
	f.stageMessageData("ink", "2.both", "From: a@alpha\nPriority: later\nPriority: urgent\nSubject: now\n\nbody\n")
	if got := notificationPriority(f.notifier.pending("ink")); got != "next" {
		t.Fatalf("priority with an urgent letter=%q want next", got)
	}
}
