# B-GW: `khala-link gateway` (0.10.0 lane) — report

Branch `task/d17-b-gateway`, base `2ca56a9` (review: D17-B r2 amendments).
Design: `review/d17-b-r1.md`, r2 section first (gateway node `gateway`, sender
`user`, `Type: message`, no `gateway-enqueue`, no `Origin` headers).

## What was built

| File | Content |
|---|---|
| `link/main.go` | one line: `case "gateway": return runGateway(args[1:])` |
| `link/gateway.go` | `runGateway` (`--home`, `--once`), single-instance lock `run/gateway.pid`, poll / send / inbox / status loops, General commands, chunking, rate limiter |
| `link/gateway_state.go` | strict `gateway.conf` parser, `gateway.state.json` (topics, threads, offset, status, notices) |
| `link/gateway_adapter.go` | `adapter` interface, `inbound`, `fakeAdapter` (in memory + `run/gateway-fake/{inbound,outbound}` file queues) |
| `link/telegram.go` | Bot API over `net/http` + `encoding/json`: getMe, getUpdates, sendMessage, sendDocument, createForumTopic, closeForumTopic |
| `link/gateway_test.go`, `link/telegram_test.go` | P1–P7 |
| `test/gateway.sh` | P8, end to end with the real CLI |
| `docs/GATEWAY.md` | setup, operation, limits, measurement table |

`go.mod`/`go.sum` unchanged (still only `fsnotify`). No existing file other than
`link/main.go` was touched.

## Evidence

RED — commit `e5f3ed7` (tests only):

```
$ go vet ./...
vet: ./gateway_test.go:72:3: undefined: gateway
```

Every P1–P7 test depends on the missing symbols, so the whole set failed to
build (RED by compilation). GREEN — commit `7217567` onward:

```
$ nice -n 19 taskset -c 20-71 go test -count=1 -v -p 2 -run 'Gateway|Telegram' .
--- PASS: TestGatewayP1ConfValidation
--- PASS: TestGatewaySingleInstance
--- PASS: TestGatewayP2InboundTopicMessageBecomesKhalaMessage
--- PASS: TestGatewayP2UnmappedTopicAndNonText
--- PASS: TestGatewayP3SessionReplyPostedToTopicAndAcked
--- PASS: TestGatewayP3BounceRepliesToOriginal
--- PASS: TestGatewayP4Chunking
--- PASS: TestGatewayRateLimiter
--- PASS: TestGatewayP5StatusPosts
--- PASS: TestGatewayP6GeneralCommands
--- PASS: TestGatewayStatePrunesOldThreads
--- PASS: TestTelegramGetUpdatesParamsAndChatFilter
--- PASS: TestTelegramSendMessagePayload
--- PASS: TestTelegramSendDocumentMultipart
--- PASS: TestTelegramTopicsAndGetMe
--- PASS: TestTelegram429HonoursRetryAfter
--- PASS: TestTelegram5xxBackoff
--- PASS: TestTelegramErrorsDoNotLeakToken
--- PASS: TestTelegramAllowListEnforced
--- PASS: TestTelegramOffsetHeldWhenSendFails
ok  github.com/Dev-Jahn/khala-network/link 1.380s
```

| Property | Test | What it proves |
|---|---|---|
| P1 | `TestGatewayP1ConfValidation`, `TestGatewaySingleInstance` | absent / 0644 / unknown key / malformed values / telegram without token → exit 2 with the reason; valid fake conf → `--once` exit 0 and `gateway: connected as @fake chat=0 topics=0` in `log/gateway.log`; a second lock on `run/gateway.pid` is refused, the file holds `pid`/`start` |
| P2 | `TestGatewayP2Inbound…`, `…UnmappedTopicAndNonText` | topic text → one file in `outbox/new` with `From: user@gw`, `Type: message`, subject = first 80 runes of line 1, body = full text; ledger `requests/send/user/tg-500`; `threads[Id]` = thread/message/update; offset 501 saved (0600 file). Replay of update 500 → still one message, offset 501. Unlinked topic → "/open" hint as a reply; empty text → "Only text" |
| P3 | `TestGatewayP3SessionReply…`, `…BounceRepliesToOriginal` | `alpha` → `user@gw` via real `khala send` + `reconcile`: createTopic `alpha@gw` then post in it, message moved to `inbox/user/cur`; rescan does not repost; a `--reply-to` of the gateway's message → post with `ReplyTo` = the original Telegram message id. Bounce → `not delivered: Delivery expired for alpha@far` as a reply to the original, acked |
| P4 | `TestGatewayP4Chunking`, `TestGatewayRateLimiter` | `utf16Len("가😀a") = 4`; 5000 Korean chars → 2 chunks ≤ 4096 units, lossless; 2047 emoji + "ab" (= 4096) → 1 piece, 2048 emoji + "a" (4097) → 2 valid UTF-8 pieces; via the sender: 2 posts (reply id only on the first), 20000 chars with chunk-limit 3 → 1 `.md` document with a 300-rune caption. 50 posts → never more than 20 in any 60 s window |
| P5 | `TestGatewayP5StatusPosts` | fabricated snapshot: `connected` once; no repeat 10 min later; `pending-ring 1` + first-seen 900 s old → `stalled: unread for 15 min`; no repeat; snapshot removed → no post within 5 min of the last one, then `disconnected`; listed again → `connected`; same snapshot 11 min later (stale) → `disconnected` |
| P6 | `TestGatewayP6GeneralCommands` | `/sessions` lists `alpha@gw — connected (0 unread)` and `beta@gw — connected (2 unread)`; `/open bad` → usage; `/open alpha@nowhere` → no listener snapshot; `/open@bot alpha@gw` → CreateTopic + mapping saved; twice → already open; `/notices` → state; `/say general …` → a stream entry `….user@gw` with the text (real CLI); `/close` → CloseTopic + mapping gone; plain text → nothing, offset advanced; unknown command → hint; General as thread 1 also works |
| P7 | `TestTelegram*` | getUpdates body `offset`, `timeout=30`, `allowed_updates=["message"]`; other chat, service message, edited message → `Ignore` (offset still passes them); a reply inside General (thread id without `is_topic_message`) → thread 0; sendMessage: `chat_id`, `message_thread_id`, `reply_parameters{message_id, allow_sending_without_reply}`, no `parse_mode`, no thread id for General; sendDocument multipart with `document` file and caption capped at 1024; 429 → sleeps exactly `retry_after` then succeeds; 500/502/503 → 1 s, 2 s, 4 s then success; 400 → no retry; backoff cap 60 s; network error text does not contain the token; allow-list: 3 updates from a non-allowed user → 0 messages, 0 posts, 1 log line, offset 63; failing `khala` script (exit 1) → `pollOnce` error, offset stays 90 in memory and on disk, next getUpdates asks for 90 again |
| P8 | `test/gateway.sh` | below |
| P9 | below | vet, full suite, 4 static builds, go.mod unchanged |

P8:

```
$ nice -n 19 taskset -c 20-71 bash test/gateway.sh
ok 0 — built khala-link and initialized node gw
ok 1 — absent gateway.conf → rc 2
ok 2 — daemon started; a second poller is refused
ok 3 — /open alpha@gw → topic 101, status connected
ok 4 — topic message → 1790151079.3085820.13632.user@gw (From: user@gw, request tg-2)
ok 5 — delivered to alpha; alpha replied 1790151079.3085988.32340.alpha@gw
ok 6 — reply posted to topic 101 with reply_to 20 and acknowledged
ok 7 — SIGTERM → rc 0, state saved (offset 3, topic, thread, status)
RESULT: PASS
```

(Step 7 also re-injects the already confirmed update 2: no new message, the
inbound file is removed, `outbox/acked` holds exactly the two messages.)

P9:

```
$ go vet ./...                                  # clean
$ go test -count=1 -p 2 ./...                   # ok  github.com/Dev-Jahn/khala-network/link 15.5-16.3s, 12 of 13 runs
$ CGO_ENABLED=1 go test -race -run 'Gateway|Telegram' .   # ok (race detector, test-only cgo)
$ GOOS={linux,darwin} GOARCH={amd64,arm64} CGO_ENABLED=0 go build   # 4 × ok; linux/amd64 "statically linked"
$ git diff 2ca56a9 -- link/go.mod link/go.sum   # empty
```

One of 13 full-suite runs (after the last commit's change) failed once and did
not reproduce in the next 11 runs. The truncated output ended in `owner no` /
`epoch 1`, which is the stdout of `runtime register` in the existing runtime
tests; no gateway test prints that. The failing test name was lost to `tail`.
It looks like a pre-existing timing flake in the runtime-register tests, not a
gateway regression; if it shows up again, rerun with `-v` and keep the full
output. The gateway and Telegram tests passed in all 13 runs and under `-race`.

`TestGatewayFailedPostIsHeldAndTopicForgotten` (added with decision 7) covers
a permanent post failure: the topic mapping is dropped, the message stays
unread, and the Id is held so the 1 s inbox tick does not retry it at once.

All Go commands ran with `PATH=/NHNHOME/jahn/go-toolchain/bin:$PATH
GOCACHE=/NHNHOME/jahn/.cache/khala-go-cache-gateway CGO_ENABLED=0 GOMAXPROCS=8`
under `nice -n 19 taskset -c 20-71`.

## Decisions where the design was silent

1. **Adapter interface.** The brief's interface plus `Me` (getMe at startup) and
   an `offset` argument on `Poll`: the gateway owns the offset and the adapter
   stays stateless, which is what makes "confirm only after khala returned an
   Id" testable. `inbound` gained `Ignore` so ignored updates (other chat,
   service messages, edits) still advance the offset.
2. **General topic.** Measured-by-design: the adapter maps any message without
   `is_topic_message` to thread 0 (in forums a reply inside General carries the
   replied-to message id as `message_thread_id`); the core accepts 0 and 1 as
   General. Posts to General omit `message_thread_id`. Topic threads from
   `createForumTopic` ≤ 1 are rejected. Live check: measurement item 1.
3. **Replies.** `reply_parameters` with `allow_sending_without_reply: true`
   instead of the older `reply_to_message_id`: a deleted original must not make
   the post fail. A subject is shown as `[subject]` on the first line.
4. **Chunk split.** Line boundaries, newline dropped between chunks; an
   over-long line is split at rune boundaries. The reply id goes on the first
   chunk only. No `(i/n)` prefix (r1 §4.3 had one; r2 did not mention it, and it
   would eat into the limit).
5. **Status clock.** `oldest-pending`, else `first-seen`, else the time the
   gateway first saw `pending-ring > 0` (persisted as `pending_since`). A
   snapshot in `state stopping` or a truncated snapshot without the session
   changes nothing; a session listed with `route=none` is `disconnected`.
   The 5-minute spacing applies to every change, including the first
   `disconnected` after a `stalled` (P5 shows the delayed post). A newly opened
   topic gets its first status right after the command is handled.
6. **Inbox relay.** `inbox list` is the index; only Ids still in
   `inbox/user/new` are relayed (list also shows `cur`). Types relayed:
   `message` (and `operator`) → sender's topic, `bounce` → "not delivered"
   reply; anything else (notices) is acked without a post and logged. Posting
   is at least once: ack-read runs after the post.
7. **Failure handling.** A failed khala send stops the batch and the loop
   retries the same update with backoff (1..60 s); later updates wait behind
   it (strict order). A permanent Telegram 4xx on a post (for example
   `message thread not found`, `TOPIC_CLOSED`) logs, forgets the topic mapping
   and leaves the khala message unread; that Id is held out of rescans for
   60 s, then the topic is recreated and the post retried. Other failed posts
   also stay unread and are retried after the same 60 s hold (no hot loop).
8. **Rate limit.** A sliding 60-second window of 20 posts for the whole chat
   (topic creation counts). The 1-per-second advice of r1 was not added.
9. **Expiry.** Every user message is sent with `-e <user expires>` (default
   259200), so expiry → the existing `expire_outbox` bounce → "not delivered".
10. **`khala bin`** is a required config key (absolute path); the CLI runs with
    `KHALA_HOME=<home>`, `KHALA_SESSION=user`, cwd = home, 75 s timeout. No
    `--as`, so the gateway does not trigger the `--as` warning.
11. **Logging.** `log/gateway.log` (rotating 1 MiB, same writer as link.log)
    and stderr, prefix `gateway: `. Telegram errors never include the token.
12. **Exit codes.** 2 = usage/config (conf absent, bad mode, unknown key,
    not a khala node); 1 = runtime start failure (lock held, getMe failed,
    unreadable state file). A corrupt `gateway.state.json` is an error, not an
    empty start, so a lost topic mapping is noticed.
13. **Fake adapter files.** `run/gateway-fake/inbound/<n>.json`
    (`update_id`, `thread_id`, `message_id`, `user_id`, `text`) behave like
    Telegram: returned until the offset passes them, then deleted.
    `outbound/<seq>.json` records every post/document/createTopic/closeTopic.

## Needed from the B-CLI lane before a live run

1. Add `user` to `reserved_name` (no session may take it) and
   `hidden_reserved_name` (the gateway's CLI calls write `presence/user@gateway`
   heartbeats; keep them off the presence table), but allow `KHALA_SESSION=user`
   for `send`, `say`, `inbox list|read|ack-read` **only on a node that has
   `gateway.conf`** (the check at `session_name`, bin/khala:346).
2. Keep `user` a valid recipient (`recipient_reserved_name` must not list it):
   sessions reply with `khala send user@gateway --reply-to <Id>`.
3. SKILL/drain wording that `From: user@gateway` is the user (design r2 §2, §3.4
   text adapted to `Type: message`).
4. Optional: `khala node ensure` service for the gateway (design §4.1). Until
   then use the launchd plists in `docs/GATEWAY.md`.

Today the gateway works with the current CLI because `user` is not reserved:
`KHALA_SESSION=user` is accepted without a warning. The warning
`khala send --as: 세션이 아닌 발신자라면 khala notify를 쓰세요` appears only with
`--as`, which the gateway does not use; a manual `khala send --as user` test
prints it and succeeds.

Also B-CONDUIT: `isReservedIdentity`/`skipFleetIdentity` should learn `user`
(the gateway already skips `user` and reserved names in `/sessions`).

## Not done (by design or out of scope)

Notice forwarding (only `/notices` state), permission relay, natural language,
attachments, delivery reaction, reopening closed topics (a closed topic's
mapping is dropped and a new topic is created), 409-conflict special state
(treated as a generic error with backoff), `khala status` integration. Live
measurement items are listed in `docs/GATEWAY.md`.
