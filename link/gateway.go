package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

// khala-link gateway: a resident relay between one chat (a Telegram forum
// supergroup, one topic per session) and the khala mailbox of the reserved
// identity `user` on this node. See docs/GATEWAY.md and review/d17-b-r1.md.

const (
	gatewayUser            = "user"
	gatewayTextLimit       = 4096 // Telegram sendMessage limit, in UTF-16 code units
	gatewayCaptionRunes    = 300
	gatewaySubjectRunes    = 80
	gatewayStatusSpacing   = 5 * 60
	gatewaySnapshotMaxAge  = 10 * 60
	gatewayStatusInterval  = 30 * time.Second
	gatewayInboxInterval   = time.Second
	gatewayInboxRescan     = 60 * time.Second
	gatewayShutdownFlush   = 10 * time.Second
	gatewayKhalaTimeout    = 75 * time.Second
	gatewayPostsPerMinute  = 20
	gatewayMaxMessageBytes = 1 << 20
)

type outItem struct {
	thread  int64
	text    string
	replyTo int64
	docName string
	ackID   string // khala message Id to ack-read once the post succeeded
}

// outQueue is the FIFO of pending chat posts. inflight holds the khala Ids
// whose post is queued or in progress, so an inbox rescan does not post twice;
// held holds Ids whose post failed, until their retry time.
type outQueue struct {
	mu       sync.Mutex
	items    []outItem
	inflight map[string]bool
	held     map[string]time.Time
	notify   chan struct{}
}

func newOutQueue() *outQueue {
	return &outQueue{inflight: map[string]bool{}, held: map[string]time.Time{}, notify: make(chan struct{}, 1)}
}

func (q *outQueue) enqueue(item outItem) {
	q.mu.Lock()
	q.items = append(q.items, item)
	if item.ackID != "" {
		q.inflight[item.ackID] = true
	}
	q.mu.Unlock()
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

func (q *outQueue) pop() (outItem, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.items) == 0 {
		return outItem{}, false
	}
	item := q.items[0]
	q.items = q.items[1:]
	return item, true
}

func (q *outQueue) pushFront(item outItem) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.items = append([]outItem{item}, q.items...)
}

func (q *outQueue) done(id string) {
	if id == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	delete(q.inflight, id)
}

// hold keeps a failed Id out of rescans until the given time.
func (q *outQueue) hold(id string, until time.Time) {
	if id == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.held[id] = until
}

// isInflight reports an Id that must not be posted now: queued, being
// posted, or held after a failure.
func (q *outQueue) isInflight(id string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if until, ok := q.held[id]; ok {
		if time.Now().Before(until) {
			return true
		}
		delete(q.held, id)
	}
	return q.inflight[id]
}

func (q *outQueue) len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.items)
}

// rateLimiter allows at most limit events in any sliding window.
type rateLimiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	stamps []time.Time
	now    func() time.Time
	sleep  func(context.Context, time.Duration) error
}

func sleepContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (r *rateLimiter) wait(ctx context.Context) error {
	for {
		r.mu.Lock()
		now := r.now()
		keep := r.stamps[:0]
		for _, stamp := range r.stamps {
			if now.Sub(stamp) < r.window {
				keep = append(keep, stamp)
			}
		}
		r.stamps = keep
		if len(r.stamps) < r.limit {
			r.stamps = append(r.stamps, now)
			r.mu.Unlock()
			return nil
		}
		delay := r.stamps[0].Add(r.window).Sub(now)
		r.mu.Unlock()
		if err := r.sleep(ctx, delay); err != nil {
			return err
		}
	}
}

type gateway struct {
	home    string
	self    string
	conf    gatewayConf
	ad      adapter
	log     *log.Logger
	now     func() time.Time
	mu      sync.Mutex // guards st
	st      *gatewayState
	out     *outQueue
	limiter *rateLimiter
	denied  map[int64]time.Time
}

func newGateway(home string, conf gatewayConf, ad adapter, logger *log.Logger) (*gateway, error) {
	cfg, err := loadConfig(home)
	if err != nil {
		return nil, err
	}
	st, err := loadGatewayState(home)
	if err != nil {
		return nil, fmt.Errorf("load %s: %w (move it aside only if the topic mapping may be rebuilt by hand)", gatewayStateName, err)
	}
	return &gateway{
		home: home, self: cfg.self, conf: conf, ad: ad, log: logger, now: time.Now, st: st,
		out:     newOutQueue(),
		limiter: &rateLimiter{limit: gatewayPostsPerMinute, window: time.Minute, now: time.Now, sleep: sleepContext},
		denied:  map[int64]time.Time{},
	}, nil
}

// ------------------------------------------------------------ entry point

func runGateway(args []string) int {
	flags := flag.NewFlagSet("gateway", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	homeFlag := flags.String("home", "", "")
	once := flags.Bool("once", false, "")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: khala-link gateway [--home DIR] [--once]")
		return 2
	}
	home := *homeFlag
	if home == "" {
		var err error
		if home, err = khalaHome(); err != nil {
			fmt.Fprintf(os.Stderr, "khala-link gateway: %v\n", err)
			return 2
		}
	}
	home, err := filepath.Abs(home)
	if err != nil {
		fmt.Fprintf(os.Stderr, "khala-link gateway: %v\n", err)
		return 2
	}
	conf, err := loadGatewayConf(home)
	if err != nil {
		fmt.Fprintf(os.Stderr, "khala-link gateway: %v\n", err)
		return 2
	}
	if _, err := loadConfig(home); err != nil {
		fmt.Fprintf(os.Stderr, "khala-link gateway: %s is not a khala node: %v\n", home, err)
		return 2
	}
	logger, err := newGatewayLogger(home)
	if err != nil {
		fmt.Fprintf(os.Stderr, "khala-link gateway: open log: %v\n", err)
		return 1
	}
	lock, acquired, err := acquireGatewayLock(home)
	if err != nil {
		logger.Printf("lock run/gateway.pid: %v", err)
		return 1
	}
	if !acquired {
		logger.Printf("another gateway already holds %s; refusing to start a second poller", filepath.Join(home, "run", "gateway.pid"))
		return 1
	}
	defer lock.Close()
	var ad adapter
	switch conf.adapter {
	case "telegram":
		timeout := conf.pollTimeout
		if *once {
			timeout = 0
		}
		ad = newTelegramAdapter(telegramAPIBase, conf.token, conf.chat, timeout, logger)
	case "fake":
		ad = newFakeAdapter(filepath.Join(home, "run", "gateway-fake"))
	}
	g, err := newGateway(home, conf, ad, logger)
	if err != nil {
		logger.Printf("%v", err)
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	startCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	bot, err := ad.Me(startCtx)
	cancel()
	if err != nil {
		logger.Printf("getMe failed: %v", err)
		return 1
	}
	logger.Printf("connected as @%s chat=%d topics=%d", bot, conf.chat, len(g.st.Topics))
	if *once {
		return g.once(ctx)
	}
	g.run(ctx)
	return 0
}

func newGatewayLogger(home string) (*log.Logger, error) {
	dir := filepath.Join(home, "log")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	file := &rotatingLog{path: filepath.Join(dir, "gateway.log")}
	return log.New(io.MultiWriter(file, os.Stderr), "gateway: ", log.LstdFlags|log.Lmsgprefix), nil
}

// acquireGatewayLock holds an exclusive flock on run/gateway.pid for the
// process lifetime: two pollers on one bot token would steal each other's
// updates (Telegram answers the second getUpdates with 409).
func acquireGatewayLock(home string) (*os.File, bool, error) {
	runDir := filepath.Join(home, "run")
	if err := os.MkdirAll(runDir, 0700); err != nil {
		return nil, false, err
	}
	f, err := os.OpenFile(filepath.Join(runDir, "gateway.pid"), os.O_CREATE|os.O_RDWR, 0600)
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
	if err := f.Truncate(0); err != nil {
		f.Close()
		return nil, false, err
	}
	if _, err := fmt.Fprintf(f, "pid %d\nstart %d\n", os.Getpid(), time.Now().Unix()); err != nil {
		f.Close()
		return nil, false, err
	}
	return f, true, nil
}

// ------------------------------------------------------------ loops

func (g *gateway) once(ctx context.Context) int {
	code := 0
	if err := g.pollOnce(ctx); err != nil {
		g.log.Printf("poll: %v", err)
		code = 1
	}
	if err := g.scanInbox(ctx); err != nil {
		g.log.Printf("inbox: %v", err)
		code = 1
	}
	g.checkStatus(ctx)
	flushCtx, cancel := context.WithTimeout(context.Background(), gatewayShutdownFlush)
	defer cancel()
	if left := g.flush(flushCtx); left > 0 {
		g.log.Printf("%d posts not sent before exit", left)
	}
	if err := g.saveState(); err != nil {
		g.log.Printf("save state: %v", err)
		code = 1
	}
	return code
}

func (g *gateway) run(ctx context.Context) {
	batches := make(chan []inbound)
	handled := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); g.pollLoop(ctx, batches, handled) }()
	go func() { defer wg.Done(); g.sendLoop(ctx) }()
	inboxTick := time.NewTicker(gatewayInboxInterval)
	statusTick := time.NewTicker(gatewayStatusInterval)
	defer inboxTick.Stop()
	defer statusTick.Stop()
	lastScan := time.Time{}
	g.checkStatus(ctx)
	backoff := time.Duration(0)
loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case batch := <-batches:
			if err := g.handleBatch(ctx, batch); err != nil {
				backoff = nextBackoff(backoff)
				g.log.Printf("%v; retrying the same update in %s", err, backoff)
				_ = sleepContext(ctx, backoff)
			} else {
				backoff = 0
			}
			g.checkStatus(ctx) // a topic opened by this batch gets its status now
			select {
			case handled <- struct{}{}:
			case <-ctx.Done():
			}
		case <-inboxTick.C:
			if g.inboxHasWork() || time.Since(lastScan) >= gatewayInboxRescan {
				lastScan = time.Now()
				if err := g.scanInbox(ctx); err != nil && ctx.Err() == nil {
					g.log.Printf("inbox: %v", err)
				}
			}
		case <-statusTick.C:
			g.checkStatus(ctx)
		}
	}
	wg.Wait()
	flushCtx, cancel := context.WithTimeout(context.Background(), gatewayShutdownFlush)
	defer cancel()
	if left := g.flush(flushCtx); left > 0 {
		g.log.Printf("stopping with %d posts not sent (unacknowledged khala messages are posted again at the next start)", left)
	}
	if err := g.saveState(); err != nil {
		g.log.Printf("save state: %v", err)
	}
	g.log.Printf("stopped")
}

func (g *gateway) currentOffset() int64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.st.Offset
}

func (g *gateway) pollLoop(ctx context.Context, batches chan<- []inbound, handled <-chan struct{}) {
	backoff := time.Duration(0)
	for ctx.Err() == nil {
		batch, err := g.ad.Poll(ctx, g.currentOffset())
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			delay := retryAfter(err)
			if delay == 0 {
				backoff = nextBackoff(backoff)
				delay = backoff
			}
			g.log.Printf("poll failed: %v; next poll in %s", err, delay)
			_ = sleepContext(ctx, delay)
			continue
		}
		backoff = 0
		if len(batch) == 0 {
			continue
		}
		select {
		case batches <- batch:
		case <-ctx.Done():
			return
		}
		select {
		case <-handled:
		case <-ctx.Done():
			return
		}
	}
}

func (g *gateway) sendLoop(ctx context.Context) {
	for ctx.Err() == nil {
		item, ok := g.out.pop()
		if !ok {
			select {
			case <-g.out.notify:
			case <-ctx.Done():
			}
			continue
		}
		if ctx.Err() != nil {
			g.out.pushFront(item)
			return
		}
		g.deliver(ctx, item)
	}
}

// flush posts queued items in the caller's goroutine until the queue is empty
// or ctx ends; it returns the number of items left.
func (g *gateway) flush(ctx context.Context) int {
	for {
		item, ok := g.out.pop()
		if !ok {
			return 0
		}
		if ctx.Err() != nil {
			g.out.pushFront(item)
			return g.out.len()
		}
		g.deliver(ctx, item)
	}
}

// ------------------------------------------------------------ chat -> khala

func (g *gateway) pollOnce(ctx context.Context) error {
	batch, err := g.ad.Poll(ctx, g.currentOffset())
	if err != nil {
		return err
	}
	return g.handleBatch(ctx, batch)
}

// handleBatch processes updates in order. The stored offset passes an update
// only after it was handled; a failed khala send stops the batch so the same
// update is fetched again (the request ledger makes the retry idempotent).
func (g *gateway) handleBatch(ctx context.Context, batch []inbound) error {
	sort.SliceStable(batch, func(i, j int) bool { return batch[i].UpdateID < batch[j].UpdateID })
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, in := range batch {
		if in.UpdateID < g.st.Offset {
			continue
		}
		if err := g.handleInbound(ctx, in); err != nil {
			return fmt.Errorf("update %d: %w", in.UpdateID, err)
		}
		g.st.Offset = in.UpdateID + 1
		if err := g.saveLocked(); err != nil {
			return fmt.Errorf("save offset after update %d: %w", in.UpdateID, err)
		}
	}
	return nil
}

func isGeneralThread(thread int64) bool { return thread == 0 || thread == 1 }

func (g *gateway) handleInbound(ctx context.Context, in inbound) error {
	if in.Ignore {
		return nil
	}
	if !g.conf.allow[in.UserID] {
		now := g.now()
		if last, ok := g.denied[in.UserID]; !ok || now.Sub(last) >= time.Hour {
			g.denied[in.UserID] = now
			g.log.Printf("ignoring messages from user id %d: not in telegram allow", in.UserID)
		}
		return nil
	}
	if isGeneralThread(in.ThreadID) {
		if in.IsCommand || strings.HasPrefix(in.Text, "/") {
			g.command(ctx, in)
		}
		return nil
	}
	address, ok := g.st.topicFor(in.ThreadID)
	if !ok {
		g.reply(in, "This topic is not linked to a session. In General, use /open <name@node>.")
		return nil
	}
	if strings.TrimSpace(in.Text) == "" {
		g.reply(in, "Only text messages are relayed; this one was not sent.")
		return nil
	}
	id, err := g.sendAsUser(ctx, address, in)
	if err != nil {
		return err
	}
	g.st.Threads[id] = threadRef{Chat: g.conf.chat, Thread: in.ThreadID, MessageID: in.MessageID, UpdateID: in.UpdateID, At: g.now().Unix()}
	return nil
}

func messageSubject(text string) string {
	line, _, _ := strings.Cut(text, "\n")
	line = strings.TrimSpace(strings.ReplaceAll(line, "\r", ""))
	if utf8.RuneCountInString(line) > gatewaySubjectRunes {
		line = string([]rune(line)[:gatewaySubjectRunes])
	}
	return line
}

func (g *gateway) sendAsUser(ctx context.Context, address string, in inbound) (string, error) {
	args := []string{"send", address, "--request-id", "tg-" + strconv.FormatInt(in.UpdateID, 10), "-e", strconv.FormatInt(g.conf.userExpires, 10)}
	if subject := messageSubject(in.Text); subject != "" {
		args = append(args, "-s", subject)
	}
	out, err := g.khala(ctx, in.Text, args...)
	if err != nil {
		return "", err
	}
	id := lastLine(out)
	if !validMessageID(id) {
		return "", fmt.Errorf("khala send printed %q, not a message Id", id)
	}
	return id, nil
}

func lastLine(text string) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// khala runs the CLI as the reserved identity `user` of this node.
func (g *gateway) khala(ctx context.Context, stdin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, gatewayKhalaTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, g.conf.khalaBin, args...)
	cmd.Env = replaceEnv(os.Environ(), map[string]string{"KHALA_HOME": g.home, "KHALA_SESSION": gatewayUser})
	cmd.Dir = g.home
	cmd.Stdin = strings.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		reason := strings.TrimSpace(stderr.String())
		if len(reason) > 300 {
			reason = reason[:300]
		}
		return "", fmt.Errorf("khala %s failed: %v: %s", args[0], err, reason)
	}
	return stdout.String(), nil
}

func (g *gateway) reply(in inbound, text string) {
	thread := in.ThreadID
	if isGeneralThread(thread) {
		thread = 0
	}
	g.out.enqueue(outItem{thread: thread, text: text, replyTo: in.MessageID})
}

// ------------------------------------------------------------ General commands

const gatewayHelp = `Commands (General topic only):
/sessions — sessions in the cluster, their status and unread count
/open <name@node> — create a topic for that session
/close <name@node> — close its topic (messages in transit still arrive in khala)
/say <stream> <text> — post to a khala stream as user
/notices <name@node> off|urgent|all — record the notice preference (forwarding is not implemented yet)
/help — this list
Write in a session's topic to message that session; its replies appear there.`

func (g *gateway) command(ctx context.Context, in inbound) {
	text := strings.TrimSpace(in.Text)
	head, rest, _ := strings.Cut(text, " ")
	if i := strings.IndexAny(head, "\n"); i >= 0 {
		rest = head[i+1:] + " " + rest
		head = head[:i]
	}
	name, _, _ := strings.Cut(strings.TrimPrefix(head, "/"), "@")
	rest = strings.TrimSpace(rest)
	args := strings.Fields(rest)
	switch name {
	case "help", "start":
		g.reply(in, gatewayHelp)
	case "sessions":
		g.reply(in, g.sessionsText())
	case "open":
		g.cmdOpen(ctx, in, args)
	case "close":
		g.cmdClose(ctx, in, args)
	case "say":
		g.cmdSay(ctx, in, rest)
	case "notices":
		g.cmdNotices(in, args)
	default:
		g.reply(in, "Unknown command. Send /help for the list.")
	}
}

func validSessionAddress(address string) bool {
	name, node, ok := splitAddress(address)
	return ok && !isReservedIdentity(name) && name != gatewayUser && validNode(node)
}

func (g *gateway) cmdOpen(ctx context.Context, in inbound, args []string) {
	if len(args) != 1 || !validSessionAddress(args[0]) {
		g.reply(in, "Usage: /open <name@node> — a session address such as steno@b200.")
		return
	}
	address := args[0]
	if thread, ok := g.st.Topics[address]; ok {
		g.reply(in, fmt.Sprintf("%s is already open (topic %d).", address, thread))
		return
	}
	_, node, _ := splitAddress(address)
	if _, err := parseListenerSnapshot(filepath.Join(g.home, "presence", "conduit@"+node+".ear")); err != nil {
		g.reply(in, fmt.Sprintf("Node %s has no listener snapshot on this node; is it part of the cluster?", node))
		return
	}
	thread, err := g.createTopic(ctx, address)
	if err != nil {
		g.reply(in, fmt.Sprintf("Could not create a topic for %s: %v", address, err))
		return
	}
	g.reply(in, fmt.Sprintf("Opened a topic for %s.", address))
	_ = thread
}

func (g *gateway) createTopic(ctx context.Context, address string) (int64, error) {
	if err := g.limiter.wait(ctx); err != nil {
		return 0, err
	}
	thread, err := g.ad.CreateTopic(ctx, address)
	if err != nil {
		return 0, err
	}
	g.st.Topics[address] = thread
	delete(g.st.Status, address)
	if err := g.saveLocked(); err != nil {
		return 0, err
	}
	g.log.Printf("topic %d created for %s", thread, address)
	return thread, nil
}

func (g *gateway) cmdClose(ctx context.Context, in inbound, args []string) {
	if len(args) != 1 || !validSessionAddress(args[0]) {
		g.reply(in, "Usage: /close <name@node>")
		return
	}
	address := args[0]
	thread, ok := g.st.Topics[address]
	if !ok {
		g.reply(in, fmt.Sprintf("%s has no open topic.", address))
		return
	}
	var closeErr error
	if err := g.limiter.wait(ctx); err == nil {
		closeErr = g.ad.CloseTopic(ctx, thread)
	} else {
		closeErr = err
	}
	delete(g.st.Topics, address)
	delete(g.st.Status, address)
	delete(g.st.Notices, address)
	if err := g.saveLocked(); err != nil {
		g.log.Printf("save state: %v", err)
	}
	if closeErr != nil {
		g.reply(in, fmt.Sprintf("Forgot the topic of %s, but closing it failed: %v", address, closeErr))
		return
	}
	g.reply(in, fmt.Sprintf("Closed the topic of %s. Its replies will open a new topic.", address))
}

func (g *gateway) cmdSay(ctx context.Context, in inbound, rest string) {
	stream, text, _ := strings.Cut(rest, " ")
	if i := strings.IndexByte(stream, '\n'); i >= 0 {
		text = stream[i+1:] + " " + text
		stream = stream[:i]
	}
	text = strings.TrimSpace(text)
	if !validNode(stream) || text == "" {
		g.reply(in, "Usage: /say <stream> <text>")
		return
	}
	out, err := g.khala(ctx, "", "say", stream, "-m", text)
	if err != nil {
		g.reply(in, fmt.Sprintf("Could not say to %s: %v", stream, err))
		return
	}
	g.reply(in, fmt.Sprintf("said to %s (%s)", stream, lastLine(out)))
}

func (g *gateway) cmdNotices(in inbound, args []string) {
	if len(args) != 2 || !validSessionAddress(args[0]) || !oneOf(args[1], "off", "urgent", "all") {
		g.reply(in, "Usage: /notices <name@node> off|urgent|all")
		return
	}
	g.st.Notices[args[0]] = args[1]
	if err := g.saveLocked(); err != nil {
		g.log.Printf("save state: %v", err)
	}
	g.reply(in, fmt.Sprintf("notices for %s: %s (recorded; forwarding notices to Telegram is not implemented yet)", args[0], args[1]))
}

// ------------------------------------------------------------ status

type sessionView struct {
	address string
	status  string // connected | stalled | disconnected
	text    string
	unread  int
}

func readListenerSnapshots(home string) map[string]listenerSnapshot {
	result := map[string]listenerSnapshot{}
	entries, err := os.ReadDir(filepath.Join(home, "presence"))
	if err != nil {
		return result
	}
	for _, entry := range entries {
		node, ok := listenerSnapshotNode(entry.Name())
		if !ok || !entry.Type().IsRegular() {
			continue
		}
		snapshot, err := parseListenerSnapshot(filepath.Join(home, "presence", entry.Name()))
		if err == nil {
			result[node] = snapshot
		}
	}
	return result
}

// deriveStatus maps a listener snapshot to one of the three status words.
// ok is false when the snapshot cannot tell (a conduit stopping for a restart,
// or an identity cut from a truncated snapshot): no transition then.
func (g *gateway) deriveStatus(address string, snapshots map[string]listenerSnapshot, record *statusRecord) (sessionView, bool) {
	view := sessionView{address: address, status: "disconnected", text: "disconnected"}
	name, node, _ := splitAddress(address)
	now := g.now().Unix()
	snapshot, ok := snapshots[node]
	if !ok || now-snapshot.WrittenAt > gatewaySnapshotMaxAge {
		record.PendingSince = 0
		return view, true
	}
	if snapshot.State == "stopping" {
		return view, false
	}
	var identity *listenerIdentity
	for i := range snapshot.Identities {
		if snapshot.Identities[i].Name == name {
			identity = &snapshot.Identities[i]
		}
	}
	if identity == nil {
		record.PendingSince = 0
		return view, snapshot.Complete
	}
	view.unread = identity.PendingRing
	if identity.Route == "none" {
		return view, true
	}
	view.status, view.text = "connected", "connected"
	if identity.PendingRing == 0 {
		record.PendingSince = 0
		return view, true
	}
	since := identity.OldestPending
	if since == 0 {
		since = identity.FirstSeen
	}
	if since == 0 {
		if record.PendingSince == 0 {
			record.PendingSince = now
		}
		since = record.PendingSince
	}
	if age := now - since; age >= g.conf.stallAfter {
		view.status = "stalled"
		view.text = fmt.Sprintf("stalled: unread for %d min", age/60)
	}
	return view, true
}

func (g *gateway) checkStatus(ctx context.Context) {
	g.mu.Lock()
	defer g.mu.Unlock()
	snapshots := readListenerSnapshots(g.home)
	now := g.now().Unix()
	changed := false
	addresses := make([]string, 0, len(g.st.Topics))
	for address := range g.st.Topics {
		addresses = append(addresses, address)
	}
	sort.Strings(addresses)
	for _, address := range addresses {
		record := g.st.Status[address]
		before := record
		view, known := g.deriveStatus(address, snapshots, &record)
		if known && view.status != record.Kind && (record.At == 0 || now-record.At >= gatewayStatusSpacing) {
			g.out.enqueue(outItem{thread: g.st.Topics[address], text: view.text})
			record.Kind, record.At = view.status, now
		}
		if record != before {
			g.st.Status[address] = record
			changed = true
		}
	}
	if changed {
		if err := g.saveLocked(); err != nil {
			g.log.Printf("save state: %v", err)
		}
	}
}

func (g *gateway) sessionsText() string {
	snapshots := readListenerSnapshots(g.home)
	seen := map[string]bool{}
	for node, snapshot := range snapshots {
		for _, identity := range snapshot.Identities {
			if identity.Principal == "session" && !isReservedIdentity(identity.Name) && identity.Name != gatewayUser {
				seen[identity.Name+"@"+node] = true
			}
		}
	}
	for address := range g.st.Topics {
		seen[address] = true
	}
	addresses := make([]string, 0, len(seen))
	for address := range seen {
		addresses = append(addresses, address)
	}
	sort.Strings(addresses)
	if len(addresses) == 0 {
		return "No sessions in the cluster's listener snapshots."
	}
	var b strings.Builder
	for _, address := range addresses {
		record := g.st.Status[address]
		view, _ := g.deriveStatus(address, snapshots, &record)
		mark := ""
		if _, ok := g.st.Topics[address]; ok {
			mark = " [topic]"
		}
		fmt.Fprintf(&b, "%s — %s (%d unread)%s\n", address, view.text, view.unread, mark)
	}
	return strings.TrimRight(b.String(), "\n")
}

// ------------------------------------------------------------ khala -> chat

// inboxHasWork is the cheap trigger for scanInbox: an unread file whose post
// is not already queued.
func (g *gateway) inboxHasWork() bool {
	entries, err := os.ReadDir(filepath.Join(g.home, "inbox", gatewayUser, "new"))
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if entry.Type().IsRegular() && !g.out.isInflight(entry.Name()) {
			return true
		}
	}
	return false
}

// scanInbox relays every unread message of `user` to its sender's topic via
// the non-destructive pull API; the message is acknowledged (ack-read) only
// after the post succeeded.
func (g *gateway) scanInbox(ctx context.Context) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	out, err := g.khala(ctx, "", "inbox", "list")
	if err != nil {
		return err
	}
	for _, line := range strings.Split(out, "\n") {
		id, _, _ := strings.Cut(line, "\t")
		if !validMessageID(id) || g.out.isInflight(id) {
			continue
		}
		if _, err := os.Lstat(filepath.Join(g.home, "inbox", gatewayUser, "new", id)); err != nil {
			continue // already read
		}
		if err := g.relayMessage(ctx, id); err != nil {
			g.log.Printf("relay %s: %v", id, err)
		}
	}
	return nil
}

func (g *gateway) relayMessage(ctx context.Context, id string) error {
	raw, err := g.khala(ctx, "", "inbox", "read", id)
	if err != nil {
		return err
	}
	if len(raw) > gatewayMaxMessageBytes {
		raw = raw[:gatewayMaxMessageBytes]
	}
	headers, body := parseHeaderBody([]byte(raw))
	body = strings.TrimRight(body, "\n")
	switch headers["Type"] {
	case "message", "operator":
		from := headers["From"]
		if _, _, ok := splitAddress(from); !ok {
			return fmt.Errorf("invalid From %q", from)
		}
		thread, ok := g.st.Topics[from]
		if !ok {
			if thread, err = g.createTopic(ctx, from); err != nil {
				return fmt.Errorf("create topic for %s: %w", from, err)
			}
		}
		var replyTo int64
		if ref, ok := g.st.Threads[headers["In-Reply-To"]]; ok && ref.Thread == thread {
			replyTo = ref.MessageID
		}
		text := body
		if subject := headers["Subject"]; subject != "" {
			text = "[" + subject + "]\n" + body
		}
		name, _, _ := splitAddress(from)
		g.out.enqueue(outItem{thread: thread, text: text, replyTo: replyTo, ackID: id, docName: fmt.Sprintf("%s-%s.md", name, strings.SplitN(id, ".", 2)[0])})
	case "bounce":
		reason, _, _ := strings.Cut(strings.TrimSpace(body), "\n")
		if reason == "" {
			reason = "expired"
		}
		var thread, replyTo int64
		if ref, ok := g.st.Threads[headers["Refs"]]; ok {
			thread, replyTo = ref.Thread, ref.MessageID
		}
		g.out.enqueue(outItem{thread: thread, text: "not delivered: " + reason, replyTo: replyTo, ackID: id})
	default:
		// Notices and other types addressed to user are acknowledged without a
		// post: forwarding notices is not part of this version (docs/GATEWAY.md).
		g.log.Printf("%s: type %q from %s is not relayed; marking read", id, headers["Type"], headers["From"])
		if _, err := g.khala(ctx, "", "inbox", "ack-read", id); err != nil {
			return err
		}
	}
	return nil
}

func (g *gateway) forgetThread(thread int64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if address, ok := g.st.topicFor(thread); ok {
		delete(g.st.Topics, address)
		delete(g.st.Status, address)
		if err := g.saveLocked(); err != nil {
			g.log.Printf("save state: %v", err)
		}
		g.log.Printf("topic %d of %s no longer exists; the next message opens a new one", thread, address)
	}
}

// deliver posts one item: as is up to 4096 UTF-16 units, as up to
// chunk-limit line-split messages, or as one .md document beyond that.
func (g *gateway) deliver(ctx context.Context, item outItem) {
	err := g.post(ctx, item)
	if err != nil {
		lower := strings.ToLower(err.Error())
		if isPermanent(err) && item.thread != 0 && (strings.Contains(lower, "thread not found") || strings.Contains(lower, "topic_closed") || strings.Contains(lower, "topic_deleted")) {
			g.forgetThread(item.thread)
		}
		g.log.Printf("post to topic %d failed: %v", item.thread, err)
		g.out.hold(item.ackID, time.Now().Add(gatewayInboxRescan))
		g.out.done(item.ackID)
		return
	}
	if item.ackID != "" {
		if _, err := g.khala(ctx, "", "inbox", "ack-read", item.ackID); err != nil {
			g.log.Printf("ack-read %s after posting: %v (it may be posted again)", item.ackID, err)
		}
		g.out.done(item.ackID)
	}
}

func (g *gateway) post(ctx context.Context, item outItem) error {
	text := item.text
	if strings.TrimSpace(text) == "" {
		text = "(empty message)"
	}
	if utf16Len(text) <= gatewayTextLimit {
		if err := g.limiter.wait(ctx); err != nil {
			return err
		}
		_, err := g.ad.Post(ctx, item.thread, text, item.replyTo)
		return err
	}
	chunks := splitMessage(text, gatewayTextLimit)
	if len(chunks) > g.conf.chunkLimit {
		name := item.docName
		if name == "" {
			name = "message.md"
		}
		caption := text
		if utf8.RuneCountInString(caption) > gatewayCaptionRunes {
			caption = string([]rune(caption)[:gatewayCaptionRunes])
		}
		if err := g.limiter.wait(ctx); err != nil {
			return err
		}
		_, err := g.ad.PostDocument(ctx, item.thread, name, []byte(text), caption)
		return err
	}
	for i, chunk := range chunks {
		replyTo := int64(0)
		if i == 0 {
			replyTo = item.replyTo
		}
		if err := g.limiter.wait(ctx); err != nil {
			return err
		}
		if _, err := g.ad.Post(ctx, item.thread, chunk, replyTo); err != nil {
			return fmt.Errorf("chunk %d/%d: %w", i+1, len(chunks), err)
		}
	}
	return nil
}

func utf16Len(text string) int {
	n := 0
	for _, r := range text {
		n += utf16.RuneLen(r)
	}
	return n
}

// splitMessage cuts text into pieces of at most limit UTF-16 units, at line
// boundaries when possible (the newline between two pieces is dropped) and at
// rune boundaries inside an over-long line (nothing dropped).
func splitMessage(text string, limit int) []string {
	if utf16Len(text) <= limit {
		return []string{text}
	}
	var chunks []string
	var current strings.Builder
	currentUnits := 0
	emit := func() {
		chunks = append(chunks, current.String())
		current.Reset()
		currentUnits = 0
	}
	for i, line := range strings.Split(text, "\n") {
		units := utf16Len(line)
		switch {
		case i == 0:
		case currentUnits+1+units <= limit:
			current.WriteByte('\n')
			currentUnits++
		default:
			emit()
		}
		if currentUnits+units <= limit {
			current.WriteString(line)
			currentUnits += units
			continue
		}
		for _, r := range line {
			size := utf16.RuneLen(r)
			if currentUnits+size > limit {
				emit()
			}
			current.WriteRune(r)
			currentUnits += size
		}
	}
	emit()
	return chunks
}

// ------------------------------------------------------------ state

func (g *gateway) saveLocked() error {
	g.st.prune(g.now().Unix())
	return saveGatewayState(g.home, g.st)
}

func (g *gateway) saveState() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.saveLocked()
}
