package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeClock is the injectable clock for budget, error-retry and conf-reload windows.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type jevRequest struct {
	header http.Header
	body   []byte
}

// fakeJev answers by the letter subject: nouls[subject] = {needs_action, awaits_reply, time_sensitive}.
type fakeJev struct {
	mu       sync.Mutex
	requests []jevRequest
	nouls    map[string][3]float64
	statuses []int // consumed one per request; 0 or exhausted = 200
	delay    time.Duration
	server   *httptest.Server
}

func newFakeJev(t *testing.T) *fakeJev {
	j := &fakeJev{nouls: make(map[string][3]float64)}
	j.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		j.mu.Lock()
		j.requests = append(j.requests, jevRequest{header: r.Header.Clone(), body: body})
		status := 200
		if len(j.statuses) > 0 {
			status = j.statuses[0]
			j.statuses = j.statuses[1:]
		}
		delay := j.delay
		j.mu.Unlock()
		if delay > 0 {
			time.Sleep(delay)
		}
		if status != 200 {
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"error":"test"}`))
			return
		}
		var req struct {
			State struct {
				Letter struct {
					Subject string `json:"subject"`
				} `json:"letter"`
			} `json:"state"`
		}
		_ = json.Unmarshal(body, &req)
		j.mu.Lock()
		values, ok := j.nouls[req.State.Letter.Subject]
		j.mu.Unlock()
		if !ok {
			values = [3]float64{0.9, 0.1, 0.1}
		}
		fmt.Fprintf(w, `{"model":"jev-test-1","answers":{"needs_action":{"type":"noul","noul":%v},"awaits_reply":{"type":"noul","noul":%v},"time_sensitive":{"type":"noul","noul":%v}},"usage":{"input_tokens":123,"output_tokens":20}}`,
			values[0], values[1], values[2])
	}))
	t.Cleanup(j.server.Close)
	return j
}

func (j *fakeJev) count() int {
	j.mu.Lock()
	defer j.mu.Unlock()
	return len(j.requests)
}

func (j *fakeJev) request(i int) jevRequest {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.requests[i]
}

type triageFixture struct {
	*conduitFixture
	jev    *fakeJev
	clock  *fakeClock
	sleeps []time.Duration
	sleepM sync.Mutex
	engine *triageEngine
}

// newTriageFixture writes conf (when non-empty; "{endpoint}" is replaced by the fake
// server URL) with mode 0600 and builds the engine the way the conduit does.
func newTriageFixture(t *testing.T, conf string) *triageFixture {
	t.Helper()
	f := &triageFixture{conduitFixture: newConduitFixture(t), jev: newFakeJev(t),
		clock: &fakeClock{now: time.Unix(1790100000, 0)}}
	if conf != "" {
		f.writeConf(conf)
	}
	f.engine = newTriageEngineAt(f.home, f.conduit.logger, f.clock.Now, func(d time.Duration) {
		f.sleepM.Lock()
		f.sleeps = append(f.sleeps, d)
		f.sleepM.Unlock()
	})
	f.conduit.triage = f.engine
	t.Cleanup(f.engine.close)
	return f
}

func (f *triageFixture) writeConf(conf string) {
	f.t.Helper()
	path := filepath.Join(f.home, "triage.conf")
	_ = os.Remove(path)
	conf = strings.ReplaceAll(conf, "{endpoint}", f.jev.server.URL)
	if err := os.WriteFile(path, []byte(conf), 0600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *triageFixture) cachePath(identity, id, ext string) string {
	return filepath.Join(f.home, "run", "triage", identity, id+ext)
}

func (f *triageFixture) waitTag(identity, id string) string {
	f.t.Helper()
	path := f.cachePath(identity, id, ".tag")
	var data []byte
	if !waitForTest(3*time.Second, func() bool {
		var err error
		data, err = os.ReadFile(path)
		return err == nil
	}) {
		f.t.Fatalf("no tag for %s/%s after 3s; requests=%d logs:\n%s", identity, id, f.jev.count(), f.logs.String())
	}
	return string(data)
}

func (f *triageFixture) frameContent(identity string) string {
	letters := f.conduit.pending(identity)
	frame := f.conduit.frame(identity, letterGeneration(letters), "attempt-1", 0, letters)
	return frame["message"].(map[string]string)["content"]
}

func triageLine(content string) string {
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, "triage: ") {
			return line
		}
	}
	return ""
}

const baseConf = "# test\nprovider typesafe\nkey test-key\nendpoint {endpoint}\n"

func TestTriageP1OffIsInert(t *testing.T) {
	f := newTriageFixture(t, "")
	f.stageEnvelope("ink", "1.mail", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: hello\n\nplease do x\n")
	f.stageEnvelope("ink", "2.info", "From: monitor@alpha\nType: notice\nUrgency: info\nSubject: quiet\n\nbody\n")
	f.conduit.triage = nil
	before := f.frameContent("ink")
	f.conduit.triage = f.engine
	f.conduit.scan()
	f.engine.refresh()
	f.engine.scan()
	time.Sleep(200 * time.Millisecond)
	after := f.frameContent("ink")
	if after != before {
		t.Fatalf("P1: frame with triage off differs from frame without triage:\n%s\nwant:\n%s", after, before)
	}
	if n := f.jev.count(); n != 0 {
		t.Fatalf("P1: triage off made %d HTTP requests", n)
	}
	if _, err := os.Lstat(filepath.Join(f.home, "run", "triage")); !os.IsNotExist(err) {
		t.Fatalf("P1: triage off created run/triage (err=%v)", err)
	}
	if strings.Contains(f.logs.String(), "triage") {
		t.Fatalf("P1: triage off logged: %s", f.logs.String())
	}
}

func TestTriageP2AsksOncePerMessageAndWritesCache(t *testing.T) {
	f := newTriageFixture(t, baseConf+"model jev-pinned\n")
	f.jev.nouls["act"] = [3]float64{0.9, 0.8, 0.75}
	f.jev.nouls["info"] = [3]float64{0.1, 0.1, 0.1}
	longBody := "a" + strings.Repeat("가", 1200) + "\n"
	f.stageEnvelope("ink", "1.act", "Khala: 0.1\nId: 1.act\nFrom: alice@alpha\nTo: ink@alpha\nType: message\nSubject: act\nIn-Reply-To: 0.prev\n\n"+longBody)
	f.stageEnvelope("ink", "2.info", "From: bob@alpha\nTo: ink@alpha\nType: message\n\nfyi only\n")
	f.jev.nouls[""] = [3]float64{0.1, 0.1, 0.1}
	f.stageEnvelope("ink", "3.notice", "From: monitor@alpha\nType: notice\nUrgency: urgent\nSubject: hot\n\nbody\n")
	f.conduit.scan()
	if got := f.waitTag("ink", "1.act"); got != "action,reply,urgent\n" {
		t.Fatalf("P2: tag for 1.act=%q want %q", got, "action,reply,urgent\n")
	}
	if got := f.waitTag("ink", "2.info"); got != "fyi\n" {
		t.Fatalf("P2: tag for 2.info=%q want fyi", got)
	}
	f.conduit.scan()
	time.Sleep(100 * time.Millisecond)
	if n := f.jev.count(); n != 2 {
		t.Fatalf("P2: %d requests for 2 message letters, want exactly 2", n)
	}
	wantQuestions := map[string]any{
		"needs_action": map[string]any{"type": "noul",
			"instructions": "Does `letter` ask the recipient session to do something or to answer something?",
			"criteria": map[string]any{
				"true":  "It contains a task, a request, or a question the recipient is expected to act on or answer",
				"false": "It only informs, confirms, reports results, or acknowledges; nothing is asked of the recipient"}},
		"awaits_reply": map[string]any{"type": "noul",
			"instructions": "Does the sender of `letter` expect a reply letter from the recipient?",
			"criteria": map[string]any{
				"true":  "The sender asks a question, requests confirmation, or explicitly says a reply is wanted",
				"false": "The sender says no reply is needed, or the letter is a pure report, notice or acknowledgment"}},
		"time_sensitive": map[string]any{"type": "noul",
			"instructions": "Does `letter` say the matter is blocking the sender now or must be handled promptly?",
			"criteria": map[string]any{
				"true":  "It states a deadline, that something is blocked or waiting on the recipient, or asks for prompt action",
				"false": "No urgency is expressed; it can wait for the recipient's next convenient moment"}},
	}
	var actState json.RawMessage
	for i := 0; i < 2; i++ {
		req := f.jev.request(i)
		if got := req.header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("P2: Authorization=%q", got)
		}
		if got := req.header.Get("Content-Type"); got != "application/json" {
			t.Fatalf("P2: Content-Type=%q", got)
		}
		var body map[string]json.RawMessage
		if err := json.Unmarshal(req.body, &body); err != nil {
			t.Fatal(err)
		}
		if len(body) != 3 || string(body["model"]) != `"jev-pinned"` {
			t.Fatalf("P2: request top level=%s", req.body)
		}
		var questions map[string]any
		_ = json.Unmarshal(body["questions"], &questions)
		if !reflect.DeepEqual(questions, wantQuestions) {
			t.Fatalf("P2: questions=%s", body["questions"])
		}
		var state map[string]map[string]any
		if err := json.Unmarshal(body["state"], &state); err != nil || len(state) != 1 {
			t.Fatalf("P2: state=%s err=%v", body["state"], err)
		}
		letter := state["letter"]
		keys := make([]string, 0)
		for k := range letter {
			keys = append(keys, k)
		}
		if len(keys) != 5 || letter["from"] == nil || letter["to"] == nil || letter["subject"] == nil || letter["is_reply"] == nil || letter["body"] == nil {
			t.Fatalf("P2: letter state keys=%v", keys)
		}
		if letter["subject"] == "act" {
			actState = body["state"]
			if letter["from"] != "alice@alpha" || letter["to"] != "ink@alpha" || letter["is_reply"] != true {
				t.Fatalf("P2: act letter state=%v", letter)
			}
			if want := "a" + strings.Repeat("가", 999); letter["body"] != want {
				t.Fatalf("P2: body not cut at 3000 bytes on a UTF-8 boundary: len=%d", len(letter["body"].(string)))
			}
		} else if letter["subject"] != "" || letter["is_reply"] != false || letter["body"] != "fyi only\n" {
			t.Fatalf("P2: info letter state=%v", letter)
		}
	}
	var entry map[string]any
	if err := readJSON(f.cachePath("ink", "1.act", ".json"), &entry); err != nil {
		t.Fatalf("P2: cache json: %v", err)
	}
	sum := sha256.Sum256(actState)
	if entry["id"] != "1.act" || entry["model"] != "jev-test-1" || entry["needsAction"] != 0.9 ||
		entry["awaitsReply"] != 0.8 || entry["timeSensitive"] != 0.75 || entry["inputTokens"] != float64(123) ||
		entry["digest"] != hex.EncodeToString(sum[:]) || entry["askedAt"] != float64(1790100000) {
		t.Fatalf("P2: cache entry=%v", entry)
	}
	if _, ok := entry["latencyMs"]; !ok {
		t.Fatalf("P2: cache entry lacks latencyMs: %v", entry)
	}
	for _, p := range []string{f.cachePath("ink", "1.act", ".json"), f.cachePath("ink", "1.act", ".tag")} {
		info, err := os.Stat(p)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("P2: %s mode=%v err=%v", p, info, err)
		}
	}
	if info, err := os.Stat(filepath.Join(f.home, "run", "triage", "ink")); err != nil || info.Mode().Perm() != 0700 {
		t.Fatalf("P2: cache dir mode err=%v", err)
	}
	content := f.frameContent("ink")
	if got, want := triageLine(content), "triage: action 1 (urgent 1, reply 1), fyi 1, pending 0"; got != want {
		t.Fatalf("P2: frame triage line=%q want %q\n%s", got, want, content)
	}
}

func TestTriageP2bThresholds(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	f.jev.nouls["edge"] = [3]float64{0.69, 0.70, 0.0}
	f.stageEnvelope("ink", "1.edge", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: edge\n\nbody\n")
	f.conduit.scan()
	if got := f.waitTag("ink", "1.edge"); got != "reply\n" {
		t.Fatalf("P2b: noul 0.69/0.70 at threshold 0.7 tagged %q, want %q", got, "reply\n")
	}
	f.writeConf(baseConf + "threshold 0.5\n")
	f.clock.Advance(61 * time.Second)
	f.conduit.scan()
	data, _ := os.ReadFile(f.cachePath("ink", "1.edge", ".tag"))
	if string(data) != "action,reply\n" {
		t.Fatalf("P2b: threshold 0.5 did not re-derive the tag: %q", data)
	}
	f.writeConf(baseConf + "threshold 0.5\nthreshold-reply 0.9\n")
	f.clock.Advance(61 * time.Second)
	f.conduit.scan()
	data, _ = os.ReadFile(f.cachePath("ink", "1.edge", ".tag"))
	if string(data) != "action\n" {
		t.Fatalf("P2b: threshold-reply 0.9 did not re-derive the tag: %q", data)
	}
	time.Sleep(100 * time.Millisecond)
	if n := f.jev.count(); n != 1 {
		t.Fatalf("P2b: threshold change made %d requests, want 1 total", n)
	}
}

func TestTriageP3DoorbellDoesNotWaitForJudgment(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	f.jev.delay = 5 * time.Second
	reg := f.addRegistration("ink", "owner", "interactive", false, time.Now().Add(-time.Hour), 3)
	f.writeLease("ink", &reg, "owned", 3)
	f.stageEnvelope("ink", "1.mail", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: please\n\nplease do x\n")
	originalHook := conduitBeforeDoorbellWrite
	t.Cleanup(func() { conduitBeforeDoorbellWrite = originalHook })
	var hookCacheExists = true
	hookCalled := false
	conduitBeforeDoorbellWrite = func(string) {
		hookCalled = true
		_, err := os.Stat(f.cachePath("ink", "1.mail", ".json"))
		hookCacheExists = err == nil
	}
	started := time.Now()
	f.conduit.scan()
	if !waitForTest(time.Second, func() bool { return f.deliveries[reg.InstanceID].Load() == 1 }) {
		t.Fatal("P3: doorbell not written")
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second || !hookCalled || hookCacheExists {
		t.Fatalf("P3: doorbell waited for judgment: elapsed=%s hook=%v cacheAtWrite=%v", elapsed, hookCalled, hookCacheExists)
	}
	if !waitForTest(3*time.Second, func() bool { return f.jev.count() == 1 }) {
		t.Fatalf("P3: judgment request not sent while the doorbell rang (requests=%d)", f.jev.count())
	}
	if line := triageLine(f.frameContent("ink")); line != "triage: action 0 (urgent 0, reply 0), fyi 0, pending 1" {
		t.Fatalf("P3: frame before judgment=%q", line)
	}
	path := f.cachePath("ink", "1.mail", ".tag")
	if !waitForTest(7*time.Second, func() bool { _, err := os.Stat(path); return err == nil }) {
		t.Fatal("P3: judgment never cached")
	}
	if line := triageLine(f.frameContent("ink")); line != "triage: action 1 (urgent 0, reply 0), fyi 0, pending 0" {
		t.Fatalf("P3: later frame=%q", line)
	}
}

func countLines(logs, substr string) int {
	n := 0
	for _, line := range strings.Split(logs, "\n") {
		if strings.Contains(line, substr) {
			n++
		}
	}
	return n
}

func TestTriageP4ErrorCachedAndBackedOff(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	f.jev.statuses = []int{401, 401, 401}
	f.stageEnvelope("ink", "1.mail", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: x\n\nbody\n")
	f.conduit.scan()
	jsonPath := f.cachePath("ink", "1.mail", ".json")
	if !waitForTest(3*time.Second, func() bool { _, err := os.Stat(jsonPath); return err == nil }) {
		t.Fatalf("P4: 401 did not write an error entry; requests=%d", f.jev.count())
	}
	var entry map[string]any
	if err := readJSON(jsonPath, &entry); err != nil || entry["id"] != "1.mail" || entry["error"] == nil || entry["error"] == "" || entry["askedAt"] != float64(1790100000) {
		t.Fatalf("P4: error entry=%v err=%v", entry, err)
	}
	if _, err := os.Stat(f.cachePath("ink", "1.mail", ".tag")); !os.IsNotExist(err) {
		t.Fatalf("P4: error entry wrote a tag (err=%v)", err)
	}
	for i := 0; i < 3; i++ {
		f.clock.Advance(3 * time.Minute)
		f.conduit.scan()
	}
	time.Sleep(200 * time.Millisecond)
	if n := f.jev.count(); n != 1 {
		t.Fatalf("P4: %d requests within 10 minutes of a 401, want 1", n)
	}
	if line := triageLine(f.frameContent("ink")); line != "triage: action 0 (urgent 0, reply 0), fyi 0, pending 1" {
		t.Fatalf("P4: frame with error entry=%q", line)
	}
	f.clock.Advance(2 * time.Minute)
	f.conduit.scan()
	if !waitForTest(3*time.Second, func() bool { return f.jev.count() == 2 }) {
		t.Fatalf("P4: no retry after 10 minutes (requests=%d)", f.jev.count())
	}
	time.Sleep(200 * time.Millisecond)
	if n := countLines(f.logs.String(), "HTTP 401"); n != 1 {
		t.Fatalf("P4: 401 logged %d times, want 1:\n%s", n, f.logs.String())
	}
}

func TestTriageP4RateLimitBacksOffThenSucceeds(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	f.jev.statuses = []int{429, 529}
	f.stageEnvelope("ink", "1.mail", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: x\n\nbody\n")
	f.conduit.scan()
	if got := f.waitTag("ink", "1.mail"); got != "action\n" {
		t.Fatalf("P4: tag after 429/529 backoff=%q", got)
	}
	f.sleepM.Lock()
	sleeps := append([]time.Duration(nil), f.sleeps...)
	f.sleepM.Unlock()
	if n := f.jev.count(); n != 3 || !reflect.DeepEqual(sleeps, []time.Duration{time.Second, 2 * time.Second}) {
		t.Fatalf("P4: requests=%d sleeps=%v, want 3 and [1s 2s]", n, sleeps)
	}
}

func TestTriageP4RateLimitExhaustedIsNotCached(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	f.jev.statuses = []int{429, 429, 429}
	f.stageEnvelope("ink", "1.mail", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: x\n\nbody\n")
	f.conduit.scan()
	if !waitForTest(3*time.Second, func() bool { return f.jev.count() == 3 }) {
		t.Fatalf("P4: requests=%d want 3 tries", f.jev.count())
	}
	time.Sleep(200 * time.Millisecond)
	if _, err := os.Stat(f.cachePath("ink", "1.mail", ".json")); !os.IsNotExist(err) {
		t.Fatalf("P4: exhausted 429 was cached (err=%v)", err)
	}
	f.conduit.scan()
	if got := f.waitTag("ink", "1.mail"); got != "action\n" {
		t.Fatalf("P4: next scan after 429 did not retry: %q", got)
	}
}

func TestTriageP5SkipsOperatorAndNotice(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	f.stageEnvelope("ink", "1.op", "From: operator@alpha\nTo: ink@alpha\nType: operator\nSubject: op\n\nbody\n")
	f.stageEnvelope("ink", "2.notice", "From: gpu@alpha\nType: notice\nUrgency: urgent\nSubject: hot\n\nbody\n")
	f.stageEnvelope("ink", "3.info", "From: gpu@alpha\nType: notice\nUrgency: info\nSubject: cool\n\nbody\n")
	f.conduit.scan()
	time.Sleep(300 * time.Millisecond)
	if n := f.jev.count(); n != 0 {
		t.Fatalf("P5: operator/notice letters made %d requests", n)
	}
	if line := triageLine(f.frameContent("ink")); line != "triage: action 0 (urgent 0, reply 0), fyi 0, pending 0" {
		t.Fatalf("P5: frame line=%q", line)
	}
}

func TestTriageP6HourlyBudget(t *testing.T) {
	f := newTriageFixture(t, baseConf+"max-per-hour 2\n")
	for i := 1; i <= 3; i++ {
		f.stageEnvelope("ink", fmt.Sprintf("%d.mail", i), fmt.Sprintf("From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: s%d\n\nbody\n", i))
	}
	f.conduit.scan()
	f.waitTag("ink", "1.mail")
	f.waitTag("ink", "2.mail")
	f.conduit.scan()
	time.Sleep(200 * time.Millisecond)
	if n := f.jev.count(); n != 2 {
		t.Fatalf("P6: max-per-hour 2 made %d requests", n)
	}
	if line := triageLine(f.frameContent("ink")); line != "triage: action 2 (urgent 0, reply 0), fyi 0, pending 1" {
		t.Fatalf("P6: frame line=%q", line)
	}
	if n := countLines(f.logs.String(), "budget"); n != 1 {
		t.Fatalf("P6: budget logged %d times, want 1:\n%s", n, f.logs.String())
	}
	f.clock.Advance(61 * time.Minute)
	f.conduit.scan()
	f.waitTag("ink", "3.mail")
	if n := f.jev.count(); n != 3 {
		t.Fatalf("P6: after an hour requests=%d want 3", n)
	}
}

func TestTriageP7CacheFollowsLetters(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	a := f.stageEnvelope("ink", "1.kept", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: a\n\nbody\n")
	b := f.stageEnvelope("ink", "2.gone", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: b\n\nbody\n")
	f.conduit.scan()
	f.waitTag("ink", "1.kept")
	f.waitTag("ink", "2.gone")
	cur := filepath.Join(f.home, "inbox", "ink", "cur")
	if err := os.MkdirAll(cur, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(a, filepath.Join(cur, "1.kept")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(b); err != nil {
		t.Fatal(err)
	}
	f.conduit.scan()
	for _, ext := range []string{".json", ".tag"} {
		if _, err := os.Stat(f.cachePath("ink", "1.kept", ext)); err != nil {
			t.Fatalf("P7: cache %s for letter moved to cur was removed: %v", ext, err)
		}
		if _, err := os.Stat(f.cachePath("ink", "2.gone", ext)); !os.IsNotExist(err) {
			t.Fatalf("P7: cache %s for deleted letter survived the scan (err=%v)", ext, err)
		}
	}
}

func TestTriageP8FrameBoundAndPosition(t *testing.T) {
	f := newTriageFixture(t, baseConf)
	for i := 0; i < 12; i++ {
		f.stageEnvelope("ink", fmt.Sprintf("%02d.mail", i), fmt.Sprintf("From: sender%02d-%s@alpha\nTo: ink@alpha\nType: message\nSubject: %s\n\nbody\n", i, strings.Repeat("x", 100), strings.Repeat("s", 300)))
	}
	f.conduit.scan()
	f.waitTag("ink", "11.mail")
	content := f.frameContent("ink")
	if len(content) > 8192 {
		t.Fatalf("P8: frame %d bytes > 8192", len(content))
	}
	lines := strings.Split(content, "\n")
	index := map[string]int{}
	for i, line := range lines {
		for _, prefix := range []string{"subjects: ", "triage: ", "generation: "} {
			if strings.HasPrefix(line, prefix) {
				index[prefix] = i
			}
		}
	}
	ti, ok := index["triage: "]
	if !ok || ti != index["subjects: "]+1 || index["generation: "] != ti+1 {
		t.Fatalf("P8: triage line position %v in:\n%s", index, content)
	}
}

func TestTriageP9UnsafeConfIsOffWithOneLogLine(t *testing.T) {
	cases := map[string]func(f *triageFixture){
		"mode0644": func(f *triageFixture) {
			f.writeConf(baseConf)
			_ = os.Chmod(filepath.Join(f.home, "triage.conf"), 0644)
		},
		"symlink": func(f *triageFixture) {
			f.writeConf(baseConf)
			real := filepath.Join(f.home, "triage.real")
			_ = os.Rename(filepath.Join(f.home, "triage.conf"), real)
			_ = os.Symlink(real, filepath.Join(f.home, "triage.conf"))
		},
		"nokey": func(f *triageFixture) {
			f.writeConf("provider typesafe\nendpoint {endpoint}\n")
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			f := newTriageFixture(t, "")
			setup(f)
			f.engine.close()
			f.engine = newTriageEngineAt(f.home, f.conduit.logger, f.clock.Now, func(time.Duration) {})
			f.conduit.triage = f.engine
			t.Cleanup(f.engine.close)
			f.stageEnvelope("ink", "1.mail", "From: alice@alpha\nTo: ink@alpha\nType: message\nSubject: x\n\nbody\n")
			for i := 0; i < 3; i++ {
				f.conduit.scan()
				f.clock.Advance(61 * time.Second)
			}
			time.Sleep(200 * time.Millisecond)
			if n := f.jev.count(); n != 0 {
				t.Fatalf("P9 %s: disabled triage made %d requests", name, n)
			}
			if n := countLines(f.logs.String(), "triage: disabled: "); n != 1 {
				t.Fatalf("P9 %s: %d 'triage: disabled:' lines, want 1:\n%s", name, n, f.logs.String())
			}
			if line := triageLine(f.frameContent("ink")); line != "" {
				t.Fatalf("P9 %s: disabled triage put %q in the frame", name, line)
			}
			// Turning it on needs no restart: a fixed conf is picked up within a minute.
			f.writeConf(baseConf)
			f.clock.Advance(61 * time.Second)
			f.conduit.scan()
			f.waitTag("ink", "1.mail")
			if n := countLines(f.logs.String(), "triage: enabled"); n != 1 {
				t.Fatalf("P9 %s: enable not logged once:\n%s", name, f.logs.String())
			}
		})
	}
}
