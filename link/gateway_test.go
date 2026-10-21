package main

import (
	"bytes"
	"context"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// khalaBinary is the worktree's CLI, used as the gateway's `khala bin`.
func khalaBinary(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "bin", "khala"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("khala CLI not found: %v", err)
	}
	return path
}

// gatewayNode creates a fresh single-node KHALA_HOME with `khala init <node>`.
func gatewayNode(t *testing.T, node string) string {
	t.Helper()
	home := filepath.Join(t.TempDir(), "node")
	khalaCmd(t, home, "", "", "init", node)
	return home
}

func khalaCmd(t *testing.T, home, session, stdin string, args ...string) string {
	t.Helper()
	cmd := exec.Command(khalaBinary(t), args...)
	values := map[string]string{"KHALA_HOME": home}
	if session != "" {
		values["KHALA_SESSION"] = session
	}
	cmd.Env = replaceEnv(os.Environ(), values)
	cmd.Dir = filepath.Dir(home)
	cmd.Stdin = strings.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("khala %v: %v\n%s", args, err, stderr.String())
	}
	return strings.TrimSpace(stdout.String())
}

func writeGatewayConf(t *testing.T, home, body string, mode os.FileMode) {
	t.Helper()
	path := filepath.Join(home, "gateway.conf")
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func fakeConf(t *testing.T) string {
	return "# test\nadapter fake\ntelegram allow 1\nkhala bin " + khalaBinary(t) + "\n"
}

type testGateway struct {
	*gateway
	fake  *fakeAdapter
	clock time.Time
	logs  *bytes.Buffer
}

func newTestGateway(t *testing.T, home string, extraConf string) *testGateway {
	t.Helper()
	writeGatewayConf(t, home, fakeConf(t)+extraConf, 0600)
	conf, err := loadGatewayConf(home)
	if err != nil {
		t.Fatalf("loadGatewayConf: %v", err)
	}
	logs := &bytes.Buffer{}
	fake := newFakeAdapter("")
	g, err := newGateway(home, conf, fake, log.New(logs, "", 0))
	if err != nil {
		t.Fatalf("newGateway: %v", err)
	}
	tg := &testGateway{gateway: g, fake: fake, clock: time.Unix(1790000000, 0), logs: logs}
	g.now = func() time.Time { return tg.clock }
	return tg
}

func (tg *testGateway) flushT(t *testing.T) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if left := tg.flush(ctx); left != 0 {
		t.Fatalf("flush left %d items", left)
	}
}

func listFiles(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		if entry.Type().IsRegular() {
			names = append(names, entry.Name())
		}
	}
	return names
}

// ---------------------------------------------------------------- P1

func TestGatewayP1ConfValidation(t *testing.T) {
	home := gatewayNode(t, "gw")
	run := func() (int, string) {
		oldStderr := os.Stderr
		r, w, _ := os.Pipe()
		os.Stderr = w
		code := runGateway([]string{"--home", home, "--once"})
		w.Close()
		os.Stderr = oldStderr
		out, _ := io.ReadAll(r)
		return code, string(out)
	}
	if code, out := run(); code != 2 || !strings.Contains(out, "gateway.conf") {
		t.Fatalf("absent conf: code=%d out=%q", code, out)
	}
	writeGatewayConf(t, home, fakeConf(t), 0644)
	if code, out := run(); code != 2 || !strings.Contains(out, "0644") {
		t.Fatalf("0644 conf: code=%d out=%q", code, out)
	}
	writeGatewayConf(t, home, fakeConf(t)+"colour blue\n", 0600)
	if code, out := run(); code != 2 || !strings.Contains(out, "unknown key") {
		t.Fatalf("unknown key: code=%d out=%q", code, out)
	}
	for _, bad := range []string{"stall-after x\n", "notices forward loud\n", "telegram chunk-limit 0\n", "user expires 9999999\n", "adapter fake\n"} {
		writeGatewayConf(t, home, fakeConf(t)+bad, 0600)
		if code, out := run(); code != 2 {
			t.Fatalf("malformed %q: code=%d out=%q", bad, code, out)
		}
	}
	writeGatewayConf(t, home, "adapter telegram\nkhala bin "+khalaBinary(t)+"\ntelegram chat -100\n", 0600)
	if code, out := run(); code != 2 || !strings.Contains(out, "token") {
		t.Fatalf("telegram without token: code=%d out=%q", code, out)
	}
	writeGatewayConf(t, home, fakeConf(t), 0600)
	if code, out := run(); code != 0 || !strings.Contains(out, "gateway: connected as @fake") {
		t.Fatalf("valid conf: code=%d out=%q", code, out)
	}
	logData, err := os.ReadFile(filepath.Join(home, "log", "gateway.log"))
	if err != nil || !strings.Contains(string(logData), "gateway: connected as @fake chat=0 topics=0") {
		t.Fatalf("startup line missing from log/gateway.log: %v %q", err, logData)
	}
}

func TestGatewaySingleInstance(t *testing.T) {
	home := gatewayNode(t, "gw")
	lock, ok, err := acquireGatewayLock(home)
	if err != nil || !ok {
		t.Fatalf("first lock: ok=%v err=%v", ok, err)
	}
	defer lock.Close()
	if _, ok, err := acquireGatewayLock(home); err != nil || ok {
		t.Fatalf("second lock must be refused: ok=%v err=%v", ok, err)
	}
	pid, _ := os.ReadFile(filepath.Join(home, "run", "gateway.pid"))
	if !strings.HasPrefix(string(pid), "pid ") || !strings.Contains(string(pid), "start ") {
		t.Fatalf("gateway.pid = %q", pid)
	}
}

// ---------------------------------------------------------------- P2

func TestGatewayP2InboundTopicMessageBecomesKhalaMessage(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	tg.st.Topics["alpha@gw"] = 77
	text := strings.Repeat("가", 100) + "\nsecond line\nthird"
	tg.fake.push(inbound{UpdateID: 500, ThreadID: 77, MessageID: 9001, UserID: 1, Text: text})
	if err := tg.pollOnce(context.Background()); err != nil {
		t.Fatalf("pollOnce: %v", err)
	}
	if tg.st.Offset != 501 {
		t.Fatalf("offset = %d, want 501", tg.st.Offset)
	}
	queued := listFiles(t, filepath.Join(home, "outbox", "new"))
	if len(queued) != 1 {
		t.Fatalf("outbox/new = %v, want 1 message", queued)
	}
	id := queued[0]
	data, err := os.ReadFile(filepath.Join(home, "outbox", "new", id))
	if err != nil {
		t.Fatal(err)
	}
	headers, body := parseHeaderBody(data)
	if headers["From"] != "user@gw" || headers["To"] != "alpha@gw" || headers["Type"] != "message" {
		t.Fatalf("headers = %v", headers)
	}
	if want := strings.Repeat("가", 80); headers["Subject"] != want {
		t.Fatalf("subject = %q (%d runes), want 80 runes", headers["Subject"], utf8.RuneCountInString(headers["Subject"]))
	}
	if strings.TrimRight(body, "\n") != text {
		t.Fatalf("body = %q", body)
	}
	if _, err := os.Stat(filepath.Join(home, "requests", "send", "user", "tg-500")); err != nil {
		t.Fatalf("request ledger tg-500 missing: %v", err)
	}
	ref, ok := tg.st.Threads[id]
	if !ok || ref.Thread != 77 || ref.MessageID != 9001 || ref.UpdateID != 500 {
		t.Fatalf("threads[%s] = %+v ok=%v", id, ref, ok)
	}
	// State is durable.
	reloaded, err := loadGatewayState(home)
	if err != nil || reloaded.Offset != 501 || reloaded.Threads[id].MessageID != 9001 {
		t.Fatalf("reloaded state = %+v err=%v", reloaded, err)
	}
	info, err := os.Stat(filepath.Join(home, "gateway.state.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("state file mode: %v %v", info, err)
	}

	// Same update again (Telegram redelivery after a crash before offset save).
	tg.st.Offset = 500
	tg.fake.push(inbound{UpdateID: 500, ThreadID: 77, MessageID: 9001, UserID: 1, Text: text})
	if err := tg.pollOnce(context.Background()); err != nil {
		t.Fatalf("pollOnce replay: %v", err)
	}
	if queued := listFiles(t, filepath.Join(home, "outbox", "new")); len(queued) != 1 {
		t.Fatalf("replay produced a second message: %v", queued)
	}
	if tg.st.Offset != 501 {
		t.Fatalf("offset after replay = %d", tg.st.Offset)
	}
}

func TestGatewayP2UnmappedTopicAndNonText(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	tg.st.Topics["alpha@gw"] = 77
	tg.fake.push(inbound{UpdateID: 10, ThreadID: 55, MessageID: 1, UserID: 1, Text: "hello?"})
	tg.fake.push(inbound{UpdateID: 11, ThreadID: 77, MessageID: 2, UserID: 1, Text: ""})
	if err := tg.pollOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	if tg.st.Offset != 12 || len(listFiles(t, filepath.Join(home, "outbox", "new"))) != 0 {
		t.Fatalf("offset=%d outbox=%v", tg.st.Offset, listFiles(t, filepath.Join(home, "outbox", "new")))
	}
	posts := tg.fake.outputs()
	if len(posts) != 2 || !strings.Contains(posts[0].Text, "/open") || posts[0].ReplyTo != 1 || !strings.Contains(posts[1].Text, "text") {
		t.Fatalf("posts = %+v", posts)
	}
}

// ---------------------------------------------------------------- P3

func TestGatewayP3SessionReplyPostedToTopicAndAcked(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	// First contact: alpha writes to the user without any topic.
	first := khalaCmd(t, home, "alpha", "hello user\nline two", "send", "user@gw", "-s", "status")
	khalaCmd(t, home, "", "", "reconcile")
	if err := tg.scanInbox(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	out := tg.fake.outputs()
	if len(out) != 2 || out[0].Method != "createTopic" || out[0].Name != "alpha@gw" || out[1].Method != "post" || out[1].Thread != out[0].Thread {
		t.Fatalf("outputs = %+v", out)
	}
	if !strings.Contains(out[1].Text, "hello user\nline two") || !strings.Contains(out[1].Text, "status") || out[1].ReplyTo != 0 {
		t.Fatalf("post = %+v", out[1])
	}
	if tg.st.Topics["alpha@gw"] != out[0].Thread {
		t.Fatalf("topic not recorded: %v", tg.st.Topics)
	}
	if _, err := os.Stat(filepath.Join(home, "inbox", "user", "cur", first)); err != nil {
		t.Fatalf("message not acked to cur: %v", err)
	}
	if len(listFiles(t, filepath.Join(home, "inbox", "user", "new"))) != 0 {
		t.Fatal("inbox/user/new not empty")
	}
	// A rescan does not repost.
	if err := tg.scanInbox(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	if n := len(tg.fake.outputs()); n != 2 {
		t.Fatalf("rescan reposted: %d outputs", n)
	}

	// Threaded reply: the user wrote via the gateway, alpha answers with --reply-to.
	thread := tg.st.Topics["alpha@gw"]
	tg.fake.push(inbound{UpdateID: 7, ThreadID: thread, MessageID: 4242, UserID: 1, Text: "please check GPU 2"})
	if err := tg.pollOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	userID := listFiles(t, filepath.Join(home, "outbox", "new"))
	if len(userID) != 1 {
		t.Fatalf("user message not queued: %v", userID)
	}
	khalaCmd(t, home, "", "", "reconcile")
	khalaCmd(t, home, "alpha", "GPU 2 is fine", "send", "user@gw", "--reply-to", userID[0], "-s", "re: GPU")
	khalaCmd(t, home, "", "", "reconcile")
	if err := tg.scanInbox(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	out = tg.fake.outputs()
	last := out[len(out)-1]
	if last.Method != "post" || last.Thread != thread || last.ReplyTo != 4242 || !strings.Contains(last.Text, "GPU 2 is fine") {
		t.Fatalf("threaded reply = %+v", last)
	}
}

func TestGatewayP3BounceRepliesToOriginal(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	tg.st.Topics["alpha@far"] = 31
	ref := "1790000000.1.2.user@gw"
	tg.st.Threads[ref] = threadRef{Chat: 0, Thread: 31, MessageID: 808, UpdateID: 3, At: tg.clock.Unix()}
	bounceID := "1790000001.1.3.khala@gw"
	bounce := "Khala: 0.1\nId: " + bounceID + "\nFrom: khala@gw\nTo: user@gw\nDate: 2026-09-23T00:00:00Z\nType: bounce\nRefs: " + ref + "\nExpires: 1799999999\n\nDelivery expired for alpha@far\n"
	dir := filepath.Join(home, "inbox", "user", "new")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, bounceID), []byte(bounce), 0600); err != nil {
		t.Fatal(err)
	}
	if err := tg.scanInbox(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	out := tg.fake.outputs()
	if len(out) != 1 || out[0].Thread != 31 || out[0].ReplyTo != 808 || !strings.HasPrefix(out[0].Text, "not delivered: Delivery expired for alpha@far") {
		t.Fatalf("bounce post = %+v", out)
	}
	if _, err := os.Stat(filepath.Join(home, "inbox", "user", "cur", bounceID)); err != nil {
		t.Fatalf("bounce not acked: %v", err)
	}
}

// ---------------------------------------------------------------- P4

func TestGatewayP4Chunking(t *testing.T) {
	if n := utf16Len("가😀a"); n != 4 {
		t.Fatalf("utf16Len = %d, want 4", n)
	}
	// 5000 Korean characters over 50 lines -> 2 chunks, each <= 4096 units, lossless.
	var lines []string
	for i := 0; i < 50; i++ {
		lines = append(lines, strings.Repeat("한", 99))
	}
	text := strings.Join(lines, "\n")
	chunks := splitMessage(text, 4096)
	if len(chunks) != 2 || strings.Join(chunks, "\n") != text {
		t.Fatalf("5000 chars -> %d chunks", len(chunks))
	}
	for _, chunk := range chunks {
		if utf16Len(chunk) > 4096 {
			t.Fatalf("chunk has %d units", utf16Len(chunk))
		}
	}
	// Emoji boundary: 2047 emoji = 4094 units + "ab" = 4096 fits; one more unit splits,
	// and no surrogate pair is broken.
	fits := strings.Repeat("😀", 2047) + "ab"
	if got := splitMessage(fits, 4096); len(got) != 1 {
		t.Fatalf("4096-unit text split into %d", len(got))
	}
	over := strings.Repeat("😀", 2048) + "a"
	got := splitMessage(over, 4096)
	if len(got) != 2 || strings.Join(got, "") != over {
		t.Fatalf("4097-unit text: %d chunks", len(got))
	}
	for _, chunk := range got {
		if !utf8.ValidString(chunk) || utf16Len(chunk) > 4096 {
			t.Fatalf("broken chunk: valid=%v units=%d", utf8.ValidString(chunk), utf16Len(chunk))
		}
	}

	// Through the sender: 5000 Korean chars -> 2 posts; 20000 chars -> 1 document.
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "telegram chunk-limit 3\n")
	tg.out.enqueue(outItem{thread: 5, text: text, replyTo: 99})
	tg.flushT(t)
	out := tg.fake.outputs()
	if len(out) != 2 || out[0].ReplyTo != 99 || out[1].ReplyTo != 0 {
		t.Fatalf("5000-char posts = %d (%+v)", len(out), out)
	}
	long := strings.Repeat(strings.Repeat("x", 199)+"\n", 100)
	tg.out.enqueue(outItem{thread: 5, text: long, docName: "reply.md"})
	tg.flushT(t)
	out = tg.fake.outputs()[2:]
	if len(out) != 1 || out[0].Method != "document" || out[0].Name != "reply.md" || string(out[0].Data) != long || utf8.RuneCountInString(out[0].Caption) != 300 {
		t.Fatalf("20000-char document = %+v", out)
	}
}

func TestGatewayRateLimiter(t *testing.T) {
	now := time.Unix(1000, 0)
	var slept time.Duration
	limiter := &rateLimiter{limit: 20, window: time.Minute, now: func() time.Time { return now }, sleep: func(ctx context.Context, d time.Duration) error {
		slept += d
		now = now.Add(d)
		return nil
	}}
	var stamps []time.Time
	for i := 0; i < 50; i++ {
		if err := limiter.wait(context.Background()); err != nil {
			t.Fatal(err)
		}
		stamps = append(stamps, now)
		now = now.Add(100 * time.Millisecond)
	}
	for i := range stamps {
		count := 0
		for j := i; j < len(stamps) && stamps[j].Sub(stamps[i]) < time.Minute; j++ {
			count++
		}
		if count > 20 {
			t.Fatalf("%d posts inside one minute starting at %d", count, i)
		}
	}
}

// ---------------------------------------------------------------- P5

func writeEar(t *testing.T, home, node string, writtenAt int64, identities ...listenerIdentity) {
	t.Helper()
	data, err := formatListenerSnapshot(listenerSnapshot{Node: node, Generation: writtenAt, WrittenAt: writtenAt, Interval: 60, State: "running", Components: []listenerComponent{{Name: "conduit", Release: linkVersion, Adapter: "1", Ears: "1"}}, Mailboxes: []string{node}, LinkAge: -1, Identities: identities})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "presence", "conduit@"+node+".ear"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func listening(name string) listenerIdentity {
	return listenerIdentity{Name: name, Principal: "session", Listening: true, Route: "socket", Phase: "ready", CCVersion: "2.1.260", Reason: "-", Generation: "-", LastDrainBefore: "-", LastDrainAfter: "-", LastDrainStatus: "-"}
}

func TestGatewayP5StatusPosts(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	tg.st.Topics["alpha@gw"] = 40
	posts := func() []fakeOut {
		tg.flushT(t)
		return tg.fake.outputs()
	}
	t0 := tg.clock.Unix()
	writeEar(t, home, "gw", t0, listening("alpha"))
	tg.checkStatus(context.Background())
	if out := posts(); len(out) != 1 || out[0].Thread != 40 || out[0].Text != "connected" {
		t.Fatalf("connected: %+v", out)
	}
	// Unchanged -> no repeat.
	tg.clock = tg.clock.Add(10 * time.Minute)
	writeEar(t, home, "gw", tg.clock.Unix(), listening("alpha"))
	tg.checkStatus(context.Background())
	if out := posts(); len(out) != 1 {
		t.Fatalf("unchanged status reposted: %+v", out)
	}
	// Pending for 15 minutes (oldest-pending absent -> ear first-seen used).
	pending := listening("alpha")
	pending.PendingRing = 1
	pending.FirstSeen = tg.clock.Unix() - 900
	writeEar(t, home, "gw", tg.clock.Unix(), pending)
	tg.checkStatus(context.Background())
	if out := posts(); len(out) != 2 || out[1].Text != "stalled: unread for 15 min" {
		t.Fatalf("stalled: %+v", out)
	}
	// Still stalled a minute later -> no repeat.
	tg.clock = tg.clock.Add(time.Minute)
	writeEar(t, home, "gw", tg.clock.Unix(), pending)
	tg.checkStatus(context.Background())
	if out := posts(); len(out) != 2 {
		t.Fatalf("stalled reposted: %+v", out)
	}
	// Snapshot removed -> disconnected, but only after the 5-minute spacing.
	if err := os.Remove(filepath.Join(home, "presence", "conduit@gw.ear")); err != nil {
		t.Fatal(err)
	}
	tg.checkStatus(context.Background())
	if out := posts(); len(out) != 2 {
		t.Fatalf("posted inside the 5-minute spacing: %+v", out)
	}
	tg.clock = tg.clock.Add(5 * time.Minute)
	tg.checkStatus(context.Background())
	if out := posts(); len(out) != 3 || out[2].Text != "disconnected" {
		t.Fatalf("disconnected: %+v", out)
	}
	// A stale snapshot that still lists the session is disconnected too.
	tg.clock = tg.clock.Add(10 * time.Minute)
	writeEar(t, home, "gw", tg.clock.Unix(), listening("alpha"))
	tg.checkStatus(context.Background())
	tg.clock = tg.clock.Add(11 * time.Minute)
	tg.checkStatus(context.Background())
	out := posts()
	if len(out) != 5 || out[3].Text != "connected" || out[4].Text != "disconnected" {
		t.Fatalf("stale sequence: %+v", out)
	}
	if got := tg.st.Status["alpha@gw"].Kind; got != "disconnected" {
		t.Fatalf("status state = %q", got)
	}
}

// ---------------------------------------------------------------- P6

func TestGatewayP6GeneralCommands(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	pending := listening("beta")
	pending.PendingRing = 2
	writeEar(t, home, "gw", tg.clock.Unix(), listening("alpha"), pending)
	general := func(update int64, text string) fakeOut {
		t.Helper()
		before := len(tg.fake.outputs())
		tg.fake.push(inbound{UpdateID: update, ThreadID: 0, MessageID: update * 10, UserID: 1, Text: text, IsCommand: strings.HasPrefix(text, "/")})
		if err := tg.pollOnce(context.Background()); err != nil {
			t.Fatal(err)
		}
		tg.flushT(t)
		if tg.st.Offset != update+1 {
			t.Fatalf("offset after %q = %d", text, tg.st.Offset)
		}
		out := tg.fake.outputs()
		if len(out) == before {
			return fakeOut{}
		}
		return out[len(out)-1]
	}
	if got := general(1, "/sessions"); !strings.Contains(got.Text, "alpha@gw — connected (0 unread)") || !strings.Contains(got.Text, "beta@gw — connected (2 unread)") || got.ReplyTo != 10 {
		t.Fatalf("/sessions = %+v", got)
	}
	if got := general(2, "/open bad"); !strings.Contains(got.Text, "name@node") {
		t.Fatalf("/open bad = %+v", got)
	}
	if got := general(3, "/open alpha@nowhere"); !strings.Contains(got.Text, "no listener snapshot") {
		t.Fatalf("/open unknown node = %+v", got)
	}
	before := len(tg.fake.outputs())
	general(4, "/open@khala_bot alpha@gw")
	out := tg.fake.outputs()[before:]
	if len(out) < 2 || out[0].Method != "createTopic" || out[0].Name != "alpha@gw" {
		t.Fatalf("/open outputs = %+v", out)
	}
	reloaded, _ := loadGatewayState(home)
	if reloaded.Topics["alpha@gw"] != out[0].Thread {
		t.Fatalf("mapping not saved: %v", reloaded.Topics)
	}
	if got := general(5, "/open alpha@gw"); !strings.Contains(got.Text, "already open") {
		t.Fatalf("/open twice = %+v", got)
	}
	if got := general(6, "/notices alpha@gw urgent"); !strings.Contains(got.Text, "urgent") || tg.st.Notices["alpha@gw"] != "urgent" {
		t.Fatalf("/notices = %+v state=%v", got, tg.st.Notices)
	}
	if got := general(7, "/say general hello from the phone"); !strings.Contains(got.Text, "said") {
		t.Fatalf("/say = %+v", got)
	}
	entries := listFiles(t, filepath.Join(home, "streams", "general", "gw"))
	if len(entries) != 1 || !strings.HasSuffix(entries[0], ".user@gw") {
		t.Fatalf("stream entries = %v", entries)
	}
	data, _ := os.ReadFile(filepath.Join(home, "streams", "general", "gw", entries[0]))
	if !strings.Contains(string(data), "hello from the phone") {
		t.Fatalf("stream entry = %q", data)
	}
	thread := tg.st.Topics["alpha@gw"]
	before = len(tg.fake.outputs())
	general(8, "/close alpha@gw")
	out = tg.fake.outputs()[before:]
	if len(out) < 1 || out[0].Method != "closeTopic" || out[0].Thread != thread {
		t.Fatalf("/close outputs = %+v", out)
	}
	if _, ok := tg.st.Topics["alpha@gw"]; ok {
		t.Fatal("mapping kept after /close")
	}
	if got := general(9, "good morning"); got.Method != "" {
		t.Fatalf("plain text in General produced %+v", got)
	}
	if got := general(10, "/help"); !strings.Contains(got.Text, "/open") {
		t.Fatalf("/help = %+v", got)
	}
	if got := general(11, "/frobnicate"); !strings.Contains(got.Text, "/help") {
		t.Fatalf("unknown command = %+v", got)
	}
	// General may also be reported as thread 1.
	if got := general(12, "/help"); got.Method == "" {
		t.Fatal("no /help reply")
	}
	tg.fake.push(inbound{UpdateID: 13, ThreadID: 1, MessageID: 130, UserID: 1, Text: "/help", IsCommand: true})
	if err := tg.pollOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	if last := tg.fake.outputs()[len(tg.fake.outputs())-1]; last.ReplyTo != 130 || !strings.Contains(last.Text, "/open") {
		t.Fatalf("/help in thread 1 = %+v", last)
	}
}

func TestGatewayStatePrunesOldThreads(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	now := tg.clock.Unix()
	tg.st.Threads["old"] = threadRef{At: now - 8*86400}
	tg.st.Threads["new"] = threadRef{At: now - 86400}
	if err := tg.saveState(); err != nil {
		t.Fatal(err)
	}
	if _, ok := tg.st.Threads["old"]; ok {
		t.Fatal("old thread entry not pruned")
	}
	if _, ok := tg.st.Threads["new"]; !ok {
		t.Fatal("recent thread entry pruned")
	}
}

type failingPoster struct{ *fakeAdapter }

func (f failingPoster) Post(context.Context, int64, string, int64) (int64, error) {
	return 0, &telegramError{method: "sendMessage", status: 400, desc: "Bad Request: message thread not found"}
}

func TestGatewayFailedPostIsHeldAndTopicForgotten(t *testing.T) {
	home := gatewayNode(t, "gw")
	tg := newTestGateway(t, home, "")
	tg.ad = failingPoster{tg.fake}
	tg.st.Topics["alpha@gw"] = 40
	id := khalaCmd(t, home, "alpha", "hello", "send", "user@gw")
	khalaCmd(t, home, "", "", "reconcile")
	if err := tg.scanInbox(context.Background()); err != nil {
		t.Fatal(err)
	}
	tg.flushT(t)
	if _, ok := tg.st.Topics["alpha@gw"]; ok {
		t.Fatal("topic mapping kept after thread not found")
	}
	if _, err := os.Stat(filepath.Join(home, "inbox", "user", "new", id)); err != nil {
		t.Fatalf("failed post must leave the message unread: %v", err)
	}
	if tg.inboxHasWork() {
		t.Fatal("failed Id is not held; the 1 s inbox tick would retry it at once")
	}
}
