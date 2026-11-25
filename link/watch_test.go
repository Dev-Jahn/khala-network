package main

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

func TestAgeGovernedFullScanRequiresSuccessfulReconcile(t *testing.T) {
	home := testKhalaHome(t)
	for _, dir := range []string{"outbox/new", "streams/commons/alpha", "minds/alpha/worker"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "spool", "for", "beta", "mail.sender@alpha"), []byte("mail"), 0600); err != nil {
		t.Fatal(err)
	}
	streamName := "1.2.3.speaker@alpha"
	if err := os.WriteFile(filepath.Join(home, "streams", "commons", "alpha", streamName), []byte("stream"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "presence", "speaker@alpha"), []byte("1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "minds", "alpha", "worker", "1.0"), []byte("mind"), 0600); err != nil {
		t.Fatal(err)
	}
	failing := filepath.Join(home, "fail-brain")
	if err := os.WriteFile(failing, []byte("#!/bin/sh\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	succeeding := filepath.Join(home, "ok-brain")
	if err := os.WriteFile(succeeding, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}

	out := make(chan candidate, 16)
	b := newCoreCLI(failing, home, log.New(io.Discard, "", 0))
	watcher := newTreeWatcher(home, "dial", "alpha", "beta", log.New(io.Discard, "", 0), b, newOriginSet(), out, time.Second)
	w, err := fsnotify.NewWatcher()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	watcher.w = w
	if err := watcher.register(); err != nil {
		t.Fatal(err)
	}
	watcher.scanAll()
	assertCandidateClasses(t, out, map[string]int{"spool": 2})

	b.path = succeeding
	watcher.scanAll()
	assertCandidateClasses(t, out, map[string]int{"spool": 1, "presence": 1, "stream": 1, "mind": 1})
}

func TestMindEligibleViewDialOwnShardAndServeAllOtherShards(t *testing.T) {
	home := testKhalaHome(t)
	for _, node := range []string{"alpha", "beta", "b200"} {
		dir := filepath.Join(home, "minds", node, "worker")
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "1.0"), []byte(node), 0600); err != nil {
			t.Fatal(err)
		}
	}
	coreCLI := newCoreCLI("/bin/true", home, log.New(io.Discard, "", 0))
	for _, tc := range []struct {
		role string
		self string
		peer string
		want map[string]bool
	}{
		{role: "dial", self: "alpha", peer: "b200", want: map[string]bool{"alpha": true}},
		{role: "serve", self: "b200", peer: "beta", want: map[string]bool{"alpha": true, "b200": true}},
	} {
		out := make(chan candidate, 16)
		watcher := newTreeWatcher(home, tc.role, tc.self, tc.peer, log.New(io.Discard, "", 0), coreCLI, newOriginSet(), out, time.Second)
		fsWatcher, err := fsnotify.NewWatcher()
		if err != nil {
			t.Fatal(err)
		}
		watcher.w = fsWatcher
		watcher.scanStatuses()
		if err := fsWatcher.Close(); err != nil {
			t.Fatal(err)
		}
		got := make(map[string]bool)
		for {
			select {
			case candidate := <-out:
				got[candidate.node] = true
			default:
				if len(got) != len(tc.want) {
					t.Fatalf("%s mind nodes=%v want %v", tc.role, got, tc.want)
				}
				for node := range tc.want {
					if !got[node] {
						t.Fatalf("%s mind nodes=%v want %v", tc.role, got, tc.want)
					}
				}
				goto next
			}
		}
	next:
	}
}

func TestMindWatchReregistersSessionAfterGenerationGC(t *testing.T) {
	home := testKhalaHome(t)
	sessionDir := filepath.Join(home, "minds", "alpha", "worker")
	if err := os.MkdirAll(sessionDir, 0700); err != nil {
		t.Fatal(err)
	}
	watcher := newTreeWatcher(home, "dial", "alpha", "b200", log.New(io.Discard, "", 0),
		newCoreCLI("/bin/true", home, log.New(io.Discard, "", 0)), newOriginSet(), make(chan candidate, 4), time.Second)
	fsWatcher, err := fsnotify.NewWatcher()
	if err != nil {
		t.Fatal(err)
	}
	defer fsWatcher.Close()
	watcher.w = fsWatcher
	if err := watcher.addStatusWatch(sessionDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(sessionDir); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for watchListContains(fsWatcher.WatchList(), sessionDir) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if watchListContains(fsWatcher.WatchList(), sessionDir) {
		t.Fatal("fsnotify kept the removed mind session watch")
	}
	if err := os.MkdirAll(sessionDir, 0700); err != nil {
		t.Fatal(err)
	}
	watcher.refreshStatusWatches()
	if err := watcher.addStatusWatch(sessionDir); err != nil {
		t.Fatal(err)
	}
	if !watchListContains(fsWatcher.WatchList(), sessionDir) {
		t.Fatal("recreated mind session was not watched")
	}
}

func watchListContains(paths []string, want string) bool {
	for _, path := range paths {
		if path == want {
			return true
		}
	}
	return false
}

func assertCandidateClasses(t *testing.T, candidates <-chan candidate, want map[string]int) {
	t.Helper()
	got := make(map[string]int)
	for {
		select {
		case candidate := <-candidates:
			got[candidate.class]++
		default:
			for class, count := range want {
				if got[class] != count {
					t.Fatalf("candidate counts=%v want %v", got, want)
				}
			}
			if len(got) != len(want) {
				t.Fatalf("candidate counts=%v want %v", got, want)
			}
			return
		}
	}
}

// The event path skips the gate reconcile only while the core CLI's own
// retention_due would also say "not due"; any disagreement in the other
// direction would let an aged presence file be offered.
func TestRetentionSweepDueMirrorsCoreCLI(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	cases := []struct {
		name   string
		config string
		stamp  int64 // age in seconds; negative = in the future
		absent bool
		want   bool
	}{
		{name: "default interval, fresh stamp", config: "self a\n", stamp: 299, want: false},
		{name: "default interval, stamp at the interval", config: "self a\n", stamp: 300, want: true},
		{name: "missing stamp", config: "self a\n", absent: true, want: true},
		{name: "stamp from the future", config: "self a\n", stamp: -5, want: true},
		{name: "interval zero sweeps every pass", config: "retention-interval 0\n", stamp: 0, want: true},
		{name: "configured interval, fresh", config: "retention-interval 0060\n", stamp: 59, want: false},
		{name: "configured interval, due", config: "retention-interval 60\n", stamp: 60, want: true},
		{name: "empty value means the default", config: "retention-interval \n", stamp: 100, want: false},
		{name: "non-numeric interval", config: "retention-interval 5m\n", stamp: 1, want: true},
		{name: "repeated key", config: "retention-interval 60\nretention-interval 60\n", stamp: 1, want: true},
		{name: "more than 18 digits", config: "retention-interval 1000000000000000000\n", stamp: 1, want: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			if err := os.WriteFile(filepath.Join(home, "config"), []byte(tc.config), 0600); err != nil {
				t.Fatal(err)
			}
			if !tc.absent {
				if err := os.Mkdir(filepath.Join(home, "run"), 0700); err != nil {
					t.Fatal(err)
				}
				stamp := filepath.Join(home, "run", "retention.stamp")
				if err := os.WriteFile(stamp, nil, 0600); err != nil {
					t.Fatal(err)
				}
				at := now.Add(-time.Duration(tc.stamp) * time.Second)
				if err := os.Chtimes(stamp, at, at); err != nil {
					t.Fatal(err)
				}
			}
			if got := retentionSweepDue(home, now); got != tc.want {
				t.Fatalf("due=%v, want %v", got, tc.want)
			}
		})
	}
	if !retentionSweepDue(filepath.Join(t.TempDir(), "no-home"), now) {
		t.Fatal("an unreadable config must count as due")
	}
}
