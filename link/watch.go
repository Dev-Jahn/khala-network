package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

type candidate struct {
	class             string
	node              string
	basename          string
	path              string
	deleteAfterStored bool
}

func (c candidate) key() string { return c.class + "\x00" + c.node + "\x00" + c.basename }

type originSet struct {
	mu sync.RWMutex
	m  map[string]string
}

func newOriginSet() *originSet { return &originSet{m: make(map[string]string)} }
func (s *originSet) add(key, id string) {
	s.mu.Lock()
	s.m[key] = id
	s.mu.Unlock()
}
func (s *originSet) has(key, id string) bool {
	s.mu.RLock()
	got, ok := s.m[key]
	s.mu.RUnlock()
	return ok && got == id
}

type treeWatcher struct {
	home         string
	role         string
	self         string
	peer         string
	logger       *log.Logger
	brain        *brain
	origins      *originSet
	out          chan<- candidate
	period       time.Duration
	dropEvents   bool
	overflowOnce bool
	w            *fsnotify.Watcher
	spoolWatches map[string]struct{}
}

func newTreeWatcher(home, role, self, peer string, logger *log.Logger, b *brain, origins *originSet, out chan<- candidate, period time.Duration) *treeWatcher {
	return &treeWatcher{
		home: home, role: role, self: self, peer: peer, logger: logger, brain: b,
		origins: origins, out: out, period: period,
		dropEvents:   os.Getenv("KHALA_LINK_TEST_DROP_EVENTS") == "1",
		overflowOnce: os.Getenv("KHALA_LINK_TEST_OVERFLOW_ON_EVENT") == "1",
		spoolWatches: make(map[string]struct{}),
	}
}

func (t *treeWatcher) run(ctx context.Context) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	t.w = w
	defer w.Close()
	// C4 ordering: every eligible tree is registered before its initial scan.
	if err := t.register(); err != nil {
		return err
	}
	t.scanAll()
	ticker := time.NewTicker(t.period)
	defer ticker.Stop()
	// khala send refreshes its presence lease immediately before reconcile
	// creates spool. Coalesce that hint briefly so a message is not queued
	// behind a lease fsync on filesystems with slow durability barriers.
	presenceTimer := time.NewTimer(time.Hour)
	if !presenceTimer.Stop() {
		<-presenceTimer.C
	}
	defer presenceTimer.Stop()
	var presenceC <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			t.scanAll()
		case <-presenceC:
			presenceC = nil
			t.scanPresence()
		case err, ok := <-w.Errors:
			if !ok {
				return nil
			}
			t.logger.Printf("fsnotify error; full eligible-view rescan: %v", err)
			t.scanAll()
		case event, ok := <-w.Events:
			if !ok {
				return nil
			}
			if t.dropEvents {
				continue
			}
			if t.overflowOnce {
				t.overflowOnce = false
				t.logger.Printf("test overflow hook; full eligible-view rescan")
				t.scanAll()
				continue
			}
			if filepath.Dir(event.Name) == filepath.Join(t.home, "presence") {
				if !presenceTimer.Stop() {
					select {
					case <-presenceTimer.C:
					default:
					}
				}
				presenceTimer.Reset(100 * time.Millisecond)
				presenceC = presenceTimer.C
				continue
			}
			t.handleHint(event.Name)
		}
	}
}

func (t *treeWatcher) register() error {
	presence := filepath.Join(t.home, "presence")
	if err := os.MkdirAll(presence, 0700); err != nil {
		return err
	}
	if err := t.w.Add(presence); err != nil {
		return fmt.Errorf("watch presence: %w", err)
	}
	spoolRoot := filepath.Join(t.home, "spool", "for")
	if err := os.MkdirAll(spoolRoot, 0700); err != nil {
		return err
	}
	if err := t.w.Add(spoolRoot); err != nil {
		return fmt.Errorf("watch spool root: %w", err)
	}
	if t.role == "dial" {
		outbox := filepath.Join(t.home, "outbox", "new")
		if err := os.MkdirAll(outbox, 0700); err != nil {
			return err
		}
		if err := t.w.Add(outbox); err != nil {
			return fmt.Errorf("watch outbox: %w", err)
		}
		entries, err := os.ReadDir(spoolRoot)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if entry.IsDir() && validNode(entry.Name()) && entry.Name() != t.self {
				if err := t.addSpoolWatch(entry.Name()); err != nil {
					return err
				}
			}
		}
	} else {
		if err := os.MkdirAll(filepath.Join(spoolRoot, t.peer), 0700); err != nil {
			return err
		}
		if err := t.addSpoolWatch(t.peer); err != nil {
			return err
		}
	}
	return nil
}

func (t *treeWatcher) addSpoolWatch(node string) error {
	if _, ok := t.spoolWatches[node]; ok {
		return nil
	}
	path := filepath.Join(t.home, "spool", "for", node)
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("spool path is not a directory: %s", path)
	}
	if err := t.w.Add(path); err != nil {
		return err
	}
	t.spoolWatches[node] = struct{}{}
	// Register first, then scan the newly eligible directory.
	t.scanSpool(node)
	return nil
}

func (t *treeWatcher) scanAll() {
	if t.role == "dial" {
		t.scanOutbox()
		root := filepath.Join(t.home, "spool", "for")
		entries, err := os.ReadDir(root)
		if err != nil {
			t.logger.Printf("scan spool root failed: %v", err)
		} else {
			for _, entry := range entries {
				if !entry.IsDir() || !validNode(entry.Name()) || entry.Name() == t.self {
					continue
				}
				if _, ok := t.spoolWatches[entry.Name()]; !ok {
					if err := t.addSpoolWatch(entry.Name()); err != nil {
						t.logger.Printf("watch new spool %s failed: %v", entry.Name(), err)
					}
				}
				t.scanSpool(entry.Name())
			}
		}
	} else {
		t.scanSpool(t.peer)
	}
	t.scanPresence()
}

func (t *treeWatcher) scanOutbox() {
	dir := filepath.Join(t.home, "outbox", "new")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.logger.Printf("scan outbox failed: %v", err)
		return
	}
	for _, entry := range entries {
		if entry.Type().IsRegular() && validBasename(entry.Name()) {
			t.brain.trigger()
			return
		}
	}
}

func (t *treeWatcher) scanSpool(node string) {
	if t.role == "dial" && node == t.self {
		return
	}
	if t.role == "serve" && node != t.peer {
		return
	}
	dir := filepath.Join(t.home, "spool", "for", node)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.logger.Printf("scan spool/%s failed: %v", node, err)
		return
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !validBasename(entry.Name()) {
			continue
		}
		c := candidate{class: "spool", node: node, basename: entry.Name(), path: filepath.Join(dir, entry.Name()), deleteAfterStored: t.role == "serve"}
		t.enqueue(c)
	}
}

func (t *treeWatcher) scanPresence() {
	dir := filepath.Join(t.home, "presence")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.logger.Printf("scan presence failed: %v", err)
		return
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		node, ok := presenceNode(entry.Name())
		if !ok || (t.role == "dial" && node != t.self) {
			continue
		}
		c := candidate{class: "presence", node: node, basename: entry.Name(), path: filepath.Join(dir, entry.Name())}
		t.enqueue(c)
	}
}

func (t *treeWatcher) enqueue(c candidate) {
	select {
	case t.out <- c:
	default:
		t.logger.Printf("offer queue full; periodic scan will retry %s", c.path)
	}
}

func (t *treeWatcher) handleHint(path string) {
	info, err := os.Lstat(path)
	if err != nil {
		return
	}
	spoolRoot := filepath.Join(t.home, "spool", "for")
	if info.IsDir() && filepath.Dir(path) == spoolRoot {
		node := filepath.Base(path)
		if t.role == "dial" && validNode(node) && node != t.self {
			if err := t.addSpoolWatch(node); err != nil {
				t.logger.Printf("watch new spool %s failed: %v", node, err)
			}
		}
		return
	}
	if !info.Mode().IsRegular() || !validBasename(filepath.Base(path)) {
		return
	}
	if filepath.Dir(path) == filepath.Join(t.home, "outbox", "new") && t.role == "dial" {
		t.brain.trigger()
		return
	}
	if filepath.Dir(path) == filepath.Join(t.home, "presence") {
		node, ok := presenceNode(filepath.Base(path))
		if ok && (t.role == "serve" || node == t.self) {
			t.enqueue(candidate{class: "presence", node: node, basename: filepath.Base(path), path: path})
		}
		return
	}
	if strings.HasPrefix(filepath.Dir(path), spoolRoot+string(os.PathSeparator)) {
		node := filepath.Base(filepath.Dir(path))
		if (t.role == "dial" && node != t.self) || (t.role == "serve" && node == t.peer) {
			t.enqueue(candidate{class: "spool", node: node, basename: filepath.Base(path), path: path, deleteAfterStored: t.role == "serve"})
		}
	}
}
