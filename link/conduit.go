package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/fsnotify/fsnotify"
)

const conduitAdapterVersion = "1"

type deliveryJournal struct {
	BootID       string   `json:"bootId"`
	Identity     string   `json:"identity"`
	InstanceID   string   `json:"instanceId"`
	Generation   string   `json:"generation"`
	AttemptID    string   `json:"attemptId"`
	AttemptIndex int      `json:"attemptIndex"`
	AttemptedAt  string   `json:"attemptedAt"`
	LetterIDs    []string `json:"letterIds"`
	Status       string   `json:"status"`
	PeerStatus   string   `json:"peerStatus"`
	CCVersion    string   `json:"ccVersion"`
	Error        string   `json:"error,omitempty"`
}

type deliveryJournalAt struct {
	journal deliveryJournal
	at      time.Time
}

type conduitState struct {
	generation   string
	attemptIndex int
	lastAttempt  time.Time
	nextAttempt  time.Time
	failures     int
}

type pendingLetter struct {
	id      string
	from    string
	subject string
}

type conduit struct {
	home       string
	runtime    string
	bootID     string
	self       string
	logger     *log.Logger
	scanEvery  time.Duration
	backoff    []time.Duration
	degradeAt  int
	statesMu   sync.Mutex
	states     map[string]*conduitState
	watcher    *fsnotify.Watcher
	watchedDir map[string]struct{}
}

func runConduit(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "khala-conduit: conduit takes no arguments")
		return 1
	}
	home, err := khalaHome()
	if err != nil {
		return conduitFatalf("%v", err)
	}
	cfg, err := loadConfig(home)
	if err != nil {
		return conduitFatalf("%v", err)
	}
	runtimePath, err := runtimeRoot()
	if err != nil {
		return conduitFatalf("%v", err)
	}
	bootID, err := currentBootID()
	if err != nil {
		return conduitFatalf("%v", err)
	}
	lock, acquired, err := acquireConduitSingleton(runtimePath, bootID)
	if err != nil {
		return conduitFatalf("singleton: %v", err)
	}
	if !acquired {
		return 0
	}
	defer lock.Close()
	logger, err := newConduitLogger(home)
	if err != nil {
		return conduitFatalf("open log/conduit.log: %v", err)
	}
	pidStart, err := processStart(os.Getpid(), bootID)
	if err != nil {
		return conduitFatalf("read own process start: %v", err)
	}
	status := struct {
		BootID    string `json:"bootId"`
		PID       int    `json:"pid"`
		PIDStart  string `json:"pidStart"`
		Adapter   string `json:"adapter"`
		StartedAt string `json:"startedAt"`
	}{bootID, os.Getpid(), pidStart, conduitAdapterVersion, time.Now().UTC().Format(time.RFC3339Nano)}
	if err := writeAtomicJSON(filepath.Join(runtimePath, "conduit.status.json"), status, 0600); err != nil {
		return conduitFatalf("write conduit status: %v", err)
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return conduitFatalf("create watcher: %v", err)
	}
	defer watcher.Close()
	c := &conduit{
		home: home, runtime: runtimePath, bootID: bootID, self: cfg.self, logger: logger,
		scanEvery: durationEnv("KHALA_CONDUIT_TEST_SCAN_INTERVAL", time.Second),
		backoff:   conduitBackoff(), degradeAt: 3, states: make(map[string]*conduitState),
		watcher: watcher, watchedDir: make(map[string]struct{}),
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	logger.Printf("started pid=%d runtime=%s", os.Getpid(), runtimePath)
	if err := c.run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		logger.Printf("stopped with error: %v", err)
		return conduitFatalf("%v", err)
	}
	logger.Printf("stopped")
	return 0
}

func conduitFatalf(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "khala-conduit: "+format+"\n", args...)
	return 1
}

func acquireConduitSingleton(root, bootID string) (*os.File, bool, error) {
	path := filepath.Join(root, "conduit.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	// A locked inode cannot be atomically replaced without moving the lock to
	// an unlinked inode. The adjacent conduit.status.json is the atomic status
	// record; this stable lock inode carries only the boot discriminator.
	if err := f.Truncate(0); err != nil {
		f.Close()
		return nil, false, err
	}
	if _, err := fmt.Fprintf(f, "{\"bootId\":%q}\n", bootID); err != nil {
		f.Close()
		return nil, false, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, false, err
	}
	return f, true, nil
}

func newConduitLogger(home string) (*log.Logger, error) {
	dir := filepath.Join(home, "log")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	return log.New(&rotatingLog{path: filepath.Join(dir, "conduit.log")},
		"khala-conduit: ", log.LstdFlags|log.Lmicroseconds), nil
}

// conduitRewrittenAfter is how long a generation whose doorbell was already
// written waits before it may be rung again. A written frame is queued in the
// session's Claude Code inbox and is read at the head of its next turn, so
// re-ringing on the fast failure backoff only stacks duplicates behind a long
// turn (measured 2026-08-16: 6 attempts / 4 visible duplicates in a 23-second
// turn). Invariant 5: at most one outstanding wake per session — a written
// doorbell IS the outstanding wake until the generation changes.
func conduitRewrittenAfter() time.Duration {
	if value := os.Getenv("KHALA_CONDUIT_TEST_REWRITE_AFTER"); value != "" {
		if d, err := time.ParseDuration(value); err == nil && d > 0 {
			return d
		}
	}
	return 10 * time.Minute
}

func conduitBackoff() []time.Duration {
	defaults := []time.Duration{100 * time.Millisecond, 300 * time.Millisecond, time.Second, 3 * time.Second, 10 * time.Second, 30 * time.Second}
	value := os.Getenv("KHALA_CONDUIT_TEST_BACKOFF")
	if value == "" {
		return defaults
	}
	parts := strings.Split(value, ",")
	parsed := make([]time.Duration, 0, len(parts))
	for _, part := range parts {
		duration, err := time.ParseDuration(strings.TrimSpace(part))
		if err != nil || duration <= 0 {
			return defaults
		}
		parsed = append(parsed, duration)
	}
	if len(parsed) == 1 {
		for len(parsed) < len(defaults) {
			parsed = append(parsed, parsed[0])
		}
	}
	return parsed
}

func (c *conduit) run(ctx context.Context) error {
	if err := c.refreshWatches(); err != nil {
		return err
	}
	c.scan()
	ticker := time.NewTicker(c.scanEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			c.scan()
		case err, ok := <-c.watcher.Errors:
			if !ok {
				return nil
			}
			c.logger.Printf("fsnotify error; full rescan: %v", err)
			c.scan()
		case _, ok := <-c.watcher.Events:
			if !ok {
				return nil
			}
			c.scan()
		}
	}
}

func (c *conduit) refreshWatches() error {
	paths := []string{filepath.Join(c.home, "inbox"), filepath.Join(c.runtime, "sessions"), filepath.Join(c.runtime, "identities")}
	if err := os.MkdirAll(paths[0], 0700); err != nil {
		return err
	}
	entries, _ := os.ReadDir(paths[0])
	for _, entry := range entries {
		if entry.IsDir() && validNode(entry.Name()) {
			newDir := filepath.Join(paths[0], entry.Name(), "new")
			if info, err := os.Lstat(newDir); err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
				paths = append(paths, newDir)
			}
		}
	}
	for _, path := range paths {
		if _, watched := c.watchedDir[path]; watched {
			continue
		}
		if err := c.watcher.Add(path); err != nil {
			return fmt.Errorf("watch %s: %w", path, err)
		}
		c.watchedDir[path] = struct{}{}
	}
	return nil
}

func (c *conduit) scan() {
	if err := c.refreshWatches(); err != nil {
		c.logger.Printf("refresh watches failed: %v", err)
	}
	regs, err := loadRegistrations(c.runtime, c.bootID)
	if err != nil {
		c.logger.Printf("load registrations failed: %v", err)
		return
	}
	registries, err := loadClaudeRegistries()
	if err != nil {
		c.logger.Printf("load Claude registry failed: %v", err)
		return
	}
	for instance, reg := range regs {
		resolved, verified, reason := c.verifyRegistration(reg, registries)
		if resolved != reg {
			var committed sessionRegistration
			err := withRegistrationLock(c.runtime, c.bootID, func() error {
				path := filepath.Join(c.runtime, "sessions", instance+".json")
				var latest sessionRegistration
				if err := readJSON(path, &latest); err != nil {
					return err
				}
				committed, verified, reason = c.verifyRegistration(latest, registries)
				if committed == latest {
					return nil
				}
				return writeAtomicJSON(path, committed, 0600)
			})
			if err != nil {
				c.logger.Printf("update registration %s failed: %v", instance, err)
			} else {
				regs[instance] = committed
			}
		}
		if !verified && reason != "" {
			c.logger.Printf("registration %s not verified: %s", instance, reason)
		}
	}
	leaseEntries, err := os.ReadDir(filepath.Join(c.runtime, "identities"))
	if err != nil {
		c.logger.Printf("load leases failed: %v", err)
		return
	}
	for _, entry := range leaseEntries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".lease") {
			continue
		}
		identity := strings.TrimSuffix(entry.Name(), ".lease")
		if !validNode(identity) {
			continue
		}
		letters := c.pending(identity)
		if len(letters) == 0 {
			c.statesMu.Lock()
			delete(c.states, identity)
			c.statesMu.Unlock()
			continue
		}
		var lease identityLease
		if readJSON(filepath.Join(c.runtime, "identities", entry.Name()), &lease) != nil ||
			lease.BootID != c.bootID || lease.Identity != identity || lease.State != "owned" ||
			!validInstanceID(lease.InstanceID) {
			continue
		}
		reg, ok := regs[lease.InstanceID]
		if !ok || reg.Identity != identity {
			continue
		}
		c.maybeRing(identity, lease, reg, letters)
	}
}

func (c *conduit) verifyRegistration(reg sessionRegistration, registries []claudeRegistry) (sessionRegistration, bool, string) {
	resolved := reg
	if registry, ok := matchingRegistry(resolved, registries); ok {
		resolved.PID = registry.PID
		resolved.SocketPath = registry.Socket
		resolved.CCVersion = firstNonempty(resolved.CCVersion, registry.Version)
		if start, err := processStart(resolved.PID, c.bootID); err == nil {
			resolved.PIDStart = start
		}
	}
	verified := true
	reason := ""
	switch {
	case resolved.BootID != c.bootID:
		verified, reason = false, "boot id mismatch"
	case resolved.Phase != "ready":
		verified, reason = false, "phase is not ready"
	case resolved.Kind != "interactive" && !resolved.ReceiveOptIn:
		verified, reason = false, "non-interactive registration lacks opt-in"
	case resolved.PID <= 1 || !processAliveWithStart(resolved.PID, resolved.PIDStart, c.bootID):
		verified, reason = false, "pid/start mismatch"
	case resolved.ClaudeSessionID == "":
		verified, reason = false, "Claude session id is empty"
	case resolved.SocketPath == "":
		verified, reason = false, "socket is not bound"
	default:
		info, err := os.Lstat(resolved.SocketPath)
		if err != nil || info.Mode()&os.ModeSocket == 0 {
			verified, reason = false, "socket is missing or not a Unix socket"
		} else if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
			verified, reason = false, "socket uid mismatch"
		} else {
			registry, ok := matchingRegistry(resolved, registries)
			if !ok || registry.PID != resolved.PID || registry.Socket != resolved.SocketPath {
				verified, reason = false, "Claude registry pid/socket mismatch"
			} else if registry.SessionID != "" && registry.SessionID != resolved.ClaudeSessionID {
				verified, reason = false, "Claude registry session id mismatch"
			}
			// # AMBIGUOUS: measured CC registry fields do not guarantee a session-id
			// field. When absent, the exact registry socket+pid and the immutable
			// hook-supplied claudeSessionId are the only literal association available.
		}
	}
	if resolved.ConduitVerified != verified {
		resolved.ConduitVerified = verified
		if verified {
			resolved.VerifiedAt = time.Now().UTC().Format(time.RFC3339Nano)
		} else {
			resolved.VerifiedAt = ""
		}
	}
	return resolved, verified, reason
}

func (c *conduit) pending(identity string) []pendingLetter {
	dir := filepath.Join(c.home, "inbox", identity, "new")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	letters := make([]pendingLetter, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !validBasename(entry.Name()) {
			continue
		}
		letter := pendingLetter{id: entry.Name()}
		f, err := os.Open(filepath.Join(dir, entry.Name()))
		if err == nil {
			scanner := bufio.NewScanner(io.LimitReader(f, 64<<10))
			for scanner.Scan() {
				line := scanner.Text()
				if line == "" {
					break
				}
				if strings.HasPrefix(line, "From: ") {
					letter.from = sanitizePreview(strings.TrimPrefix(line, "From: "), 128)
				}
				if strings.HasPrefix(line, "Subject: ") {
					letter.subject = sanitizePreview(strings.TrimPrefix(line, "Subject: "), 256)
				}
			}
			_ = f.Close()
		}
		letters = append(letters, letter)
	}
	sort.Slice(letters, func(i, j int) bool { return letters[i].id < letters[j].id })
	return letters
}

func sanitizePreview(value string, limit int) string {
	if !utf8.ValidString(value) {
		value = strings.ToValidUTF8(value, "�")
	}
	value = strings.ReplaceAll(value, "&", "&amp;")
	value = strings.ReplaceAll(value, "<", "&lt;")
	value = strings.ReplaceAll(value, ">", "&gt;")
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	if len(value) > limit {
		value = value[:limit]
		for !utf8.ValidString(value) {
			value = value[:len(value)-1]
		}
		value += "…"
	}
	return value
}

func letterGeneration(letters []pendingLetter) string {
	hash := sha256.New()
	for _, letter := range letters {
		_, _ = io.WriteString(hash, letter.id)
		_, _ = hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func (c *conduit) maybeRing(identity string, lease identityLease, reg sessionRegistration, letters []pendingLetter) {
	now := time.Now()
	generation := letterGeneration(letters)
	c.statesMu.Lock()
	state := c.states[identity]
	if state == nil {
		state = c.restoreState(identity, reg.InstanceID, generation)
		c.states[identity] = state
	}
	if state.generation != generation {
		state.generation = generation
		state.attemptIndex = 0
		if state.lastAttempt.IsZero() || now.Sub(state.lastAttempt) >= c.backoff[0] {
			state.nextAttempt = now
		} else {
			state.nextAttempt = state.lastAttempt.Add(c.backoff[0])
		}
	}
	if now.Before(state.nextAttempt) {
		c.statesMu.Unlock()
		return
	}
	state.attemptIndex++
	attemptIndex := state.attemptIndex
	c.statesMu.Unlock()

	attemptID, err := newUUID()
	if err != nil {
		c.logger.Printf("create attempt id failed: %v", err)
		return
	}
	journal := deliveryJournal{
		BootID: c.bootID, Identity: identity, InstanceID: reg.InstanceID,
		Generation: generation, AttemptID: attemptID, AttemptIndex: attemptIndex,
		AttemptedAt: now.UTC().Format(time.RFC3339Nano), PeerStatus: "unknown", CCVersion: reg.CCVersion,
	}
	for _, letter := range letters {
		journal.LetterIDs = append(journal.LetterIDs, letter.id)
	}
	verified := reg.ConduitVerified && reg.Phase == "ready" && lease.InstanceID == reg.InstanceID &&
		lease.Epoch > 0 && lease.Epoch == reg.LeaseEpoch && lease.PID == reg.PID &&
		lease.PIDStart == reg.PIDStart && lease.ClaudeSessionID == reg.ClaudeSessionID
	var deliveryErr error
	if !verified {
		journal.Status = "failed"
		journal.Error = "registration is not ready and conduit-verified"
		deliveryErr = errors.New(journal.Error)
	} else {
		frame := c.frame(identity, generation, attemptID, letters)
		deliveryErr = writeDoorbell(reg.SocketPath, frame)
		if deliveryErr != nil {
			journal.Status = "failed"
			journal.Error = deliveryErr.Error()
		} else {
			journal.Status = "written"
		}
	}
	journalDir := filepath.Join(c.runtime, "deliveries", identity, reg.InstanceID)
	journalErr := secureDirectory(filepath.Join(c.runtime, "deliveries", identity))
	if journalErr == nil {
		journalErr = secureDirectory(journalDir)
	}
	if journalErr == nil {
		journalErr = writeAtomicJSON(filepath.Join(journalDir, attemptID+".json"), journal, 0600)
	}
	if journalErr != nil {
		c.logger.Printf("journal attempt %s failed: %v", attemptID, journalErr)
	}

	c.statesMu.Lock()
	state.lastAttempt = now
	if journal.Status == "written" {
		// The doorbell is queued in the session; it is the one outstanding
		// wake for this generation. Re-ring only much later (missed/dropped).
		state.nextAttempt = now.Add(conduitRewrittenAfter())
		state.failures = 0
	} else {
		delayIndex := attemptIndex - 1
		if delayIndex >= len(c.backoff) {
			delayIndex = len(c.backoff) - 1
		}
		state.nextAttempt = now.Add(c.backoff[delayIndex])
		state.failures++
	}
	failures := state.failures
	c.statesMu.Unlock()
	c.updateNativeStatus(reg, failures)
}

func (c *conduit) restoreState(identity, instance, generation string) *conduitState {
	state := &conduitState{generation: generation, nextAttempt: time.Now()}
	dir := filepath.Join(c.runtime, "deliveries", identity, instance)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return state
	}
	var journals []deliveryJournalAt
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		var journal deliveryJournal
		if readJSON(filepath.Join(dir, entry.Name()), &journal) != nil || journal.BootID != c.bootID {
			continue
		}
		attempted, err := time.Parse(time.RFC3339Nano, journal.AttemptedAt)
		if err == nil {
			journals = append(journals, deliveryJournalAt{journal: journal, at: attempted})
		}
	}
	if len(journals) == 0 {
		return state
	}
	sort.Slice(journals, func(i, j int) bool { return journals[i].at.Before(journals[j].at) })
	var latest deliveryJournalAt
	for _, item := range journals {
		if item.journal.Status == "failed" {
			state.failures++
		} else if item.journal.Status == "written" {
			state.failures = 0
		}
		if item.journal.Generation == generation {
			latest = item
		}
	}
	if latest.at.IsZero() {
		return state
	}
	state.attemptIndex = latest.journal.AttemptIndex
	state.lastAttempt = latest.at
	if latest.journal.Status == "written" {
		state.nextAttempt = latest.at.Add(conduitRewrittenAfter())
		return state
	}
	index := state.attemptIndex - 1
	if index < 0 {
		index = 0
	}
	if index >= len(c.backoff) {
		index = len(c.backoff) - 1
	}
	state.nextAttempt = latest.at.Add(c.backoff[index])
	return state
}

func (c *conduit) updateNativeStatus(reg sessionRegistration, failures int) {
	status := ""
	if failures >= c.degradeAt {
		status = "native-degraded"
	}
	if reg.NativeStatus == status && reg.NativeFailureCount == failures {
		return
	}
	if err := mutateRegistration(c.runtime, c.bootID, reg.InstanceID, func(current *sessionRegistration) error {
		if current.NativeStatus != status {
			current.NativeWarningShown = false
		}
		current.NativeStatus = status
		current.NativeFailureCount = failures
		return nil
	}); err != nil {
		c.logger.Printf("update native status %s failed: %v", reg.InstanceID, err)
	}
}

func (c *conduit) frame(identity, generation, attempt string, letters []pendingLetter) map[string]any {
	fromSet := make(map[string]struct{})
	var from []string
	var subjects []string
	for _, letter := range letters {
		if letter.from != "" {
			if _, seen := fromSet[letter.from]; !seen && len(from) < 8 {
				fromSet[letter.from] = struct{}{}
				from = append(from, letter.from)
			}
		}
		if letter.subject != "" && len(subjects) < 8 {
			subjects = append(subjects, letter.subject)
		}
	}
	streamPending := c.pendingStreams(identity)
	content := fmt.Sprintf("KHALA-CONDUIT/1\nrecipient: %s@%s\npending: %d\nstreams: %d\nfrom: %s\nsubjects: %s\ngeneration: %s\nattempt: %s\nread: khala inbox --drain",
		identity, c.self, len(letters), streamPending, strings.Join(from, ", "), strings.Join(subjects, "; "), generation, attempt)
	if len(content) > 8192 {
		content = content[:8192]
		for !utf8.ValidString(content) {
			content = content[:len(content)-1]
		}
	}
	return map[string]any{
		"type":    "user",
		"message": map[string]string{"role": "user", "content": content},
		"from":    "khala:conduit@" + c.self, "priority": "later", "msg_id": generation + ":" + attempt,
	}
}

func (c *conduit) pendingStreams(identity string) int {
	joinDir := filepath.Join(c.home, "join", identity)
	joins, err := os.ReadDir(joinDir)
	if err != nil {
		return 0
	}
	total := 0
	for _, join := range joins {
		if join.IsDir() || !validNode(join.Name()) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(joinDir, join.Name()))
		if err != nil {
			continue
		}
		fields := strings.Fields(string(data))
		if len(fields) != 2 || (fields[0] != "joined" && fields[0] != "quiet") {
			continue
		}
		joinEpoch, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || joinEpoch < 0 {
			continue
		}
		cursor := ""
		if cursorData, err := os.ReadFile(filepath.Join(c.home, "cursor", identity, join.Name())); err == nil {
			cursor = strings.TrimSpace(string(cursorData))
		}
		shards, err := os.ReadDir(filepath.Join(c.home, "streams", join.Name()))
		if err != nil {
			continue
		}
		for _, shard := range shards {
			if !shard.IsDir() || !validNode(shard.Name()) {
				continue
			}
			entries, err := os.ReadDir(filepath.Join(c.home, "streams", join.Name(), shard.Name()))
			if err != nil {
				continue
			}
			for _, entry := range entries {
				id := entry.Name()
				if !entry.Type().IsRegular() || !validMessageID(id) {
					continue
				}
				epochText := strings.SplitN(id, ".", 2)[0]
				epoch, err := strconv.ParseInt(epochText, 10, 64)
				if err != nil || epoch < joinEpoch {
					continue
				}
				if cursor != "" && compareMessageIDs(id, cursor) <= 0 {
					continue
				}
				total++
			}
		}
	}
	return total
}

func compareMessageIDs(left, right string) int {
	leftEpoch, _ := strconv.ParseUint(strings.SplitN(left, ".", 2)[0], 10, 64)
	rightEpoch, _ := strconv.ParseUint(strings.SplitN(right, ".", 2)[0], 10, 64)
	if leftEpoch < rightEpoch {
		return -1
	}
	if leftEpoch > rightEpoch {
		return 1
	}
	return strings.Compare(left, right)
}

func writeDoorbell(socketPath string, frame map[string]any) error {
	connection, err := net.DialTimeout("unix", socketPath, 250*time.Millisecond)
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := connection.SetWriteDeadline(time.Now().Add(250 * time.Millisecond)); err != nil {
		return err
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	for len(data) > 0 {
		written, err := connection.Write(data)
		if err != nil {
			return err
		}
		data = data[written:]
	}
	return nil
}
