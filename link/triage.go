package main

// Advisory letter triage (review/jev-triage-r1.md). The conduit asks the TypeSafe
// System One API three yes/no questions about each new `Type: message` letter and
// caches the answers under $KHALA_HOME/run/triage/<identity>/ (node-local, never
// replicated). The doorbell never waits for a judgment: frames only read the
// in-memory copy of the cache. Without $KHALA_HOME/triage.conf nothing happens.

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	triageDefaultModel    = "jev-latest"
	triageDefaultEndpoint = "https://api.typesafe.ai/v1/systemone"
	triageDefaultBudget   = 600
	triageDefaultThresh   = 0.7
	triageBodyLimit       = 3000
	triageHeaderLimit     = 64 << 10
	triageRequestTimeout  = 8 * time.Second
	triageErrorRetry      = 10 * time.Minute
	triageConfReread      = time.Minute
	triageWorkers         = 2
	triageQueueSize       = 1024
	triageTries           = 3
)

// triageQuestions is sent verbatim with every request. The ids are ours.
var triageQuestions = []byte(`{` +
	`"needs_action":{"type":"noul","instructions":"Does ` + "`letter`" + ` ask the recipient session to do something or to answer something?",` +
	`"criteria":{"true":"It contains a task, a request, or a question the recipient is expected to act on or answer",` +
	`"false":"It only informs, confirms, reports results, or acknowledges; nothing is asked of the recipient"}},` +
	`"awaits_reply":{"type":"noul","instructions":"Does the sender of ` + "`letter`" + ` expect a reply letter from the recipient?",` +
	`"criteria":{"true":"The sender asks a question, requests confirmation, or explicitly says a reply is wanted",` +
	`"false":"The sender says no reply is needed, or the letter is a pure report, notice or acknowledgment"}},` +
	`"time_sensitive":{"type":"noul","instructions":"Does ` + "`letter`" + ` say the matter is blocking the sender now or must be handled promptly?",` +
	`"criteria":{"true":"It states a deadline, that something is blocked or waiting on the recipient, or asks for prompt action",` +
	`"false":"No urgency is expressed; it can wait for the recipient's next convenient moment"}}` +
	`}`)

type triageConf struct {
	model           string
	endpoint        string
	key             string
	maxPerHour      int
	thresholdAction float64
	thresholdReply  float64
	thresholdUrgent float64
}

func (c *triageConf) status() string {
	return fmt.Sprintf("model %s, max-per-hour %d, thresholds action %g reply %g urgent %g",
		c.model, c.maxPerHour, c.thresholdAction, c.thresholdReply, c.thresholdUrgent)
}

// loadTriageConf returns (nil, "") when the file is absent (triage off, silent),
// (nil, reason) when it is present but unusable, and the parsed conf otherwise.
func loadTriageConf(home string) (*triageConf, string) {
	path := filepath.Join(home, "triage.conf")
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil, ""
	}
	if err != nil {
		return nil, fmt.Sprintf("inspect %s: %v", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return nil, path + " is a symlink"
	}
	if !info.Mode().IsRegular() {
		return nil, path + " is not a regular file"
	}
	if info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Sprintf("%s has mode %04o; want 0600", path, info.Mode().Perm())
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Geteuid() {
		return nil, path + " is not owned by this user"
	}
	f, err := openRegular(path)
	if err != nil {
		return nil, fmt.Sprintf("open %s: %v", path, err)
	}
	defer f.Close()
	c := &triageConf{model: triageDefaultModel, endpoint: triageDefaultEndpoint, maxPerHour: triageDefaultBudget}
	threshold := triageDefaultThresh
	var perTag [3]*float64
	provider := ""
	keyFile := ""
	s := bufio.NewScanner(io.LimitReader(f, 64<<10))
	for line := 1; s.Scan(); line++ {
		fields := strings.Fields(s.Text())
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		if len(fields) != 2 {
			return nil, fmt.Sprintf("triage.conf line %d: want \"key value\"", line)
		}
		value := fields[1]
		switch fields[0] {
		case "provider":
			provider = value
		case "key":
			c.key = value
		case "key-file":
			keyFile = value
		case "model":
			c.model = value
		case "endpoint":
			c.endpoint = value
		case "max-per-hour":
			n, err := strconv.Atoi(value)
			if err != nil || n <= 0 {
				return nil, fmt.Sprintf("triage.conf line %d: max-per-hour must be a positive integer", line)
			}
			c.maxPerHour = n
		case "threshold", "threshold-action", "threshold-reply", "threshold-urgent":
			v, err := strconv.ParseFloat(value, 64)
			if err != nil || v < 0 || v > 1 {
				return nil, fmt.Sprintf("triage.conf line %d: %s must be a number in 0..1", line, fields[0])
			}
			switch fields[0] {
			case "threshold":
				threshold = v
			case "threshold-action":
				perTag[0] = &v
			case "threshold-reply":
				perTag[1] = &v
			case "threshold-urgent":
				perTag[2] = &v
			}
		default:
			return nil, fmt.Sprintf("triage.conf line %d: unknown key %q", line, fields[0])
		}
	}
	if err := s.Err(); err != nil {
		return nil, fmt.Sprintf("read triage.conf: %v", err)
	}
	if provider != "typesafe" {
		return nil, "triage.conf provider must be typesafe"
	}
	if c.key != "" && keyFile != "" {
		return nil, "triage.conf has both key and key-file"
	}
	if keyFile != "" {
		if !filepath.IsAbs(keyFile) {
			return nil, "triage.conf key-file must be an absolute path"
		}
		data, err := os.ReadFile(keyFile)
		if err != nil {
			return nil, fmt.Sprintf("read key-file: %v", err)
		}
		c.key = strings.TrimSpace(string(data))
	}
	if c.key == "" {
		return nil, "triage.conf has no key"
	}
	c.thresholdAction, c.thresholdReply, c.thresholdUrgent = threshold, threshold, threshold
	if perTag[0] != nil {
		c.thresholdAction = *perTag[0]
	}
	if perTag[1] != nil {
		c.thresholdReply = *perTag[1]
	}
	if perTag[2] != nil {
		c.thresholdUrgent = *perTag[2]
	}
	return c, ""
}

// triageEntry is the cache file <letter-id>.json. A success entry carries the three
// probabilities and the digest of the state that was sent; an error entry carries
// only id, error and askedAt.
type triageEntry struct {
	ID            string  `json:"id"`
	Model         string  `json:"model,omitempty"`
	AskedAt       int64   `json:"askedAt"`
	NeedsAction   float64 `json:"needsAction"`
	AwaitsReply   float64 `json:"awaitsReply"`
	TimeSensitive float64 `json:"timeSensitive"`
	InputTokens   int64   `json:"inputTokens"`
	LatencyMs     int64   `json:"latencyMs"`
	Digest        string  `json:"digest"`
	Error         string  `json:"error,omitempty"`
}

type triageErrorEntry struct {
	ID      string `json:"id"`
	Error   string `json:"error"`
	AskedAt int64  `json:"askedAt"`
}

// triageTag derives the one-line tag: the tags among action, reply, urgent in that
// order, comma-joined, or fyi when none reaches its threshold.
func triageTag(e *triageEntry, c *triageConf) string {
	var tags []string
	if e.NeedsAction >= c.thresholdAction {
		tags = append(tags, "action")
	}
	if e.AwaitsReply >= c.thresholdReply {
		tags = append(tags, "reply")
	}
	if e.TimeSensitive >= c.thresholdUrgent {
		tags = append(tags, "urgent")
	}
	if len(tags) == 0 {
		return "fyi"
	}
	return strings.Join(tags, ",")
}

// triageMemo is the conduit's in-memory view of one letter in new/.
type triageMemo struct {
	size, mtime int64
	kind        string
	digest      string
	entry       *triageEntry
	tagOnDisk   string
	seen        bool
}

type triageJob struct {
	identity, id, path string
}

type triageEngine struct {
	home   string
	logger *log.Logger
	now    func() time.Time
	sleep  func(time.Duration)
	client *http.Client
	ctx    context.Context
	cancel context.CancelFunc
	jobs   chan triageJob
	wg     sync.WaitGroup

	mu           sync.Mutex
	conf         *triageConf
	confChecked  bool
	confReadAt   time.Time
	confStatus   string
	memo         map[string]*triageMemo
	inflight     map[string]bool
	asked        []time.Time
	budgetLogged time.Time
	errLogged    map[string]time.Time
}

func newTriageEngine(home string, logger *log.Logger) *triageEngine {
	return newTriageEngineAt(home, logger, time.Now, time.Sleep)
}

func newTriageEngineAt(home string, logger *log.Logger, now func() time.Time, sleep func(time.Duration)) *triageEngine {
	ctx, cancel := context.WithCancel(context.Background())
	t := &triageEngine{
		home: home, logger: logger, now: now, sleep: sleep, client: &http.Client{},
		ctx: ctx, cancel: cancel, jobs: make(chan triageJob, triageQueueSize),
		memo: make(map[string]*triageMemo), inflight: make(map[string]bool), errLogged: make(map[string]time.Time),
	}
	for i := 0; i < triageWorkers; i++ {
		t.wg.Add(1)
		go t.worker()
	}
	return t
}

func (t *triageEngine) close() {
	t.cancel()
	t.wg.Wait()
}

// refresh re-reads triage.conf at most once per minute and logs a status change once.
func (t *triageEngine) refresh() {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	if t.confChecked && now.Sub(t.confReadAt) < triageConfReread {
		return
	}
	conf, reason := loadTriageConf(t.home)
	t.confChecked, t.confReadAt = true, now
	status := "off"
	switch {
	case conf != nil:
		status = "enabled (" + conf.status() + ")"
	case reason != "":
		status = "disabled: " + reason
	}
	if status != t.confStatus {
		// The initial absent-file state is silent: no conf means nothing happens.
		if !(t.confStatus == "" && status == "off") {
			t.logger.Printf("triage: %s", status)
		}
		t.confStatus = status
	}
	t.conf = conf
}

func (t *triageEngine) enabled() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.conf != nil
}

// scan is one conduit pass: refresh the conf, then (when on) enqueue unjudged
// message letters of every identity, re-derive tags, and drop cache files of
// letters that are in neither new/ nor cur/.
func (t *triageEngine) scan() {
	t.refresh()
	if !t.enabled() {
		// Off: nothing is asked or written; only leftovers of an earlier "on"
		// period are cleaned up (collectGarbage never creates run/triage).
		t.collectGarbage()
		return
	}
	inbox := filepath.Join(t.home, "inbox")
	entries, _ := os.ReadDir(inbox)
	t.mu.Lock()
	for _, m := range t.memo {
		m.seen = false
	}
	t.mu.Unlock()
	for _, entry := range entries {
		if entry.IsDir() && validBasename(entry.Name()) {
			t.observe(entry.Name())
		}
	}
	t.mu.Lock()
	for key, m := range t.memo {
		if !m.seen {
			delete(t.memo, key)
		}
	}
	t.mu.Unlock()
	t.collectGarbage()
}

func (t *triageEngine) observe(identity string) {
	dir := filepath.Join(t.home, "inbox", identity, "new")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	cacheDir := filepath.Join(t.home, "run", "triage", identity)
	for _, entry := range entries {
		id := entry.Name()
		if !entry.Type().IsRegular() || !validBasename(id) {
			continue
		}
		path := filepath.Join(dir, id)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		key := identity + "/" + id
		t.mu.Lock()
		m := t.memo[key]
		t.mu.Unlock()
		if m == nil || m.size != info.Size() || m.mtime != info.ModTime().UnixNano() {
			kind, state, err := readTriageLetter(path)
			if err != nil {
				continue
			}
			fresh := &triageMemo{size: info.Size(), mtime: info.ModTime().UnixNano(), kind: kind}
			if kind == "message" {
				sum := sha256.Sum256(state)
				fresh.digest = hex.EncodeToString(sum[:])
				var cached triageEntry
				if readJSON(filepath.Join(cacheDir, id+".json"), &cached) == nil && cached.ID == id {
					fresh.entry = &cached
				}
				if data, err := os.ReadFile(filepath.Join(cacheDir, id+".tag")); err == nil {
					fresh.tagOnDisk = strings.TrimSuffix(string(data), "\n")
				}
			}
			t.mu.Lock()
			if m != nil && m.entry != nil && fresh.entry == nil {
				fresh.entry = m.entry
			}
			t.memo[key] = fresh
			m = fresh
			t.mu.Unlock()
		}
		t.mu.Lock()
		m.seen = true
		if m.kind != "message" {
			t.mu.Unlock()
			continue
		}
		conf := t.conf
		entry := m.entry
		switch {
		case entry != nil && entry.Error == "" && entry.Digest == m.digest:
			tag := triageTag(entry, conf)
			if tag != m.tagOnDisk {
				t.mu.Unlock()
				if err := writeAtomicText(filepath.Join(cacheDir, id+".tag"), tag+"\n"); err != nil {
					t.logger.Printf("triage: write tag %s failed: %v", key, err)
					continue
				}
				t.mu.Lock()
				m.tagOnDisk = tag
			}
			t.mu.Unlock()
			continue
		case entry != nil && entry.Error != "" && t.now().Sub(time.Unix(entry.AskedAt, 0)) < triageErrorRetry:
			t.mu.Unlock()
			continue
		}
		if t.inflight[key] {
			t.mu.Unlock()
			continue
		}
		if !t.reserveLocked(conf) {
			t.mu.Unlock()
			continue
		}
		select {
		case t.jobs <- triageJob{identity: identity, id: id, path: path}:
			t.inflight[key] = true
		default:
			// Queue full: give the reservation back; the next scan retries.
			t.asked = t.asked[:len(t.asked)-1]
		}
		t.mu.Unlock()
	}
}

// reserveLocked takes one request from the rolling hourly budget.
func (t *triageEngine) reserveLocked(conf *triageConf) bool {
	now := t.now()
	kept := t.asked[:0]
	for _, at := range t.asked {
		if now.Sub(at) < time.Hour {
			kept = append(kept, at)
		}
	}
	t.asked = kept
	if len(t.asked) >= conf.maxPerHour {
		if t.budgetLogged.IsZero() || now.Sub(t.budgetLogged) >= time.Hour {
			t.logger.Printf("triage: hourly budget of %d requests reached; remaining letters wait (shown as pending)", conf.maxPerHour)
			t.budgetLogged = now
		}
		return false
	}
	t.asked = append(t.asked, now)
	return true
}

func (t *triageEngine) collectGarbage() {
	root := filepath.Join(t.home, "run", "triage")
	identities, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, identity := range identities {
		if !identity.IsDir() || !validBasename(identity.Name()) {
			continue
		}
		dir := filepath.Join(root, identity.Name())
		files, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		present := make(map[string]bool)
		for _, file := range files {
			name := file.Name()
			id := strings.TrimSuffix(strings.TrimSuffix(name, ".json"), ".tag")
			if id == name || strings.HasPrefix(name, ".") {
				continue
			}
			live, known := present[id]
			if !known {
				live = false
				for _, box := range []string{"new", "cur"} {
					if _, err := os.Lstat(filepath.Join(t.home, "inbox", identity.Name(), box, id)); err == nil {
						live = true
						break
					}
				}
				present[id] = live
			}
			if !live {
				if err := os.Remove(filepath.Join(dir, name)); err != nil && !os.IsNotExist(err) {
					t.logger.Printf("triage: remove stale cache %s failed: %v", name, err)
				}
			}
		}
	}
}

// readTriageLetter returns the envelope Type and, for messages, the exact state
// bytes that are sent (and hashed into the digest).
func readTriageLetter(path string) (string, []byte, error) {
	f, err := openRegular(path)
	if err != nil {
		return "", nil, err
	}
	defer f.Close()
	r := bufio.NewReader(f)
	var letter struct {
		From    string `json:"from"`
		To      string `json:"to"`
		Subject string `json:"subject"`
		IsReply bool   `json:"is_reply"`
		Body    string `json:"body"`
	}
	kind := ""
	headerBytes := 0
	for {
		line, err := r.ReadString('\n')
		headerBytes += len(line)
		if headerBytes > triageHeaderLimit {
			return "", nil, errors.New("envelope header exceeds 64 KiB")
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		name, value, ok := strings.Cut(line, ": ")
		if ok {
			value = strings.TrimSpace(value)
			switch name {
			case "Type":
				kind = value
			case "From":
				letter.From = value
			case "To":
				letter.To = value
			case "Subject":
				letter.Subject = value
			case "In-Reply-To":
				letter.IsReply = value != ""
			}
		}
		if err != nil {
			break
		}
	}
	if kind != "message" {
		return kind, nil, nil
	}
	body := make([]byte, triageBodyLimit)
	n, err := io.ReadFull(r, body)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", nil, err
	}
	letter.Body = string(cutUTF8(body[:n]))
	state, err := json.Marshal(map[string]any{"letter": letter})
	if err != nil {
		return "", nil, err
	}
	return kind, state, nil
}

// cutUTF8 drops a rune that the byte limit split in half.
func cutUTF8(b []byte) []byte {
	for i := len(b) - 1; i >= 0 && i >= len(b)-utf8.UTFMax; i-- {
		if utf8.RuneStart(b[i]) {
			if !utf8.FullRune(b[i:]) {
				return b[:i]
			}
			break
		}
	}
	return b
}

func (t *triageEngine) worker() {
	defer t.wg.Done()
	for {
		select {
		case <-t.ctx.Done():
			return
		case job := <-t.jobs:
			t.judge(job)
			t.mu.Lock()
			delete(t.inflight, job.identity+"/"+job.id)
			t.mu.Unlock()
		}
	}
}

type triageStatusError struct{ status int }

func (e triageStatusError) Error() string { return fmt.Sprintf("HTTP %d", e.status) }

func (t *triageEngine) judge(job triageJob) {
	t.mu.Lock()
	conf := t.conf
	t.mu.Unlock()
	if conf == nil {
		return
	}
	kind, state, err := readTriageLetter(job.path)
	if err != nil || kind != "message" {
		return // the letter moved or changed; the next scan decides again
	}
	sum := sha256.Sum256(state)
	digest := hex.EncodeToString(sum[:])
	askedAt := t.now().Unix()
	started := time.Now()
	var entry *triageEntry
	for try := 1; ; try++ {
		entry, err = t.ask(conf, state)
		var status triageStatusError
		if err == nil || !errors.As(err, &status) || (status.status != 429 && status.status != 529) {
			break
		}
		if try == triageTries {
			// Rate limited on every try: not cached, the next scan asks again.
			t.logOnce(fmt.Sprintf("triage: %s/%s rate limited (%v) after %d tries; retrying on a later scan", job.identity, job.id, err, triageTries), err.Error()+" rate")
			return
		}
		t.sleep(time.Duration(1<<(try-1)) * time.Second)
		if t.ctx.Err() != nil {
			return
		}
	}
	if t.ctx.Err() != nil {
		return
	}
	cacheDir := filepath.Join(t.home, "run", "triage", job.identity)
	path := filepath.Join(cacheDir, job.id+".json")
	if err != nil {
		t.logOnce(fmt.Sprintf("triage: request failed: %v (no retry for this letter for 10 minutes)", err), err.Error())
		failed := &triageEntry{ID: job.id, Error: err.Error(), AskedAt: askedAt}
		if writeErr := writeAtomicJSON(path, triageErrorEntry{ID: job.id, Error: err.Error(), AskedAt: askedAt}, 0600); writeErr != nil {
			t.logger.Printf("triage: write error entry %s/%s failed: %v", job.identity, job.id, writeErr)
		}
		_ = os.Remove(filepath.Join(cacheDir, job.id+".tag"))
		t.store(job, failed, "")
		return
	}
	entry.ID, entry.AskedAt, entry.Digest = job.id, askedAt, digest
	entry.LatencyMs = time.Since(started).Milliseconds()
	if err := writeAtomicJSON(path, entry, 0600); err != nil {
		t.logger.Printf("triage: write cache %s/%s failed: %v", job.identity, job.id, err)
		return
	}
	t.mu.Lock()
	current := t.conf
	t.mu.Unlock()
	if current == nil {
		current = conf
	}
	tag := triageTag(entry, current)
	if err := writeAtomicText(filepath.Join(cacheDir, job.id+".tag"), tag+"\n"); err != nil {
		t.logger.Printf("triage: write tag %s/%s failed: %v", job.identity, job.id, err)
		tag = ""
	}
	t.store(job, entry, tag)
}

func (t *triageEngine) store(job triageJob, entry *triageEntry, tag string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if m := t.memo[job.identity+"/"+job.id]; m != nil {
		m.entry = entry
		m.tagOnDisk = tag
	}
}

// logOnce logs one line per distinct error string per hour.
func (t *triageEngine) logOnce(line, key string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	if at, ok := t.errLogged[key]; ok && now.Sub(at) < time.Hour {
		return
	}
	t.errLogged[key] = now
	t.logger.Print(line)
}

func (t *triageEngine) ask(conf *triageConf, state []byte) (*triageEntry, error) {
	model, _ := json.Marshal(conf.model)
	var body bytes.Buffer
	body.WriteString(`{"model":`)
	body.Write(model)
	body.WriteString(`,"state":`)
	body.Write(state)
	body.WriteString(`,"questions":`)
	body.Write(triageQuestions)
	body.WriteString(`}`)
	ctx, cancel := context.WithTimeout(t.ctx, triageRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, conf.endpoint, &body)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+conf.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.client.Do(req)
	if err != nil {
		var urlErr interface{ Unwrap() error }
		if errors.As(err, &urlErr) && urlErr.Unwrap() != nil {
			err = urlErr.Unwrap() // drop the URL from the message
		}
		return nil, fmt.Errorf("request: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, triageStatusError{status: resp.StatusCode}
	}
	var decoded struct {
		Model   string `json:"model"`
		Answers map[string]struct {
			Noul *float64 `json:"noul"`
		} `json:"answers"`
		Usage struct {
			InputTokens int64 `json:"input_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	var values [3]float64
	for i, id := range []string{"needs_action", "awaits_reply", "time_sensitive"} {
		answer, ok := decoded.Answers[id]
		if !ok || answer.Noul == nil || *answer.Noul < 0 || *answer.Noul > 1 {
			return nil, fmt.Errorf("response lacks a noul in 0..1 for %s", id)
		}
		values[i] = *answer.Noul
	}
	return &triageEntry{Model: decoded.Model, NeedsAction: values[0], AwaitsReply: values[1],
		TimeSensitive: values[2], InputTokens: decoded.Usage.InputTokens}, nil
}

// frameLine is the doorbell's advisory summary, or "" when triage is off. It only
// reads the in-memory cache and never waits for a judgment.
func (t *triageEngine) frameLine(identity string, letters []pendingLetter) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.conf == nil {
		return ""
	}
	var action, urgent, reply, fyi, pending int
	for _, letter := range letters {
		if letter.kind != "message" {
			continue
		}
		m := t.memo[identity+"/"+letter.id]
		if m == nil || m.entry == nil || m.entry.Error != "" || m.entry.Digest != m.digest {
			pending++
			continue
		}
		tag := triageTag(m.entry, t.conf)
		if tag == "fyi" {
			fyi++
			continue
		}
		if strings.HasPrefix(tag, "action") {
			action++
		}
		if strings.Contains(tag, "reply") {
			reply++
		}
		if strings.Contains(tag, "urgent") {
			urgent++
		}
	}
	return fmt.Sprintf("triage: action %d (urgent %d, reply %d), fyi %d, pending %d", action, urgent, reply, fyi, pending)
}
