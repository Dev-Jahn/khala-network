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

const notifierAdapterVersion = "1"

type deliveryJournal struct {
	BootID       string   `json:"bootId"`
	Identity     string   `json:"identity"`
	InstanceID   string   `json:"instanceId"`
	Generation   string   `json:"generation"`
	AttemptID    string   `json:"attemptId"`
	AttemptIndex int      `json:"attemptIndex"`
	AttemptedAt  string   `json:"attemptedAt"`
	FirstSeen    string   `json:"firstSeen,omitempty"`
	LetterIDs    []string `json:"letterIds"`
	Status       string   `json:"status"`
	PeerStatus   string   `json:"peerStatus"`
	CCVersion    string   `json:"ccVersion"`
	Via          string   `json:"via,omitempty"`
	ChannelError string   `json:"channelError,omitempty"`
	Error        string   `json:"error,omitempty"`
}

type deliveryJournalAt struct {
	journal deliveryJournal
	at      time.Time
}

type notifierState struct {
	pendingDigest            string
	firstSeen                time.Time
	attemptIndex             int
	notificationsSent        int
	outstandingNotifications int
	outstandingWritten       time.Time
	targetInstance           string
	targetPID                int
	targetPIDStart           string
	lastAttempt              time.Time
	lastWritten              time.Time
	nextAttempt              time.Time
	lastInboxReadToken       string
	failures                 int
	echoLogged               bool
}

type pendingMessage struct {
	id          string
	installedAt int64
	// kind is the message Type header value ("" when absent).
	kind    string
	from    string
	subject string
	alert   bool
	urgent  bool
	// later is set when the message headers carry "Priority: later" — the sender
	// asked for the inbox notification to wait until the session is idle.
	later bool
}

// notifierBeforeNotificationWrite is nil in production. Tests use it to change the
// inbox deterministically after a frame is built and before its final re-check.
var notifierBeforeNotificationWrite func(identity string)

type notifier struct {
	home                    string
	runtime                 string
	bootID                  string
	self                    string
	logger                  *log.Logger
	scanEvery               time.Duration
	backoff                 []time.Duration
	degradeAt               int
	statesMu                sync.Mutex
	states                  map[string]*notifierState
	verificationReasons     map[string]string
	listenerMu              sync.Mutex
	listenerInterval        time.Duration
	snapshotSequence        int64
	listenerLastWrite       time.Time
	listenerUpstreams       []string
	inboxReadWarned         map[string]bool
	turnsWarned             map[string]bool
	listenerLastSignature   string
	listenerRegistrationSig string
	listenerSignatureSet    bool
	listenerInstances       map[string]bool
	listenerForceWrite      bool
	listenerSuppressed      bool
	scanComplete            bool
	listenerReady           bool
	watcher                 *fsnotify.Watcher
	watchedDir              map[string]struct{}
	// triage is nil in tests that do not exercise it; nil means off.
	triage *triageEngine
	// Parent notices (parent.go). parentGrace 0 means parentNoticeGrace;
	// the maps are created on first use.
	parentGrace     time.Duration
	parentWaiting   map[string]time.Time
	parentNoticed   map[string]map[string]bool
	parentNoticeErr map[string]string
}

func runNotifier(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "khala-conduit: conduit takes no arguments")
		return 1
	}
	home, err := khalaHome()
	if err != nil {
		return notifierFatalf("%v", err)
	}
	cfg, err := loadConfig(home)
	if err != nil {
		return notifierFatalf("%v", err)
	}
	runtimePath, err := runtimeRoot()
	if err != nil {
		return notifierFatalf("%v", err)
	}
	bootID, err := currentBootID()
	if err != nil {
		return notifierFatalf("%v", err)
	}
	lock, acquired, err := acquireNotifierSingleton(runtimePath, bootID)
	if err != nil {
		return notifierFatalf("singleton: %v", err)
	}
	if !acquired {
		return 0
	}
	defer lock.Close()
	logger, err := newNotifierLogger(home)
	if err != nil {
		return notifierFatalf("open log/conduit.log: %v", err)
	}
	statusPath := filepath.Join(runtimePath, "conduit.status.json")
	var previous notifierStatus
	statusErr := readJSON(statusPath, &previous)
	if statusErr != nil && !os.IsNotExist(statusErr) {
		return notifierFatalf("read notifier status: %v", statusErr)
	}
	if statusErr == nil && previous.PID != os.Getpid() && previous.BootID == bootID &&
		processAliveWithStart(previous.PID, previous.PIDStart, bootID) {
		logger.Printf("another conduit is live (pid=%d); exiting", previous.PID)
		return 0
	}
	pidStart, err := processStart(os.Getpid(), bootID)
	if err != nil {
		return notifierFatalf("read own process start: %v", err)
	}
	status := notifierStatus{
		BootID: bootID, PID: os.Getpid(), PIDStart: pidStart, Runtime: runtimePath,
		Adapter: notifierAdapterVersion, StartedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := writeAtomicJSON(statusPath, status, 0600); err != nil {
		return notifierFatalf("write notifier status: %v", err)
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return notifierFatalf("create watcher: %v", err)
	}
	defer watcher.Close()
	c := &notifier{
		home: home, runtime: runtimePath, bootID: bootID, self: cfg.self, logger: logger,
		scanEvery: durationEnv("KHALA_CONDUIT_TEST_SCAN_INTERVAL", time.Second),
		backoff:   notifierBackoff(), degradeAt: 3, states: make(map[string]*notifierState),
		verificationReasons: make(map[string]string),
		watcher:             watcher, watchedDir: make(map[string]struct{}),
		listenerInterval:  durationEnv("KHALA_CONDUIT_TEST_EAR_INTERVAL", 60*time.Second),
		listenerUpstreams: append([]string(nil), cfg.upstreamNodes...), inboxReadWarned: make(map[string]bool),
		turnsWarned: make(map[string]bool),
		triage:      newTriageEngine(home, logger),
		parentGrace: durationEnv("KHALA_CONDUIT_TEST_PARENT_GRACE", parentNoticeGrace),
	}
	defer c.triage.close()
	if c.listenerInterval < time.Second {
		c.listenerInterval = time.Second
	}
	c.snapshotSequence = readSnapshotSequence(filepath.Join(home, "presence", "conduit@"+cfg.self+".ear"))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	logger.Printf("started pid=%d runtime=%s", os.Getpid(), runtimePath)
	if err := c.run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		logger.Printf("stopped with error: %v", err)
		return notifierFatalf("%v", err)
	}
	logger.Printf("stopped")
	return 0
}

func notifierFatalf(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "khala-conduit: "+format+"\n", args...)
	return 1
}

func acquireNotifierSingleton(root, bootID string) (*os.File, bool, error) {
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

func newNotifierLogger(home string) (*log.Logger, error) {
	dir := filepath.Join(home, "log")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	return log.New(&rotatingLog{path: filepath.Join(dir, "conduit.log")},
		"khala-conduit: ", log.LstdFlags|log.Lmicroseconds), nil
}

// notificationRetryAfter is the bounded backoff schedule for an outstanding inbox notification.
// A successful frame remains the target registration process's one outstanding
// notification until an inbox-read marker proves consumption. A different process starts a
// new backoff schedule; queue digest changes only refresh the next scheduled frame's
// summary. Each unconsumed write advances the backoff schedule, while consumption resets
// it. Invariant 5: message arrival cannot produce frames faster than this schedule
// merely by changing the queue digest.
func notificationRetryAfter(outstandingNotifications int) time.Duration {
	defaults := []time.Duration{10 * time.Minute, 20 * time.Minute, 40 * time.Minute, 80 * time.Minute, 160 * time.Minute, 320 * time.Minute}
	value := os.Getenv("KHALA_CONDUIT_TEST_REWRITE_AFTER")
	if value == "" {
		return defaults[rewriteDelayIndex(outstandingNotifications, len(defaults))]
	}
	parts := strings.Split(value, ",")
	parsed := make([]time.Duration, 0, len(parts))
	for _, part := range parts {
		duration, err := time.ParseDuration(strings.TrimSpace(part))
		if err != nil || duration <= 0 {
			return defaults[rewriteDelayIndex(outstandingNotifications, len(defaults))]
		}
		parsed = append(parsed, duration)
	}
	return parsed[rewriteDelayIndex(outstandingNotifications, len(parsed))]
}

func rewriteDelayIndex(outstandingNotifications, scheduleLength int) int {
	index := outstandingNotifications - 1
	if index < 0 {
		index = 0
	}
	if index >= scheduleLength {
		index = scheduleLength - 1
	}
	return index
}

func notifierBackoff() []time.Duration {
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

func (c *notifier) run(ctx context.Context) error {
	if err := c.refreshWatches(); err != nil {
		return err
	}
	c.scan()
	if c.scanComplete {
		if model, err := c.captureListenerModel("running"); err != nil {
			c.logger.Printf("build initial listener snapshot failed: %v", err)
		} else if err := c.writeListenerSnapshot(model); err != nil {
			c.logger.Printf("write initial listener snapshot failed: %v", err)
		}
	}
	defer func() {
		if !c.listenerReady {
			return
		}
		c.waitListenerWriteSlot()
		if err := c.writeListenerSnapshot(listenerModel{Now: time.Now(), State: "stopping", LinkAge: linkFreshAge(c.home, time.Now())}); err != nil {
			c.logger.Printf("write final listener snapshot failed: %v", err)
		}
	}()
	ticker := time.NewTicker(c.scanEvery)
	defer ticker.Stop()
	listenerTicker := time.NewTicker(c.listenerInterval)
	defer listenerTicker.Stop()
	debounce := time.NewTimer(time.Hour)
	if !debounce.Stop() {
		<-debounce.C
	}
	defer debounce.Stop()
	var debounceC <-chan time.Time
	listenerDebounce := time.NewTimer(time.Hour)
	if !listenerDebounce.Stop() {
		<-listenerDebounce.C
	}
	defer listenerDebounce.Stop()
	var listenerDebounceC <-chan time.Time
	cancelDebounce := func() {
		if !debounce.Stop() {
			select {
			case <-debounce.C:
			default:
			}
		}
		debounceC = nil
	}
	scheduleScan := func() {
		cancelDebounce()
		debounce.Reset(200 * time.Millisecond)
		debounceC = debounce.C
	}
	scheduleListener := func(delay time.Duration) {
		if !listenerDebounce.Stop() {
			select {
			case <-listenerDebounce.C:
			default:
			}
		}
		listenerDebounce.Reset(delay)
		listenerDebounceC = listenerDebounce.C
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			cancelDebounce()
			if c.scan() {
				scheduleListener(2 * time.Second)
			}
		case <-listenerTicker.C:
			if wait := c.listenerWriteDelay(); wait > 0 {
				scheduleListener(wait)
			} else if model, err := c.captureListenerModel("running"); err != nil {
				c.logger.Printf("build periodic listener snapshot failed: %v", err)
			} else if err := c.writeListenerSnapshot(model); err != nil {
				c.logger.Printf("write periodic listener snapshot failed: %v", err)
			}
		case <-debounceC:
			debounceC = nil
			if c.scan() {
				scheduleListener(2 * time.Second)
			}
		case <-listenerDebounceC:
			listenerDebounceC = nil
			if wait := c.listenerWriteDelay(); wait > 0 {
				scheduleListener(wait)
			} else if model, err := c.captureListenerModel("running"); err != nil {
				c.logger.Printf("build transition listener snapshot failed: %v", err)
			} else if listenerReachabilitySignature(model.Identities) != c.listenerLastSignature || c.listenerForceWrite {
				if err := c.writeListenerSnapshot(model); err != nil {
					c.logger.Printf("write transition listener snapshot failed: %v", err)
				}
			}
		case err, ok := <-c.watcher.Errors:
			if !ok {
				return nil
			}
			c.logger.Printf("fsnotify error; full rescan: %v", err)
			cancelDebounce()
			if c.scan() {
				scheduleListener(2 * time.Second)
			}
		case event, ok := <-c.watcher.Events:
			if !ok {
				return nil
			}
			if strings.HasPrefix(filepath.Base(event.Name), ".") {
				continue
			}
			scheduleScan()
			parent := filepath.Dir(event.Name)
			if parent == filepath.Join(c.runtime, "sessions") || parent == filepath.Join(c.runtime, "identities") {
				scheduleListener(2 * time.Second)
			}
		}
	}
}

func (c *notifier) refreshWatches() error {
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

func (c *notifier) scan() bool {
	c.scanComplete = false
	if err := c.refreshWatches(); err != nil {
		c.logger.Printf("refresh watches failed: %v", err)
	}
	regs, err := loadRegistrations(c.runtime, c.bootID)
	if err != nil {
		c.logger.Printf("load registrations failed: %v", err)
		return false
	}
	c.pruneVerificationReasons(regs)
	if c.triage != nil {
		// Only enqueues judgments and reads/cleans the cache; never waits on the API.
		c.triage.scan()
	}
	registries, err := loadClaudeRegistries()
	if err != nil {
		c.logger.Printf("load Claude registry failed: %v", err)
		return false
	}
	verifiedRegs := make(map[string]bool, len(regs))
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
		if verified {
			verifiedRegs[instance] = true
			c.healLease(regs[instance])
		}
		c.logVerification(instance, verified, loggedReason(regs[instance], reason))
	}
	c.reclaimLeases(regs, verifiedRegs)
	c.reapDeadRegistrations(regs)
	leases, err := loadListenerLeases(c.runtime, c.bootID)
	if err != nil {
		c.logger.Printf("load leases failed: %v", err)
		return false
	}
	transition := c.registrationListenerTransition(regs, leases)
	identities := make([]string, 0, len(leases))
	for identity := range leases {
		identities = append(identities, identity)
	}
	sort.Strings(identities)
	for _, identity := range identities {
		messages := c.pending(identity)
		if len(notifiableMessages(messages)) == 0 {
			c.statesMu.Lock()
			delete(c.states, identity)
			c.statesMu.Unlock()
			continue
		}
		lease := leases[identity]
		if lease.State != "owned" ||
			!validInstanceID(lease.InstanceID) {
			c.observeQueueDigest(identity, "", messages)
			continue
		}
		reg, ok := regs[lease.InstanceID]
		if !ok || reg.Identity != identity {
			c.observeQueueDigest(identity, "", messages)
			continue
		}
		c.maybeNotify(identity, lease, reg, messages)
	}
	c.noticeParents(regs)
	c.scanComplete = true
	c.listenerReady = true
	return transition
}

func (c *notifier) registrationListenerTransition(registrations map[string]sessionRegistration, leases map[string]identityLease) bool {
	byIdentity := make(map[string][]sessionRegistration)
	identitySet := make(map[string]bool)
	currentInstances := make(map[string]bool, len(registrations))
	for instance, registration := range registrations {
		byIdentity[registration.Identity] = append(byIdentity[registration.Identity], registration)
		identitySet[registration.Identity] = true
		currentInstances[instance] = true
	}
	for identity := range leases {
		identitySet[identity] = true
	}
	names := make([]string, 0, len(identitySet))
	for identity := range identitySet {
		names = append(names, identity)
	}
	sort.Strings(names)
	rows := make([]listenerIdentity, 0, len(names))
	for _, identity := range names {
		row, err := c.buildListenerIdentityBase(identity, byIdentity[identity], leases[identity])
		if err != nil {
			c.logger.Printf("build listener snapshot transition state failed: %v", err)
			return false
		}
		rows = append(rows, row)
	}
	current := listenerReachabilitySignature(rows)
	if !c.listenerSignatureSet {
		c.listenerRegistrationSig = current
		c.listenerInstances = currentInstances
		c.listenerSignatureSet = true
		return false
	}
	changed := current != c.listenerRegistrationSig
	for instance := range c.listenerInstances {
		if !currentInstances[instance] {
			c.listenerMu.Lock()
			c.listenerForceWrite = true
			c.listenerMu.Unlock()
			break
		}
	}
	c.listenerRegistrationSig = current
	c.listenerInstances = currentInstances
	return changed
}

func (c *notifier) observeQueueDigest(identity, instance string, messages []pendingMessage) {
	if len(notifiableMessages(messages)) == 0 {
		return
	}
	pendingDigest := queueDigest(messages)
	c.statesMu.Lock()
	state := c.states[identity]
	c.statesMu.Unlock()
	changed := false
	if state == nil {
		if instance == "" {
			state = &notifierState{pendingDigest: pendingDigest, firstSeen: time.Now()}
		} else {
			state = c.restoreState(identity, instance, pendingDigest)
		}
		c.statesMu.Lock()
		if existing := c.states[identity]; existing != nil {
			state = existing
		} else {
			c.states[identity] = state
		}
		c.statesMu.Unlock()
		changed = true
	}
	c.statesMu.Lock()
	if state.pendingDigest != pendingDigest {
		state.pendingDigest = pendingDigest
		state.firstSeen = time.Now()
		state.attemptIndex = 0
		state.notificationsSent = 0
		state.echoLogged = false
		changed = true
	}
	snapshot := *state
	c.statesMu.Unlock()
	if changed {
		if err := c.writeListenerSidecar(identity, snapshot); err != nil {
			c.logger.Printf("write listener sidecar %s failed: %v", identity, err)
		}
	}
}

func (c *notifier) pruneVerificationReasons(regs map[string]sessionRegistration) {
	for instance := range c.verificationReasons {
		if _, exists := regs[instance]; !exists {
			delete(c.verificationReasons, instance)
		}
	}
}

// loggedReason is the verification failure worth a log line. A Codex worker (an
// exec lane) is never rung — its mail enters the turn through hooks (D18) — so
// registering without a receive opt-in is how it is meant to be, not a fault.
func loggedReason(reg sessionRegistration, reason string) string {
	if reg.Harness == "codex" && reg.Kind == "worker" && reason == "non-interactive registration lacks opt-in" {
		return ""
	}
	return reason
}

func (c *notifier) logVerification(instance string, verified bool, reason string) {
	if c.verificationReasons == nil {
		c.verificationReasons = make(map[string]string)
	}
	previous, wasUnverified := c.verificationReasons[instance]
	if verified {
		if wasUnverified {
			c.logger.Printf("registration %s verified", instance)
			delete(c.verificationReasons, instance)
		}
		return
	}
	if reason != "" && (!wasUnverified || previous != reason) {
		c.logger.Printf("registration %s not verified: %s", instance, reason)
		c.verificationReasons[instance] = reason
	}
}

func (c *notifier) verifyRegistration(reg sessionRegistration, registries []claudeRegistry) (sessionRegistration, bool, string) {
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
	case resolved.Harness == "codex":
		if !resolved.ChannelVerified {
			verified, reason = false, "Codex channel is not verified"
		} else if err := c.verifyChannelSocket(resolved); err != nil {
			verified, reason = false, "Codex channel socket is invalid"
		}
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

// healLease copies a verified registration's pid/pidStart into the identity
// lease it owns when the lease recorded none. On `claude --resume` the Claude
// registry file can land after the hook's binds, so the lease captured pid 0;
// the notification gate then never matches (measured 2026-08-16, ink resume). Only the
// same instance/epoch/session is healed; nothing else about the lease changes.
func (c *notifier) healLease(reg sessionRegistration) {
	if reg.PID <= 1 || reg.PIDStart == "" || reg.LeaseEpoch == 0 {
		return
	}
	leasePath := filepath.Join(c.runtime, "identities", reg.Identity+".lease")
	var current identityLease
	if err := readJSON(leasePath, &current); err != nil {
		c.logger.Printf("heal lease %s failed: %v", reg.Identity, err)
		return
	}
	if !leaseNeedsHeal(current, reg) {
		return
	}
	err := withRuntimeLock(filepath.Join(c.runtime, "identities", ".leases.lock"), c.bootID, func() error {
		var lease identityLease
		if err := readJSON(leasePath, &lease); err != nil {
			return err
		}
		if !leaseNeedsHeal(lease, reg) {
			return nil
		}
		lease.PID = reg.PID
		lease.PIDStart = reg.PIDStart
		c.logger.Printf("healed lease %s: pid %d start %s", reg.Identity, reg.PID, reg.PIDStart)
		return writeAtomicJSON(leasePath, lease, 0600)
	})
	if err != nil {
		c.logger.Printf("heal lease %s failed: %v", reg.Identity, err)
	}
}

func leaseNeedsHeal(lease identityLease, reg sessionRegistration) bool {
	if lease.BootID != reg.BootID || lease.State != "owned" || lease.InstanceID != reg.InstanceID ||
		lease.Epoch != reg.LeaseEpoch || lease.ClaudeSessionID != reg.ClaudeSessionID {
		return false
	}
	if lease.PID == reg.PID && lease.PIDStart == reg.PIDStart {
		return false
	}
	return lease.PID <= 1 || lease.PID == reg.PID
}

func (c *notifier) reclaimLeases(regs map[string]sessionRegistration, verified map[string]bool) {
	byIdentity := make(map[string][]sessionRegistration)
	for instance, reg := range regs {
		if verified[instance] && (reg.Kind == "interactive" || reg.ReceiveOptIn) {
			byIdentity[reg.Identity] = append(byIdentity[reg.Identity], reg)
		}
	}
	identities := make([]string, 0, len(byIdentity))
	for identity := range byIdentity {
		identities = append(identities, identity)
	}
	sort.Strings(identities)
	for _, identity := range identities {
		leasePath := filepath.Join(c.runtime, "identities", identity+".lease")
		var lease identityLease
		if err := readJSON(leasePath, &lease); err != nil && !os.IsNotExist(err) {
			c.logger.Printf("reclaim lease %s failed: %v", identity, err)
			continue
		}
		if leaseOwnerLive(c.runtime, c.bootID, lease) {
			continue
		}
		candidates := byIdentity[identity]
		sort.Slice(candidates, func(i, j int) bool {
			left, leftErr := time.Parse(time.RFC3339Nano, candidates[i].StartedAt)
			right, rightErr := time.Parse(time.RFC3339Nano, candidates[j].StartedAt)
			if leftErr == nil && rightErr == nil && !left.Equal(right) {
				return left.After(right)
			}
			if leftErr == nil && rightErr != nil {
				return true
			}
			if leftErr != nil && rightErr == nil {
				return false
			}
			if candidates[i].StartedAt != candidates[j].StartedAt {
				return candidates[i].StartedAt > candidates[j].StartedAt
			}
			return candidates[i].InstanceID < candidates[j].InstanceID
		})
		candidate := candidates[0]
		owner, epoch, err := claimLease(c.runtime, c.bootID, &candidate, false)
		if err != nil {
			c.logger.Printf("reclaim lease %s failed: %v", identity, err)
			continue
		}
		if !owner {
			continue
		}
		if err := mutateRegistration(c.runtime, c.bootID, candidate.InstanceID, func(reg *sessionRegistration) error {
			reg.LeaseEpoch = epoch
			return nil
		}); err != nil {
			c.logger.Printf("reclaim lease %s registration update failed: %v", identity, err)
			continue
		}
		candidate.LeaseEpoch = epoch
		regs[candidate.InstanceID] = candidate
		c.logger.Printf("reclaimed lease %s for instance %s", identity, candidate.InstanceID)
	}
}

const deadRegistrationReapAfter = 10 * time.Minute

func deadRegistrationExpired(reg sessionRegistration, bootID string, now time.Time) bool {
	if reg.BootID != bootID || reg.PID <= 1 || processAliveWithStart(reg.PID, reg.PIDStart, bootID) {
		return false
	}
	started, err := time.Parse(time.RFC3339Nano, reg.StartedAt)
	return err == nil && started.Before(now.Add(-deadRegistrationReapAfter))
}

func registrationOwnsLease(root, bootID string, reg sessionRegistration) (bool, error) {
	var lease identityLease
	err := readJSON(filepath.Join(root, "identities", reg.Identity+".lease"), &lease)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return lease.BootID == bootID && lease.State == "owned" && lease.InstanceID == reg.InstanceID, nil
}

func (c *notifier) reapDeadRegistrations(regs map[string]sessionRegistration) {
	now := time.Now()
	instances := make([]string, 0, len(regs))
	for instance, reg := range regs {
		if deadRegistrationExpired(reg, c.bootID, now) {
			instances = append(instances, instance)
		}
	}
	sort.Strings(instances)
	for _, instance := range instances {
		var reaped sessionRegistration
		err := withRegistrationLock(c.runtime, c.bootID, func() error {
			path := filepath.Join(c.runtime, "sessions", instance+".json")
			var latest sessionRegistration
			if err := readJSON(path, &latest); err != nil {
				if os.IsNotExist(err) {
					return nil
				}
				return err
			}
			if latest.InstanceID != instance || !deadRegistrationExpired(latest, c.bootID, now) {
				return nil
			}
			ownsLease, err := registrationOwnsLease(c.runtime, c.bootID, latest)
			if err != nil {
				return err
			}
			if ownsLease {
				return nil
			}
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return err
			}
			reaped = latest
			return nil
		})
		if err != nil {
			c.logger.Printf("reap registration %s failed: %v", instance, err)
			continue
		}
		if reaped.InstanceID != "" {
			delete(regs, instance)
			delete(c.verificationReasons, instance)
			c.logger.Printf("reaped dead registration %s (%s)", reaped.InstanceID, reaped.Identity)
		}
	}
}

func (c *notifier) pending(identity string) []pendingMessage {
	return c.readPending(identity, false)
}

func (c *notifier) pendingForSnapshot(identity string) []pendingMessage {
	return c.readPending(identity, true)
}

func (c *notifier) readPending(identity string, includeMtime bool) []pendingMessage {
	dir := filepath.Join(c.home, "inbox", identity, "new")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	messages := make([]pendingMessage, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !validBasename(entry.Name()) {
			continue
		}
		messageItem := pendingMessage{id: entry.Name()}
		typeValue := ""
		urgencyValue := ""
		f, err := openRegular(filepath.Join(dir, entry.Name()))
		if err == nil {
			if includeMtime {
				info, statErr := f.Stat()
				if statErr == nil {
					messageItem.installedAt = info.ModTime().Unix()
				}
			}
			scanner := bufio.NewScanner(io.LimitReader(f, 64<<10))
			for scanner.Scan() {
				line := scanner.Text()
				if line == "" {
					break
				}
				if strings.HasPrefix(line, "From: ") {
					messageItem.from = sanitizePreview(strings.TrimPrefix(line, "From: "), 128)
				}
				if strings.HasPrefix(line, "Subject: ") {
					messageItem.subject = sanitizePreview(strings.TrimPrefix(line, "Subject: "), 256)
				}
				if strings.HasPrefix(line, "Priority: ") && strings.TrimSpace(strings.TrimPrefix(line, "Priority: ")) == "later" {
					messageItem.later = true
				}
				if strings.HasPrefix(line, "Type: ") {
					typeValue = strings.TrimSpace(strings.TrimPrefix(line, "Type: "))
				}
				if strings.HasPrefix(line, "Urgency: ") {
					urgencyValue = strings.TrimSpace(strings.TrimPrefix(line, "Urgency: "))
				}
			}
			_ = f.Close()
		}
		messageItem.kind = typeValue
		if typeValue == "notice" {
			messageItem.alert = true
			messageItem.urgent = urgencyValue != "info"
		}
		messages = append(messages, messageItem)
	}
	sort.Slice(messages, func(i, j int) bool { return messages[i].id < messages[j].id })
	return messages
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

func queueDigest(messages []pendingMessage) string {
	ids := make([]string, 0, len(messages))
	for _, messageItem := range messages {
		if !messageItem.alert || messageItem.urgent {
			ids = append(ids, messageItem.id)
		}
	}
	sort.Strings(ids)
	if len(ids) == 0 {
		return "-"
	}
	hash := sha256.New()
	for _, id := range ids {
		_, _ = io.WriteString(hash, id)
		_, _ = hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func notifiableMessages(messages []pendingMessage) []pendingMessage {
	notifiable := make([]pendingMessage, 0, len(messages))
	for _, messageItem := range messages {
		if !messageItem.alert || messageItem.urgent {
			notifiable = append(notifiable, messageItem)
		}
	}
	return notifiable
}

func messageCounts(messages []pendingMessage) (mail, alerts, urgent int) {
	for _, messageItem := range messages {
		if !messageItem.alert {
			mail++
			continue
		}
		alerts++
		if messageItem.urgent {
			urgent++
		}
	}
	return mail, alerts, urgent
}

func (c *notifier) maybeNotify(identity string, lease identityLease, reg sessionRegistration, messages []pendingMessage) {
	if len(notifiableMessages(messages)) == 0 {
		c.statesMu.Lock()
		delete(c.states, identity)
		c.statesMu.Unlock()
		return
	}
	now := time.Now()
	pendingDigest := queueDigest(messages)
	c.statesMu.Lock()
	state := c.states[identity]
	if state == nil {
		state = c.restoreState(identity, reg.InstanceID, pendingDigest)
		state.targetInstance = reg.InstanceID
		state.targetPID = reg.PID
		state.targetPIDStart = reg.PIDStart
		c.states[identity] = state
	} else if state.targetInstance == "" && state.targetPID == 0 && state.targetPIDStart == "" {
		state.targetInstance = reg.InstanceID
		state.targetPID = reg.PID
		state.targetPIDStart = reg.PIDStart
	} else if state.targetInstance != reg.InstanceID || state.targetPID != reg.PID || state.targetPIDStart != reg.PIDStart {
		state.targetInstance = reg.InstanceID
		state.targetPID = reg.PID
		state.targetPIDStart = reg.PIDStart
		state.attemptIndex = 0
		state.outstandingNotifications = 0
		state.outstandingWritten = time.Time{}
		state.failures = 0
		state.echoLogged = false
		if state.lastAttempt.IsZero() || now.Sub(state.lastAttempt) >= c.backoff[0] {
			state.nextAttempt = now
		} else {
			state.nextAttempt = state.lastAttempt.Add(c.backoff[0])
		}
	}
	inboxRead := c.readInboxReadMarker(identity)
	if state.outstandingNotifications > 0 && inboxRead.Token != state.lastInboxReadToken && inboxRead.LastDrain >= state.outstandingWritten.Unix() {
		state.outstandingNotifications = 0
		state.outstandingWritten = time.Time{}
		state.nextAttempt = now
	}
	state.lastInboxReadToken = inboxRead.Token
	if state.pendingDigest != pendingDigest {
		state.pendingDigest = pendingDigest
		state.firstSeen = now
		state.attemptIndex = 0
		state.notificationsSent = 0
		state.echoLogged = false
		if state.outstandingNotifications == 0 {
			if state.lastAttempt.IsZero() || now.Sub(state.lastAttempt) >= c.backoff[0] {
				state.nextAttempt = now
			} else {
				state.nextAttempt = state.lastAttempt.Add(c.backoff[0])
			}
		}
		if err := c.writeListenerSidecar(identity, *state); err != nil {
			c.logger.Printf("write listener sidecar %s failed: %v", identity, err)
		}
	}
	if now.Before(state.nextAttempt) {
		c.statesMu.Unlock()
		return
	}
	if state.outstandingNotifications > 0 {
		turn := c.readTurnMarker(identity)
		if turn.Present && turn.LastTurn < state.outstandingWritten.Unix() {
			c.statesMu.Unlock()
			return
		}
	}
	state.attemptIndex++
	attemptIndex := state.attemptIndex
	retry := state.notificationsSent
	c.statesMu.Unlock()

	attemptID, err := newUUID()
	if err != nil {
		c.logger.Printf("create attempt id failed: %v", err)
		return
	}
	journal := deliveryJournal{
		BootID: c.bootID, Identity: identity, InstanceID: reg.InstanceID,
		Generation: pendingDigest, AttemptID: attemptID, AttemptIndex: attemptIndex,
		AttemptedAt: now.UTC().Format(time.RFC3339Nano), FirstSeen: state.firstSeen.UTC().Format(time.RFC3339Nano),
		PeerStatus: "unknown", CCVersion: reg.CCVersion,
	}
	for _, messageItem := range notifiableMessages(messages) {
		journal.LetterIDs = append(journal.LetterIDs, messageItem.id)
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
		frame := c.frame(identity, pendingDigest, attemptID, retry, messages)
		if notifierBeforeNotificationWrite != nil {
			notifierBeforeNotificationWrite(identity)
		}
		freshMessages := c.pending(identity)
		if queueDigest(freshMessages) != pendingDigest {
			c.logger.Printf("doorbell skipped: generation changed before write (%s)", identity)
			if len(notifiableMessages(freshMessages)) == 0 {
				c.statesMu.Lock()
				delete(c.states, identity)
				c.statesMu.Unlock()
			}
			return
		}
		if reg.ChannelSocket != "" {
			deliveryErr = c.verifyChannelSocket(reg)
			if deliveryErr == nil {
				deliveryErr = writeChannelNotification(reg.ChannelSocket, c.channelRequest(pendingDigest, attemptID, retry, messages))
			}
			if deliveryErr == nil {
				journal.Via = "channel"
				if !reg.ChannelVerified && reg.Harness != "codex" {
					info, socketErr := os.Lstat(reg.SocketPath)
					if socketErr == nil && info.Mode()&os.ModeSymlink == 0 && info.Mode()&os.ModeSocket != 0 {
						deliveryErr = writeNotification(reg.SocketPath, frame)
						if deliveryErr == nil {
							journal.Via = "channel+socket"
							c.statesMu.Lock()
							if !state.echoLogged {
								c.logger.Printf("channel written; socket ring echoed (opt-in unverified)")
								state.echoLogged = true
							}
							c.statesMu.Unlock()
						} else {
							c.logger.Printf("channel written but socket echo %s failed: %v", reg.InstanceID, deliveryErr)
						}
					}
				}
			} else {
				journal.ChannelError = deliveryErr.Error()
				if reg.Harness == "codex" {
					journal.Via = "channel"
					c.logger.Printf("Codex channel doorbell %s failed: %v", reg.InstanceID, deliveryErr)
				} else {
					c.logger.Printf("channel doorbell %s failed: %v; falling back to socket", reg.InstanceID, deliveryErr)
					journal.Via = "socket"
					deliveryErr = writeNotification(reg.SocketPath, frame)
				}
			}
		} else if reg.Harness == "codex" {
			journal.Via = "channel"
			deliveryErr = errors.New("Codex channel is not bound")
		} else {
			journal.Via = "socket"
			deliveryErr = writeNotification(reg.SocketPath, frame)
		}
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
		state.failures = 0
		state.lastWritten = now
		state.outstandingWritten = now
		state.notificationsSent++
		state.outstandingNotifications++
		state.nextAttempt = now.Add(notificationRetryAfter(state.outstandingNotifications))
	} else {
		delayIndex := attemptIndex - 1
		if delayIndex >= len(c.backoff) {
			delayIndex = len(c.backoff) - 1
		}
		state.nextAttempt = now.Add(c.backoff[delayIndex])
		state.failures++
	}
	failures := state.failures
	sidecarState := *state
	c.statesMu.Unlock()
	if journal.Status == "written" {
		if err := c.writeListenerSidecar(identity, sidecarState); err != nil {
			c.logger.Printf("write listener sidecar %s failed: %v", identity, err)
		}
	}
	c.updateNativeStatus(reg, failures)
}

func (c *notifier) restoreState(identity, instance, pendingDigest string) *notifierState {
	state := &notifierState{pendingDigest: pendingDigest}
	sidecarCurrent := false
	if sidecar, err := c.readListenerSidecar(identity); err == nil {
		if sidecar.LastWritten > 0 {
			state.lastWritten = time.Unix(sidecar.LastWritten, 0)
		}
		if sidecar.Generation == pendingDigest {
			sidecarCurrent = true
			state.firstSeen = time.Unix(sidecar.FirstSeen, 0)
			state.notificationsSent = sidecar.WrittenRings
		}
	}
	inboxRead := c.readInboxReadMarker(identity)
	state.lastInboxReadToken = inboxRead.Token
	dir := filepath.Join(c.runtime, "deliveries", identity, instance)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if pendingDigest != "" && state.firstSeen.IsZero() {
			state.firstSeen = time.Now()
			if err := c.writeListenerSidecar(identity, *state); err != nil && c.logger != nil {
				c.logger.Printf("write listener sidecar %s failed: %v", identity, err)
			}
		}
		return state
	}
	var journals []deliveryJournalAt
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		var journal deliveryJournal
		if readJSON(filepath.Join(dir, entry.Name()), &journal) != nil || journal.BootID != c.bootID || journal.Identity != identity || journal.InstanceID != instance {
			continue
		}
		attempted, parseErr := time.Parse(time.RFC3339Nano, journal.AttemptedAt)
		if parseErr == nil {
			journals = append(journals, deliveryJournalAt{journal: journal, at: attempted})
		}
	}
	if len(journals) == 0 {
		if pendingDigest != "" {
			state.firstSeen = time.Now()
		}
		return state
	}
	sort.Slice(journals, func(i, j int) bool { return journals[i].at.Before(journals[j].at) })
	var latest, latestCurrent deliveryJournalAt
	for _, item := range journals {
		latest = item
		if item.journal.Status == "failed" {
			state.failures++
		} else if item.journal.Status == "written" {
			state.failures = 0
			if state.lastWritten.IsZero() || item.at.After(state.lastWritten) {
				state.lastWritten = item.at
			}
			if inboxRead.LastDrain < item.at.Unix() {
				state.outstandingNotifications++
				state.outstandingWritten = item.at
			}
			if !sidecarCurrent && item.journal.Generation == pendingDigest {
				state.notificationsSent++
			}
		}
		if item.journal.Generation == pendingDigest {
			firstSeen := item.at
			if recorded, err := time.Parse(time.RFC3339Nano, item.journal.FirstSeen); err == nil {
				firstSeen = recorded
			}
			if state.firstSeen.IsZero() || firstSeen.Before(state.firstSeen) {
				state.firstSeen = firstSeen
			}
			latestCurrent = item
			if item.journal.Via == "channel+socket" {
				state.echoLogged = true
			}
		}
	}
	if latestCurrent.at.IsZero() {
		if pendingDigest != "" {
			if state.firstSeen.IsZero() {
				state.firstSeen = time.Now()
			}
			if err := c.writeListenerSidecar(identity, *state); err != nil && c.logger != nil {
				c.logger.Printf("write listener sidecar %s failed: %v", identity, err)
			}
		}
	} else {
		state.attemptIndex = latestCurrent.journal.AttemptIndex
	}
	state.lastAttempt = latest.at
	if latest.journal.Status == "failed" && (state.lastWritten.IsZero() || latest.at.After(state.lastWritten)) {
		index := latest.journal.AttemptIndex - 1
		if index < 0 {
			index = 0
		}
		if index >= len(c.backoff) {
			index = len(c.backoff) - 1
		}
		state.nextAttempt = latest.at.Add(c.backoff[index])
	} else if state.outstandingNotifications > 0 {
		state.nextAttempt = state.outstandingWritten.Add(notificationRetryAfter(state.outstandingNotifications))
	}
	if err := c.writeListenerSidecar(identity, *state); err != nil && c.logger != nil {
		c.logger.Printf("write listener sidecar %s failed: %v", identity, err)
	}
	return state
}

func (c *notifier) updateNativeStatus(reg sessionRegistration, failures int) {
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

// retry is the number of earlier attempts already written for this same
// queue digest (0 on the first notification). A session that sees retry > 0 learns that
// earlier notifications opened turns without an inbox read (measured 2026-09-02: an
// account limit opened four turns that could not run a model call).
func (c *notifier) frame(identity, pendingDigest, attempt string, retry int, messages []pendingMessage) map[string]any {
	from, subjects := notificationDisplay(messages)
	mail, alerts, urgent := messageCounts(messages)
	streamPending := c.pendingStreams(identity)
	triageLine := ""
	if c.triage != nil {
		if line := c.triage.frameLine(identity, messages); line != "" {
			triageLine = line + "\n"
		}
	}
	content := fmt.Sprintf("KHALA-CONDUIT/1\nrecipient: %s@%s\npending: %d\nnotices: %d\nurgent: %d\nstreams: %d\nfrom: %s\nsubjects: %s\n%sgeneration: %s\nattempt: %s\nretry: %d\nread: khala inbox --drain",
		identity, c.self, mail, alerts, urgent, streamPending, strings.Join(from, ", "), strings.Join(subjects, "; "), triageLine, pendingDigest, attempt, retry)
	if len(content) > 8192 {
		content = content[:8192]
		for !utf8.ValidString(content) {
			content = content[:len(content)-1]
		}
	}
	return map[string]any{
		"type":    "user",
		"message": map[string]string{"role": "user", "content": content},
		"from":    "khala:conduit@" + c.self, "priority": notificationPriority(messages), "msg_id": pendingDigest + ":" + attempt,
	}
}

func notificationDisplay(messages []pendingMessage) ([]string, []string) {
	fromSet := make(map[string]struct{})
	var from []string
	var subjects []string
	for _, messageItem := range messages {
		if messageItem.alert && !messageItem.urgent {
			continue
		}
		if messageItem.from != "" {
			if _, seen := fromSet[messageItem.from]; !seen && len(from) < 8 {
				fromSet[messageItem.from] = struct{}{}
				from = append(from, messageItem.from)
			}
		}
		if messageItem.subject != "" && len(subjects) < 8 {
			subject := messageItem.subject
			if messageItem.alert {
				subject = "U · " + subject
			}
			subjects = append(subjects, subject)
		}
	}
	return from, subjects
}

func (c *notifier) channelRequest(pendingDigest, attempt string, retry int, messages []pendingMessage) map[string]any {
	from, subjects := notificationDisplay(messages)
	mail, alerts, urgent := messageCounts(messages)
	meta := map[string]string{
		"from":       strings.Join(from, ", "),
		"subject":    strings.Join(subjects, "; "),
		"pending":    strconv.Itoa(mail),
		"notices":    strconv.Itoa(alerts),
		"urgent":     strconv.Itoa(urgent),
		"generation": pendingDigest,
		"attempt":    attempt,
		"retry":      strconv.Itoa(retry),
	}
	if len(from) == 1 {
		meta["user"] = from[0]
	} else {
		meta["user"] = fmt.Sprintf("%d senders", len(from))
	}
	if notificationPriority(messages) == "later" {
		meta["later"] = "1"
	}
	notifiable := notifiableMessages(messages)
	lines := make([]string, 0, len(notifiable)+1)
	for _, messageItem := range notifiable {
		if messageItem.alert {
			lines = append(lines, fmt.Sprintf("%s · U · %s", messageItem.from, messageItem.subject))
		} else {
			lines = append(lines, fmt.Sprintf("%s · %s", messageItem.from, messageItem.subject))
		}
	}
	lines = append(lines, fmt.Sprintf("%d letters, %d notices — run khala_drain", mail, alerts))
	return map[string]any{"v": 1, "content": strings.Join(lines, "\n"), "meta": meta}
}

func (c *notifier) verifyChannelSocket(reg sessionRegistration) error {
	if !processAliveWithStart(reg.ChannelPID, reg.ChannelPIDStart, c.bootID) {
		return errors.New("channel pid/start mismatch")
	}
	dir := filepath.Join(c.runtime, "channels")
	expected := filepath.Join(dir, reg.InstanceID+".sock")
	if filepath.Clean(reg.ChannelSocket) != expected {
		return fmt.Errorf("channel socket is outside runtime channels: %s", reg.ChannelSocket)
	}
	dirInfo, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("inspect channel directory: %w", err)
	}
	if dirInfo.Mode()&os.ModeSymlink != 0 || !dirInfo.IsDir() || dirInfo.Mode().Perm() != 0700 {
		return errors.New("channel directory is not a real 0700 directory")
	}
	if stat, ok := dirInfo.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
		return errors.New("channel directory uid mismatch")
	}
	info, err := os.Lstat(expected)
	if err != nil {
		return fmt.Errorf("inspect channel socket: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeSocket == 0 {
		return errors.New("channel socket is not a real Unix socket")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
		return errors.New("channel socket uid mismatch")
	}
	return nil
}

// notificationPriority is the Claude Code inbox priority of one inbox notification. The
// default is "next": Claude Code dequeues next between tool calls of a running
// turn, exactly as its own SendMessage does, while "later" waits for idle —
// and an autonomous turn can run for tens of minutes (user decision
// 2026-08-17, superseding the 0.5.0 default). A inbox notification drops to "later" only
// when every notifiable message carries "Priority: later" (khala send
// --later); info alerts are outside that set, while one ordinary message keeps
// the batch prompt. "now" is never minted here.
func notificationPriority(messages []pendingMessage) string {
	notifiable := notifiableMessages(messages)
	if len(notifiable) == 0 {
		return "next"
	}
	for _, messageItem := range notifiable {
		if !messageItem.later {
			return "next"
		}
	}
	return "later"
}

func (c *notifier) pendingStreams(identity string) int {
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

func writeNotification(socketPath string, frame map[string]any) error {
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

func writeChannelNotification(socketPath string, request map[string]any) error {
	connection, err := net.DialTimeout("unix", socketPath, 250*time.Millisecond)
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		return err
	}
	data, err := json.Marshal(request)
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
	responseData, err := bufio.NewReader(io.LimitReader(connection, 4097)).ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read channel response: %w", err)
	}
	if len(responseData) > 4096 {
		return errors.New("channel response exceeds 4096 bytes")
	}
	var response struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(responseData, &response); err != nil {
		return fmt.Errorf("parse channel response: %w", err)
	}
	if !response.OK {
		return fmt.Errorf("channel rejected inbox notification: %s", firstNonempty(response.Error, "unspecified error"))
	}
	return nil
}
