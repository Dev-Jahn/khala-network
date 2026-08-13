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
	stream            string
	node              string
	basename          string
	path              string
	deleteAfterStored bool
}

func (c candidate) key() string {
	return c.class + "\x00" + c.stream + "\x00" + c.node + "\x00" + c.basename
}

type originSet struct {
	mu sync.RWMutex
	m  map[string]string
}

type logOnceSet struct {
	mu sync.Mutex
	m  map[string]struct{}
}

func newLogOnceSet() *logOnceSet { return &logOnceSet{m: make(map[string]struct{})} }
func (s *logOnceSet) first(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.m[key]; ok {
		return false
	}
	s.m[key] = struct{}{}
	return true
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
	home          string
	role          string
	self          string
	peer          string
	logger        *log.Logger
	brain         *brain
	origins       *originSet
	out           chan<- candidate
	period        time.Duration
	dropEvents    bool
	overflowOnce  bool
	w             *fsnotify.Watcher
	spoolWatches  map[string]struct{}
	streamWatches map[string]struct{}
	presenceWatch bool
	ageReady      bool
}

func newTreeWatcher(home, role, self, peer string, logger *log.Logger, b *brain, origins *originSet, out chan<- candidate, period time.Duration) *treeWatcher {
	return &treeWatcher{
		home: home, role: role, self: self, peer: peer, logger: logger, brain: b,
		origins: origins, out: out, period: period,
		dropEvents:    os.Getenv("KHALA_LINK_TEST_DROP_EVENTS") == "1",
		overflowOnce:  os.Getenv("KHALA_LINK_TEST_OVERFLOW_ON_EVENT") == "1",
		spoolWatches:  make(map[string]struct{}),
		streamWatches: make(map[string]struct{}),
	}
}

func (t *treeWatcher) run(ctx context.Context) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	t.w = w
	defer w.Close()
	// Spool is not age-governed and remains live even if the brain is busy.
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
			if t.ageScanReady() {
				t.scanPresence()
			}
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

func (t *treeWatcher) registerAgeGoverned() error {
	presence := filepath.Join(t.home, "presence")
	if err := os.MkdirAll(presence, 0700); err != nil {
		return err
	}
	if !t.presenceWatch {
		if err := t.w.Add(presence); err != nil {
			return fmt.Errorf("watch presence: %w", err)
		}
		t.presenceWatch = true
	}
	streamsRoot := filepath.Join(t.home, "streams")
	if err := os.MkdirAll(streamsRoot, 0700); err != nil {
		return err
	}
	if err := t.addStreamWatch(streamsRoot); err != nil {
		return fmt.Errorf("watch streams root: %w", err)
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
	t.scanAgeGoverned()
}

func (t *treeWatcher) scanAgeGoverned() {
	if !t.ageScanReady() {
		return
	}
	t.scanPresence()
	t.scanStreams()
}

func (t *treeWatcher) ageScanReady() bool {
	if err := t.brain.reconcile(true); err != nil {
		t.ageReady = false
		t.logger.Printf("age-governed scan skipped; brain reconcile failed: %v", err)
		return false
	}
	// Presence has no filename epoch, so successful reconciliation is its
	// only age gate. Register first, then scan to preserve C4 event coverage.
	if err := t.registerAgeGoverned(); err != nil {
		t.ageReady = false
		t.logger.Printf("age-governed scan skipped; watch registration failed: %v", err)
		return false
	}
	t.ageReady = true
	return true
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

func (t *treeWatcher) addStreamWatch(path string) error {
	if _, ok := t.streamWatches[path]; ok {
		return nil
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("stream path is not a directory: %s", path)
	}
	if err := t.w.Add(path); err != nil {
		return err
	}
	t.streamWatches[path] = struct{}{}
	return nil
}

func (t *treeWatcher) eligibleStreamNode(node string) bool {
	if t.role == "dial" {
		return node == t.self
	}
	return node != t.peer
}

func (t *treeWatcher) scanStreams() {
	root := filepath.Join(t.home, "streams")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.logger.Printf("scan streams root failed: %v", err)
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() || !validNode(entry.Name()) {
			continue
		}
		streamDir := filepath.Join(root, entry.Name())
		if err := t.addStreamWatch(streamDir); err != nil {
			t.logger.Printf("watch stream %s failed: %v", entry.Name(), err)
			continue
		}
		t.scanStream(entry.Name())
	}
}

func (t *treeWatcher) scanStream(stream string) {
	dir := filepath.Join(t.home, "streams", stream)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.logger.Printf("scan stream/%s failed: %v", stream, err)
		return
	}
	for _, entry := range entries {
		node := entry.Name()
		if !entry.IsDir() || !validNode(node) || !t.eligibleStreamNode(node) {
			continue
		}
		shardDir := filepath.Join(dir, node)
		if err := t.addStreamWatch(shardDir); err != nil {
			t.logger.Printf("watch stream shard %s/%s failed: %v", stream, node, err)
			continue
		}
		t.scanStreamShard(stream, node)
	}
}

func (t *treeWatcher) scanStreamShard(stream, node string) {
	dir := filepath.Join(t.home, "streams", stream, node)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.logger.Printf("scan stream shard %s/%s failed: %v", stream, node, err)
		return
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !validMessageID(entry.Name()) {
			continue
		}
		t.enqueue(candidate{
			class: "stream", stream: stream, node: node, basename: entry.Name(),
			path: filepath.Join(dir, entry.Name()),
		})
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
	streamsRoot := filepath.Join(t.home, "streams")
	if info.IsDir() && filepath.Dir(path) == spoolRoot {
		node := filepath.Base(path)
		if t.role == "dial" && validNode(node) && node != t.self {
			if err := t.addSpoolWatch(node); err != nil {
				t.logger.Printf("watch new spool %s failed: %v", node, err)
			}
		}
		return
	}
	if info.IsDir() && filepath.Dir(path) == streamsRoot {
		stream := filepath.Base(path)
		if validNode(stream) && t.ageScanReady() {
			if err := t.addStreamWatch(path); err != nil {
				t.logger.Printf("watch stream %s failed: %v", stream, err)
			} else {
				t.scanStream(stream)
			}
		}
		return
	}
	if info.IsDir() && filepath.Dir(filepath.Dir(path)) == streamsRoot {
		stream := filepath.Base(filepath.Dir(path))
		node := filepath.Base(path)
		if validNode(stream) && validNode(node) && t.eligibleStreamNode(node) && t.ageScanReady() {
			if err := t.addStreamWatch(path); err != nil {
				t.logger.Printf("watch stream shard %s/%s failed: %v", stream, node, err)
			} else {
				t.scanStreamShard(stream, node)
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
	shardDir := filepath.Dir(path)
	streamDir := filepath.Dir(shardDir)
	if filepath.Dir(streamDir) == streamsRoot {
		stream := filepath.Base(streamDir)
		node := filepath.Base(shardDir)
		if t.ageReady && validNode(stream) && validNode(node) && t.eligibleStreamNode(node) && validMessageID(filepath.Base(path)) {
			t.enqueue(candidate{class: "stream", stream: stream, node: node, basename: filepath.Base(path), path: path})
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
