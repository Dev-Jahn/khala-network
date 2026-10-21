package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Telegram Bot API adapter over net/http + encoding/json. No library: the
// polling loop must confirm an update (advance the offset) only after the
// gateway handed it to khala, which the reviewed library does not allow.

const (
	telegramAPIBase       = "https://api.telegram.org"
	telegramCaptionLimit  = 1024
	telegramMaxAttempts   = 10
	telegramMaxBackoff    = 60 * time.Second
	telegramResponseLimit = 8 << 20
)

type telegramAdapter struct {
	base    string
	token   string
	chat    int64
	timeout int
	client  *http.Client
	log     *log.Logger
	sleep   func(context.Context, time.Duration) error
}

func newTelegramAdapter(base, token string, chat int64, pollTimeout int, logger *log.Logger) *telegramAdapter {
	return &telegramAdapter{
		base: strings.TrimRight(base, "/"), token: token, chat: chat, timeout: pollTimeout, log: logger,
		client: &http.Client{Timeout: time.Duration(pollTimeout)*time.Second + 30*time.Second},
		sleep:  sleepContext,
	}
}

// telegramError is a Bot API failure. Status 0 means the request never got
// an HTTP answer (network error).
type telegramError struct {
	method     string
	status     int
	desc       string
	retryAfter time.Duration
}

func (e *telegramError) Error() string {
	if e.status == 0 {
		return fmt.Sprintf("telegram %s: %s", e.method, e.desc)
	}
	return fmt.Sprintf("telegram %s: HTTP %d: %s", e.method, e.status, e.desc)
}

// retryAfter returns the server-requested delay of a 429, else 0.
func retryAfter(err error) time.Duration {
	var te *telegramError
	if errors.As(err, &te) && te.status == http.StatusTooManyRequests {
		if te.retryAfter <= 0 {
			return time.Second
		}
		return te.retryAfter
	}
	return 0
}

// isPermanent reports a client error that a retry cannot fix.
func isPermanent(err error) bool {
	var te *telegramError
	return errors.As(err, &te) && te.status >= 400 && te.status < 500 && te.status != http.StatusTooManyRequests
}

func nextBackoff(previous time.Duration) time.Duration {
	if previous <= 0 {
		return time.Second
	}
	if previous*2 > telegramMaxBackoff {
		return telegramMaxBackoff
	}
	return previous * 2
}

type telegramEnvelope struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	ErrorCode   int             `json:"error_code"`
	Description string          `json:"description"`
	Parameters  struct {
		RetryAfter int `json:"retry_after"`
	} `json:"parameters"`
}

// call performs one request. body is JSON-encoded unless it is a *multipartBody.
func (t *telegramAdapter) call(ctx context.Context, method string, body any, result any) error {
	var reader io.Reader
	contentType := "application/json"
	if mp, ok := body.(*multipartBody); ok {
		reader = bytes.NewReader(mp.data)
		contentType = mp.contentType
	} else {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, t.base+"/bot"+t.token+"/"+method, reader)
	if err != nil {
		return &telegramError{method: method, desc: t.scrub(err.Error())}
	}
	request.Header.Set("Content-Type", contentType)
	response, err := t.client.Do(request)
	if err != nil {
		return &telegramError{method: method, desc: t.scrub(err.Error())}
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, telegramResponseLimit))
	if err != nil {
		return &telegramError{method: method, status: response.StatusCode, desc: t.scrub(err.Error())}
	}
	var envelope telegramEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		if response.StatusCode == http.StatusOK {
			return &telegramError{method: method, status: 502, desc: "response is not JSON"}
		}
		return &telegramError{method: method, status: response.StatusCode, desc: http.StatusText(response.StatusCode)}
	}
	if response.StatusCode != http.StatusOK || !envelope.OK {
		status := response.StatusCode
		if status == http.StatusOK {
			status = envelope.ErrorCode
		}
		return &telegramError{method: method, status: status, desc: t.scrub(envelope.Description), retryAfter: time.Duration(envelope.Parameters.RetryAfter) * time.Second}
	}
	if result == nil {
		return nil
	}
	if err := json.Unmarshal(envelope.Result, result); err != nil {
		return &telegramError{method: method, status: 502, desc: "unexpected result: " + err.Error()}
	}
	return nil
}

// scrub removes the bot token from text that may embed the request URL.
func (t *telegramAdapter) scrub(text string) string {
	if t.token == "" {
		return text
	}
	return strings.ReplaceAll(text, t.token, "<token>")
}

// callRetry retries 429 after retry_after and 5xx/network errors with
// exponential backoff (1 s .. 60 s), at most telegramMaxAttempts times.
func (t *telegramAdapter) callRetry(ctx context.Context, method string, body any, result any) error {
	backoff := time.Duration(0)
	var err error
	for attempt := 1; attempt <= telegramMaxAttempts; attempt++ {
		err = t.call(ctx, method, body, result)
		if err == nil || isPermanent(err) || ctx.Err() != nil {
			return err
		}
		delay := retryAfter(err)
		if delay == 0 {
			backoff = nextBackoff(backoff)
			delay = backoff
		}
		if t.log != nil {
			t.log.Printf("%v; retry %d in %s", err, attempt, delay)
		}
		if sleepErr := t.sleep(ctx, delay); sleepErr != nil {
			return err
		}
	}
	return err
}

func (t *telegramAdapter) Me(ctx context.Context) (string, error) {
	var me struct {
		Username string `json:"username"`
	}
	if err := t.callRetry(ctx, "getMe", map[string]any{}, &me); err != nil {
		return "", err
	}
	return me.Username, nil
}

type telegramUpdate struct {
	UpdateID int64                      `json:"update_id"`
	Message  map[string]json.RawMessage `json:"message"`
}

type telegramMessageCore struct {
	MessageID      int64  `json:"message_id"`
	ThreadID       int64  `json:"message_thread_id"`
	IsTopicMessage bool   `json:"is_topic_message"`
	Text           string `json:"text"`
	From           *struct {
		ID    int64 `json:"id"`
		IsBot bool  `json:"is_bot"`
	} `json:"from"`
	Chat struct {
		ID int64 `json:"id"`
	} `json:"chat"`
	Entities []struct {
		Type   string `json:"type"`
		Offset int    `json:"offset"`
	} `json:"entities"`
}

// Keys that make a message user content that is not text (answered with
// "only text is relayed"). Anything else without text is a service message.
var telegramMediaKeys = []string{"photo", "document", "video", "audio", "voice", "sticker", "animation", "video_note", "contact", "location", "venue", "poll", "dice", "caption"}

// Poll issues one getUpdates. It does not retry: the caller's loop owns the
// backoff so it can keep the offset discipline. Every update comes back
// (possibly with Ignore) so the offset can pass it.
func (t *telegramAdapter) Poll(ctx context.Context, offset int64) ([]inbound, error) {
	var updates []telegramUpdate
	request := map[string]any{"offset": offset, "timeout": t.timeout, "allowed_updates": []string{"message"}}
	if err := t.call(ctx, "getUpdates", request, &updates); err != nil {
		return nil, err
	}
	result := make([]inbound, 0, len(updates))
	for _, update := range updates {
		result = append(result, t.convert(update))
	}
	return result, nil
}

func (t *telegramAdapter) convert(update telegramUpdate) inbound {
	in := inbound{UpdateID: update.UpdateID, Ignore: true}
	if update.Message == nil {
		return in
	}
	raw, err := json.Marshal(update.Message)
	if err != nil {
		return in
	}
	var core telegramMessageCore
	if err := json.Unmarshal(raw, &core); err != nil {
		if t.log != nil {
			t.log.Printf("update %d: malformed message skipped: %v", update.UpdateID, err)
		}
		return in
	}
	if core.Chat.ID != t.chat || core.From == nil || core.From.IsBot {
		return in
	}
	in.MessageID = core.MessageID
	in.UserID = core.From.ID
	// In a forum, message_thread_id without is_topic_message is a reply
	// inside General (it names the replied-to message), so General is 0.
	if core.IsTopicMessage {
		in.ThreadID = core.ThreadID
	}
	_, hasText := update.Message["text"]
	media := false
	for _, key := range telegramMediaKeys {
		if _, ok := update.Message[key]; ok {
			media = true
		}
	}
	if !hasText && !media {
		return in // service message: topic created/closed, members, pins
	}
	in.Ignore = false
	in.Text = core.Text
	for _, entity := range core.Entities {
		if entity.Type == "bot_command" && entity.Offset == 0 {
			in.IsCommand = true
		}
	}
	return in
}

func (t *telegramAdapter) Post(ctx context.Context, threadID int64, text string, replyTo int64) (int64, error) {
	request := map[string]any{"chat_id": t.chat, "text": text}
	if threadID > 1 {
		request["message_thread_id"] = threadID
	}
	if replyTo > 0 {
		request["reply_parameters"] = map[string]any{"message_id": replyTo, "allow_sending_without_reply": true}
	}
	var message struct {
		MessageID int64 `json:"message_id"`
	}
	if err := t.callRetry(ctx, "sendMessage", request, &message); err != nil {
		return 0, err
	}
	return message.MessageID, nil
}

type multipartBody struct {
	data        []byte
	contentType string
}

func (t *telegramAdapter) PostDocument(ctx context.Context, threadID int64, name string, data []byte, caption string) (int64, error) {
	if runes := []rune(caption); len(runes) > telegramCaptionLimit {
		caption = string(runes[:telegramCaptionLimit])
	}
	var buffer bytes.Buffer
	writer := multipart.NewWriter(&buffer)
	fields := [][2]string{{"chat_id", strconv.FormatInt(t.chat, 10)}}
	if threadID > 1 {
		fields = append(fields, [2]string{"message_thread_id", strconv.FormatInt(threadID, 10)})
	}
	if caption != "" {
		fields = append(fields, [2]string{"caption", caption})
	}
	for _, field := range fields {
		if err := writer.WriteField(field[0], field[1]); err != nil {
			return 0, err
		}
	}
	part, err := writer.CreateFormFile("document", name)
	if err != nil {
		return 0, err
	}
	if _, err := part.Write(data); err != nil {
		return 0, err
	}
	if err := writer.Close(); err != nil {
		return 0, err
	}
	var message struct {
		MessageID int64 `json:"message_id"`
	}
	body := &multipartBody{data: buffer.Bytes(), contentType: writer.FormDataContentType()}
	if err := t.callRetry(ctx, "sendDocument", body, &message); err != nil {
		return 0, err
	}
	return message.MessageID, nil
}

func (t *telegramAdapter) CreateTopic(ctx context.Context, name string) (int64, error) {
	var topic struct {
		ThreadID int64 `json:"message_thread_id"`
	}
	if err := t.callRetry(ctx, "createForumTopic", map[string]any{"chat_id": t.chat, "name": name}, &topic); err != nil {
		return 0, err
	}
	if topic.ThreadID <= 1 {
		return 0, fmt.Errorf("telegram createForumTopic returned thread id %d", topic.ThreadID)
	}
	return topic.ThreadID, nil
}

func (t *telegramAdapter) CloseTopic(ctx context.Context, threadID int64) error {
	return t.callRetry(ctx, "closeForumTopic", map[string]any{"chat_id": t.chat, "message_thread_id": threadID}, nil)
}
