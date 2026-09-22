# T-GO: conduit letter triage (Jev), v0.9.10 lane report

Branch `task/triage-go`, base `ad33ad9`. Commits: `5e06f4a` (RED tests + no-op engine stub), `3816a13` (implementation), plus this report.
Files: `link/triage.go` (new), `link/triage_test.go` (new), `link/conduit.go` (+23/-6). `go.mod` unchanged (stdlib `net/http` only).

## Commands (all runs)
```
export PATH=/NHNHOME/jahn/go-toolchain/bin:$PATH
export GOTMPDIR=/NHNHOME/jahn/.cache/go-tmp GOCACHE=/NHNHOME/jahn/.cache/khala-go-cache-triage-go CGO_ENABLED=0 GOMAXPROCS=8
cd link
nice -n 19 taskset -c 20-71 go vet ./...
nice -n 19 taskset -c 20-71 go test -p 2 -count=1 ./...
nice -n 19 taskset -c 20-71 go test -p 2 -run TestTriage -count=1 .
```

## RED (commit 5e06f4a: tests against a no-op `triageEngine` stub)
On the bare base the tests do not compile (no triage engine exists), so the stub was added to get assertion-level failures:

| Property | Test | Failing assertion on the stub |
|---|---|---|
| P1 | TestTriageP1OffIsInert | PASS on stub (the stub is inert by construction; P1 is the regression guard that the real engine stays inert when off) |
| P2 | TestTriageP2AsksOncePerMessageAndWritesCache | `no tag for ink/1.act after 3s; requests=0` |
| P2b | TestTriageP2bThresholds | `no tag for ink/1.edge after 3s; requests=0` |
| P3 | TestTriageP3DoorbellDoesNotWaitForJudgment | `P3: judgment request not sent while the doorbell rang (requests=0)` |
| P4 | TestTriageP4ErrorCachedAndBackedOff | `P4: 401 did not write an error entry; requests=0` |
| P4 | TestTriageP4RateLimitBacksOffThenSucceeds | `no tag for ink/1.mail after 3s; requests=0` |
| P4 | TestTriageP4RateLimitExhaustedIsNotCached | `P4: requests=0 want 3 tries` |
| P5 | TestTriageP5SkipsOperatorAndNotice | `P5: frame line=""` |
| P6 | TestTriageP6HourlyBudget | `no tag for ink/1.mail after 3s; requests=0` |
| P7 | TestTriageP7CacheFollowsLetters | `no tag for ink/1.kept after 3s; requests=0` |
| P8 | TestTriageP8FrameBoundAndPosition | `no tag for ink/11.mail after 3s; requests=0` |
| P9 | TestTriageP9UnsafeConfIsOffWithOneLogLine/{mode0644,symlink,nokey} | `P9 mode0644: 0 'triage: disabled:' lines, want 1` (same for symlink, nokey) |

## GREEN (commit 3816a13)
- `go vet ./...`: clean. `gofmt -l .`: empty.
- `go test -p 2 -count=1 ./...`: `ok github.com/Dev-Jahn/khala-network/link 14.5s` (all existing conduit tests unchanged and passing; no existing assertion was edited).
- `go test -run TestTriage -count=1` repeated 3x: `ok` each (~7.2 s; P3 dominates with its 5 s server delay).
- Tests use an httptest server, an injected clock (budget, 10-min error window, 1-min conf re-read) and an injected sleep (429/529 backoff asserted as exactly `[1s 2s]`).
- Shell suites (test/*.sh) not run, per lane rules.

## Contract as implemented (the CLI lane reads this)

### Config `$KHALA_HOME/triage.conf`
- `key value` lines, `#` comments and blank lines ok. Keys: `provider typesafe` (required, only value), `key <token>` XOR `key-file <absolute path>` (read, whitespace-trimmed), `model` (default `jev-latest`), `endpoint` (default `https://api.typesafe.ai/v1/systemone`), `max-per-hour` (positive int, default 600), `threshold` (0..1, default 0.7), `threshold-action|threshold-reply|threshold-urgent` (override per tag).
- Absent file: off, silent. Present but symlink / not regular / group-or-other mode bits / not owned by the user / unknown key / malformed line / no key: off, one log line `triage: disabled: <reason>`.
- Re-read at most once per minute (first read at the conduit's first scan). Status changes are logged once: `triage: enabled (model …, max-per-hour …, thresholds action … reply … urgent …)`, `triage: disabled: …`, or `triage: off` (file removed after it had been on/disabled).

### Cache `$KHALA_HOME/run/triage/<identity>/` (dir 0700, files 0600, atomic temp+rename)
- `<letter-id>.json` success: `{"id","model","askedAt","needsAction","awaitsReply","timeSensitive","inputTokens","latencyMs","digest"}`; `askedAt` = unix seconds; `model` = the response's `model` field (e.g. `jev-1.13.0`); `digest` = hex sha256 of the exact `state` JSON bytes sent.
- `<letter-id>.json` error: `{"id","error","askedAt"}`, `error` = `HTTP <status>` or `request: <err>` / `decode response: …`. No `.tag` exists for an error entry (a stale `.tag` is removed). Not retried for 10 minutes.
- `<letter-id>.tag`: one line, newline-terminated, no spaces: comma-joined subset of `action,reply,urgent` in that order (noul >= its threshold), or `fyi`. Absent = not judged (pending, skipped by budget, rate-limited, or error). **CLI rule: `cat` the `.tag`; missing file -> `-`.**
- Threshold changes re-derive `.tag` from the cached probabilities on the next scan (no request).
- GC every scan (also when triage is off): cache files whose letter id is in neither `inbox/<identity>/new` nor `inbox/<identity>/cur` are removed. The engine never creates `run/triage` while off.

### Judgment
- Only letters in `inbox/<identity>/new` whose header `Type:` is exactly `message`. Operator, notice and anything else: never asked, never counted.
- State: `{"letter":{"from","to","subject","is_reply","body"}}`; `subject` "" when absent; `is_reply` = non-empty `In-Reply-To`; `body` = first 3000 bytes after the blank line, a split trailing rune dropped. Request `{"model","state","questions"}` with the three noul questions verbatim from the brief (ids `needs_action`, `awaits_reply`, `time_sensitive`), `Authorization: Bearer <key>`, `Content-Type: application/json`.
- 2 worker goroutines, 8 s per-request timeout, queue 1024. Rolling-hour budget = requests started in the last hour; an over-budget letter is not cached and is retried when budget returns (log `triage: hourly budget of N requests reached …` at most once per hour).
- 429/529: sleep 1 s, 2 s, then give up after 3 tries, not cached (next scan retries). Other non-200 / network / malformed answer: error entry. Errors log one line per distinct error string per hour.
- Re-judged when the letter's state digest differs from the cached `digest`.

### Frame line
After `subjects:`, before `generation:`, only when on:
`triage: action A (urgent U, reply R), fyi F, pending P` — over the frame's letters of `Type: message`: A = tag contains `action`; U, R = tag contains `urgent` / `reply` (any letter, not only action ones); F = tag `fyi`; P = no successful, digest-current cache entry. `frame` reads only the engine's in-memory state; the doorbell never waits (P3). Off: frame byte-identical to 0.9.9 (P1).

## Notes / judgment calls
- The frame counts `urgent`/`reply` over all judged messages (a letter tagged `reply` without `action` still counts in R). The brief phrased U/R as "those containing urgent/reply"; this is the literal reading.
- `key-file` must be absolute (the conduit's cwd is not meaningful under systemd/launchd); a relative path disables triage with a reason.
- The conf is parsed strictly: an unknown key or malformed line disables triage (logged once) rather than being ignored.
- `channelRequest` (Codex/channel doorbell meta) is unchanged; only the socket `frame` text carries the triage line, as scoped.
- `khala status` display (`triage: on/off`) is not in this lane's Go files; the CLI lane can derive it from the file's presence/mode, or from the `triage:` lines in `log/conduit.log`.
