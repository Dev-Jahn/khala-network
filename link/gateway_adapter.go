package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// inbound is one chat update as the gateway sees it. ThreadID 0 means the
// forum's General topic. Ignore marks an update the gateway must not act on
// (another chat, a service message, a bot) but whose UpdateID still advances
// the offset.
type inbound struct {
	ThreadID  int64  `json:"thread_id"`
	MessageID int64  `json:"message_id"`
	UpdateID  int64  `json:"update_id"`
	UserID    int64  `json:"user_id"`
	Text      string `json:"text"`
	IsCommand bool   `json:"is_command"`
	Ignore    bool   `json:"ignore,omitempty"`
}

// adapter is the chat service behind the gateway. Poll returns the updates
// whose id is >= offset (confirming everything below offset); the gateway
// owns the offset and advances it only after an update was handed to khala.
type adapter interface {
	Me(ctx context.Context) (string, error)
	Poll(ctx context.Context, offset int64) ([]inbound, error)
	Post(ctx context.Context, threadID int64, text string, replyTo int64) (messageID int64, err error)
	PostDocument(ctx context.Context, threadID int64, name string, data []byte, caption string) (int64, error)
	CreateTopic(ctx context.Context, name string) (threadID int64, err error)
	CloseTopic(ctx context.Context, threadID int64) error
}

// fakeOut records one adapter call that changes the chat.
type fakeOut struct {
	Seq       int    `json:"seq"`
	Method    string `json:"method"` // post | document | createTopic | closeTopic
	Thread    int64  `json:"thread"`
	Text      string `json:"text,omitempty"`
	ReplyTo   int64  `json:"reply_to,omitempty"`
	Name      string `json:"name,omitempty"`
	Data      []byte `json:"data,omitempty"`
	Caption   string `json:"caption,omitempty"`
	MessageID int64  `json:"message_id,omitempty"`
}

// fakeAdapter is an in-memory chat used by tests and by `adapter fake`.
// With a directory it also reads <dir>/inbound/*.json (one inbound each) and
// writes every output as <dir>/outbound/<seq>.json, so a shell test can drive
// the daemon end to end without a network.
type fakeAdapter struct {
	mu      sync.Mutex
	dir     string
	queue   []inbound
	outs    []fakeOut
	seq     int
	nextMsg int64
	nextTop int64
}

func newFakeAdapter(dir string) *fakeAdapter {
	f := &fakeAdapter{dir: dir, nextMsg: 5000, nextTop: 100}
	if dir != "" {
		entries, _ := os.ReadDir(filepath.Join(dir, "outbound"))
		f.seq = len(entries)
		f.nextMsg += int64(len(entries))
		f.nextTop += int64(len(entries))
	}
	return f
}

func (f *fakeAdapter) push(message inbound) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.queue = append(f.queue, message)
}

func (f *fakeAdapter) outputs() []fakeOut {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeOut(nil), f.outs...)
}

func (f *fakeAdapter) Me(context.Context) (string, error) { return "fake", nil }

func (f *fakeAdapter) Poll(ctx context.Context, offset int64) ([]inbound, error) {
	f.mu.Lock()
	var result, keep []inbound
	for _, message := range f.queue {
		if message.UpdateID >= offset {
			result = append(result, message)
			keep = append(keep, message)
		}
	}
	f.queue = keep
	f.mu.Unlock()
	if f.dir != "" {
		files, err := f.pollFiles(offset)
		if err != nil {
			return nil, err
		}
		result = append(result, files...)
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].UpdateID < result[j].UpdateID })
	if len(result) == 0 && f.dir != "" {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}
	return result, nil
}

// pollFiles mirrors Telegram: files below the offset are confirmed (deleted),
// the rest are returned again until the offset passes them.
func (f *fakeAdapter) pollFiles(offset int64) ([]inbound, error) {
	dir := filepath.Join(f.dir, "inbound")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var result []inbound
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var message inbound
		if err := json.Unmarshal(data, &message); err != nil {
			return nil, fmt.Errorf("fake inbound %s: %w", entry.Name(), err)
		}
		if message.UpdateID < offset {
			_ = os.Remove(path)
			continue
		}
		message.IsCommand = message.IsCommand || strings.HasPrefix(message.Text, "/")
		result = append(result, message)
	}
	return result, nil
}

func (f *fakeAdapter) record(out fakeOut) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seq++
	out.Seq = f.seq
	f.outs = append(f.outs, out)
	if f.dir == "" {
		return nil
	}
	dir := filepath.Join(f.dir, "outbound")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	data, err := json.Marshal(out)
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, fmt.Sprintf(".%06d.tmp", out.Seq))
	if err := os.WriteFile(tmp, append(data, '\n'), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, fmt.Sprintf("%06d.json", out.Seq)))
}

func (f *fakeAdapter) newMessageID() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextMsg++
	return f.nextMsg
}

func (f *fakeAdapter) Post(_ context.Context, threadID int64, text string, replyTo int64) (int64, error) {
	id := f.newMessageID()
	return id, f.record(fakeOut{Method: "post", Thread: threadID, Text: text, ReplyTo: replyTo, MessageID: id})
}

func (f *fakeAdapter) PostDocument(_ context.Context, threadID int64, name string, data []byte, caption string) (int64, error) {
	id := f.newMessageID()
	return id, f.record(fakeOut{Method: "document", Thread: threadID, Name: name, Data: append([]byte(nil), data...), Caption: caption, MessageID: id})
}

func (f *fakeAdapter) CreateTopic(_ context.Context, name string) (int64, error) {
	f.mu.Lock()
	f.nextTop++
	thread := f.nextTop
	f.mu.Unlock()
	return thread, f.record(fakeOut{Method: "createTopic", Thread: thread, Name: name})
}

func (f *fakeAdapter) CloseTopic(_ context.Context, threadID int64) error {
	return f.record(fakeOut{Method: "closeTopic", Thread: threadID})
}
