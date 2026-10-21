package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type tgCall struct {
	Method string
	JSON   map[string]any
	Form   map[string]string
	File   []byte
	Name   string
}

type tgServer struct {
	mu      sync.Mutex
	calls   []tgCall
	replies map[string][]func(http.ResponseWriter) // scripted replies per method, consumed in order
	server  *httptest.Server
}

func newTGServer(t *testing.T) *tgServer {
	s := &tgServer{replies: make(map[string][]func(http.ResponseWriter))}
	s.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/botTOKEN/") {
			http.Error(w, "bad token path", 404)
			return
		}
		call := tgCall{Method: strings.TrimPrefix(r.URL.Path, "/botTOKEN/")}
		if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
			if err := r.ParseMultipartForm(1 << 20); err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			call.Form = map[string]string{}
			for key, values := range r.MultipartForm.Value {
				call.Form[key] = values[0]
			}
			if files := r.MultipartForm.File["document"]; len(files) == 1 {
				f, _ := files[0].Open()
				call.File, _ = io.ReadAll(f)
				call.Name = files[0].Filename
				f.Close()
			}
		} else {
			_ = json.NewDecoder(r.Body).Decode(&call.JSON)
		}
		s.mu.Lock()
		s.calls = append(s.calls, call)
		var reply func(http.ResponseWriter)
		if queue := s.replies[call.Method]; len(queue) > 0 {
			reply = queue[0]
			s.replies[call.Method] = queue[1:]
		}
		s.mu.Unlock()
		if reply != nil {
			reply(w)
			return
		}
		switch call.Method {
		case "getMe":
			io.WriteString(w, `{"ok":true,"result":{"id":5,"is_bot":true,"username":"khala_test_bot"}}`)
		case "getUpdates":
			io.WriteString(w, `{"ok":true,"result":[]}`)
		case "createForumTopic":
			io.WriteString(w, `{"ok":true,"result":{"message_thread_id":321,"name":"x"}}`)
		default:
			io.WriteString(w, `{"ok":true,"result":{"message_id":777}}`)
		}
	}))
	t.Cleanup(s.server.Close)
	return s
}

func (s *tgServer) script(method string, replies ...func(http.ResponseWriter)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.replies[method] = append(s.replies[method], replies...)
}

func (s *tgServer) got() []tgCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]tgCall(nil), s.calls...)
}

func reply(status int, body string) func(http.ResponseWriter) {
	return func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		io.WriteString(w, body)
	}
}

func newTestTelegram(t *testing.T, s *tgServer) (*telegramAdapter, *[]time.Duration) {
	var slept []time.Duration
	a := newTelegramAdapter(s.server.URL, "TOKEN", -100, 30, log.New(io.Discard, "", 0))
	a.sleep = func(ctx context.Context, d time.Duration) error {
		slept = append(slept, d)
		return ctx.Err()
	}
	return a, &slept
}

const tgUpdates = `{"ok":true,"result":[
 {"update_id":42,"message":{"message_id":10,"message_thread_id":77,"is_topic_message":true,"from":{"id":1},"chat":{"id":-100},"text":"hello"}},
 {"update_id":43,"message":{"message_id":11,"from":{"id":1},"chat":{"id":-999},"text":"other chat"}},
 {"update_id":44,"message":{"message_id":12,"message_thread_id":10,"from":{"id":1},"chat":{"id":-100},"text":"/sessions","entities":[{"type":"bot_command","offset":0,"length":9}]}},
 {"update_id":45,"message":{"message_id":13,"message_thread_id":77,"is_topic_message":true,"from":{"id":1},"chat":{"id":-100},"forum_topic_created":{"name":"x"}}},
 {"update_id":46,"message":{"message_id":14,"message_thread_id":77,"is_topic_message":true,"from":{"id":1},"chat":{"id":-100},"photo":[{"file_id":"a"}]}},
 {"update_id":47,"edited_message":{"message_id":10}}
]}`

func TestTelegramGetUpdatesParamsAndChatFilter(t *testing.T) {
	s := newTGServer(t)
	s.script("getUpdates", reply(200, tgUpdates))
	a, _ := newTestTelegram(t, s)
	got, err := a.Poll(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	call := s.got()[0]
	if call.Method != "getUpdates" || call.JSON["offset"] != float64(42) || call.JSON["timeout"] != float64(30) {
		t.Fatalf("getUpdates request = %+v", call)
	}
	if allowed, _ := json.Marshal(call.JSON["allowed_updates"]); string(allowed) != `["message"]` {
		t.Fatalf("allowed_updates = %s", allowed)
	}
	if len(got) != 6 {
		t.Fatalf("got %d inbound, want 6 (every update id reported)", len(got))
	}
	if got[0].Ignore || got[0].ThreadID != 77 || got[0].MessageID != 10 || got[0].UserID != 1 || got[0].Text != "hello" || got[0].UpdateID != 42 {
		t.Fatalf("topic message = %+v", got[0])
	}
	if !got[1].Ignore {
		t.Fatalf("other chat not ignored: %+v", got[1])
	}
	// A reply in General carries message_thread_id without is_topic_message: that is General.
	if got[2].Ignore || got[2].ThreadID != 0 || !got[2].IsCommand {
		t.Fatalf("General command = %+v", got[2])
	}
	if !got[3].Ignore {
		t.Fatalf("service message not ignored: %+v", got[3])
	}
	if got[4].Ignore || got[4].Text != "" {
		t.Fatalf("photo = %+v", got[4])
	}
	if !got[5].Ignore || got[5].UpdateID != 47 {
		t.Fatalf("edited message = %+v", got[5])
	}
}

func TestTelegramSendMessagePayload(t *testing.T) {
	s := newTGServer(t)
	a, _ := newTestTelegram(t, s)
	id, err := a.Post(context.Background(), 77, "plain *text* <b>", 55)
	if err != nil || id != 777 {
		t.Fatalf("Post = %d, %v", id, err)
	}
	if _, err := a.Post(context.Background(), 0, "general", 0); err != nil {
		t.Fatal(err)
	}
	calls := s.got()
	body := calls[0].JSON
	if calls[0].Method != "sendMessage" || body["chat_id"] != float64(-100) || body["message_thread_id"] != float64(77) || body["text"] != "plain *text* <b>" {
		t.Fatalf("sendMessage = %+v", body)
	}
	if _, ok := body["parse_mode"]; ok {
		t.Fatal("parse_mode must not be sent")
	}
	params, _ := body["reply_parameters"].(map[string]any)
	if params["message_id"] != float64(55) || params["allow_sending_without_reply"] != true {
		t.Fatalf("reply_parameters = %v", body["reply_parameters"])
	}
	if _, ok := calls[1].JSON["message_thread_id"]; ok {
		t.Fatalf("General post carries a thread id: %v", calls[1].JSON)
	}
	if _, ok := calls[1].JSON["reply_parameters"]; ok {
		t.Fatalf("unthreaded post carries reply_parameters: %v", calls[1].JSON)
	}
}

func TestTelegramSendDocumentMultipart(t *testing.T) {
	s := newTGServer(t)
	a, _ := newTestTelegram(t, s)
	caption := strings.Repeat("c", 1500)
	if _, err := a.PostDocument(context.Background(), 77, "reply.md", []byte("# body\n"), caption); err != nil {
		t.Fatal(err)
	}
	call := s.got()[0]
	if call.Method != "sendDocument" || call.Form["chat_id"] != "-100" || call.Form["message_thread_id"] != "77" || call.Name != "reply.md" || string(call.File) != "# body\n" {
		t.Fatalf("sendDocument = %+v", call)
	}
	if len([]rune(call.Form["caption"])) != 1024 {
		t.Fatalf("caption length = %d, want capped at 1024", len([]rune(call.Form["caption"])))
	}
}

func TestTelegramTopicsAndGetMe(t *testing.T) {
	s := newTGServer(t)
	a, _ := newTestTelegram(t, s)
	name, err := a.Me(context.Background())
	if err != nil || name != "khala_test_bot" {
		t.Fatalf("Me = %q %v", name, err)
	}
	thread, err := a.CreateTopic(context.Background(), "alpha@gw")
	if err != nil || thread != 321 {
		t.Fatalf("CreateTopic = %d %v", thread, err)
	}
	if err := a.CloseTopic(context.Background(), 321); err != nil {
		t.Fatal(err)
	}
	calls := s.got()
	if calls[1].JSON["name"] != "alpha@gw" || calls[2].Method != "closeForumTopic" || calls[2].JSON["message_thread_id"] != float64(321) {
		t.Fatalf("topic calls = %+v", calls)
	}
}

func TestTelegram429HonoursRetryAfter(t *testing.T) {
	s := newTGServer(t)
	s.script("sendMessage", reply(429, `{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 7","parameters":{"retry_after":7}}`))
	a, slept := newTestTelegram(t, s)
	if _, err := a.Post(context.Background(), 1, "x", 0); err != nil {
		t.Fatal(err)
	}
	if len(*slept) != 1 || (*slept)[0] != 7*time.Second || len(s.got()) != 2 {
		t.Fatalf("slept=%v calls=%d", *slept, len(s.got()))
	}
	// getUpdates does not retry internally; the error carries retry_after for the loop.
	s.script("getUpdates", reply(429, `{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":9}}`))
	_, err := a.Poll(context.Background(), 0)
	if err == nil || retryAfter(err) != 9*time.Second {
		t.Fatalf("poll 429: err=%v retryAfter=%v", err, retryAfter(err))
	}
}

func TestTelegram5xxBackoff(t *testing.T) {
	s := newTGServer(t)
	s.script("sendMessage", reply(500, `{"ok":false,"error_code":500,"description":"Internal"}`), reply(502, "bad gateway"), reply(503, "x"))
	a, slept := newTestTelegram(t, s)
	if _, err := a.Post(context.Background(), 1, "x", 0); err != nil {
		t.Fatal(err)
	}
	want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second}
	if len(*slept) != 3 || (*slept)[0] != want[0] || (*slept)[1] != want[1] || (*slept)[2] != want[2] {
		t.Fatalf("backoff = %v", *slept)
	}
	// Permanent 4xx is not retried.
	s.script("sendMessage", reply(400, `{"ok":false,"error_code":400,"description":"Bad Request: message thread not found"}`))
	_, err := a.Post(context.Background(), 1, "x", 0)
	if err == nil || !isPermanent(err) || !strings.Contains(err.Error(), "thread not found") {
		t.Fatalf("400: %v", err)
	}
	// The backoff sequence is capped at 60 s.
	d := time.Duration(0)
	for i := 0; i < 10; i++ {
		d = nextBackoff(d)
	}
	if d != 60*time.Second || nextBackoff(0) != time.Second {
		t.Fatalf("nextBackoff cap = %v", d)
	}
}

func TestTelegramErrorsDoNotLeakToken(t *testing.T) {
	s := newTGServer(t)
	a, _ := newTestTelegram(t, s)
	s.server.Close()
	_, err := a.Poll(context.Background(), 0)
	if err == nil || strings.Contains(err.Error(), "TOKEN") {
		t.Fatalf("error leaks token or is nil: %v", err)
	}
}

func telegramGateway(t *testing.T, s *tgServer, khalaBin string) (*gateway, *bytes.Buffer, string) {
	home := gatewayNode(t, "gw")
	writeGatewayConf(t, home, "adapter telegram\ntelegram token TOKEN\ntelegram chat -100\ntelegram allow 1 3\nkhala bin "+khalaBin+"\n", 0600)
	conf, err := loadGatewayConf(home)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := newTestTelegram(t, s)
	logs := &bytes.Buffer{}
	g, err := newGateway(home, conf, a, log.New(logs, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	g.st.Topics["alpha@gw"] = 77
	return g, logs, home
}

func TestTelegramAllowListEnforced(t *testing.T) {
	s := newTGServer(t)
	s.script("getUpdates", reply(200, `{"ok":true,"result":[
 {"update_id":60,"message":{"message_id":1,"message_thread_id":77,"is_topic_message":true,"from":{"id":2},"chat":{"id":-100},"text":"intruder"}},
 {"update_id":61,"message":{"message_id":2,"message_thread_id":77,"is_topic_message":true,"from":{"id":2},"chat":{"id":-100},"text":"intruder again"}},
 {"update_id":62,"message":{"message_id":3,"from":{"id":2},"chat":{"id":-100},"text":"/open alpha@gw"}}
]}`))
	g, logs, home := telegramGateway(t, s, khalaBinary(t))
	if err := g.pollOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if g.st.Offset != 63 {
		t.Fatalf("offset = %d, want 63", g.st.Offset)
	}
	if n := len(listFiles(t, filepath.Join(home, "outbox", "new"))); n != 0 {
		t.Fatalf("disallowed sender produced %d messages", n)
	}
	if n := strings.Count(logs.String(), "not in telegram allow"); n != 1 {
		t.Fatalf("allow-list log lines = %d, want 1:\n%s", n, logs.String())
	}
	for _, call := range s.got() {
		if call.Method != "getUpdates" {
			t.Fatalf("disallowed sender caused %s", call.Method)
		}
	}
}

func TestTelegramOffsetHeldWhenSendFails(t *testing.T) {
	failing := filepath.Join(t.TempDir(), "khala")
	if err := os.WriteFile(failing, []byte("#!/bin/sh\necho 'simulated failure' >&2\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	s := newTGServer(t)
	updates := `{"ok":true,"result":[{"update_id":90,"message":{"message_id":5,"message_thread_id":77,"is_topic_message":true,"from":{"id":1},"chat":{"id":-100},"text":"please run"}}]}`
	s.script("getUpdates", reply(200, updates), reply(200, updates))
	g, _, _ := telegramGateway(t, s, failing)
	g.st.Offset = 90
	if err := g.pollOnce(context.Background()); err == nil {
		t.Fatal("pollOnce succeeded although khala send failed")
	}
	if g.st.Offset != 90 {
		t.Fatalf("offset advanced to %d after a failed send", g.st.Offset)
	}
	saved, _ := loadGatewayState(g.home)
	if saved.Offset > 90 {
		t.Fatalf("saved offset advanced to %d", saved.Offset)
	}
	// The next poll asks for the same update again.
	_ = g.pollOnce(context.Background())
	calls := s.got()
	if calls[len(calls)-1].JSON["offset"] != float64(90) {
		t.Fatalf("second getUpdates offset = %v", calls[len(calls)-1].JSON["offset"])
	}
}
