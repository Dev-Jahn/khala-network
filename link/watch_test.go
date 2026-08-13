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
	for _, dir := range []string{"outbox/new", "streams/commons/alpha"} {
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
	failing := filepath.Join(home, "fail-brain")
	if err := os.WriteFile(failing, []byte("#!/bin/sh\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	succeeding := filepath.Join(home, "ok-brain")
	if err := os.WriteFile(succeeding, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}

	out := make(chan candidate, 16)
	b := newBrain(failing, home, log.New(io.Discard, "", 0))
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
	assertCandidateClasses(t, out, map[string]int{"spool": 1, "presence": 1, "stream": 1})
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
