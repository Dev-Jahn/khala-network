# GPT Pro (GPT-5.6 Sol, effort pro) — D17 review reply (2026-09-02)

> Question: scratchpad d17-consult-prompt.md, pinned to public dev 78174c7 (draft with facts 1-12). The reply was harvested from the live tab after the CLI run was killed; verbatim below.

# Executive verdict

I would block the A release on three issues:

1. **Notice custody is not R4-durable under the rsync fallback.**
2. **The proposed mutable `.watcher` record has no coherent single-writer or monotonic-update rule.**
3. **Thirty-day retention based on file age will delete some items immediately after their state transition and can reopen deduplication holes.**

The pre-write conduit recheck is worthwhile, but it only narrows the stale-doorbell race. For B, the design should use **Telegram topics in the user’s private chat**, not a supergroup, and `Type: user` should become an authenticated `Type: operator`. For C, per-session `.ear` files are viable at this scale, but a **single versioned per-node listening/status snapshot** is the better long-term object.

All code conclusions below are pinned to `78174c70e21652ea2a176e4dc96d6d726dbd81d4`. The `dev` branch moved to a child implementation commit while this review was in progress; I did not mix those changes into the audit.

---

# 1. Audit of §1 facts and discrepancies

The draft itself says its line references are against `c813c1f`, not the requested HEAD, at `review/d17-three-lanes-draft.md:14`. Consequently, almost every numerical code range in §1 is stale even where the substance is correct. Also, the requested HEAD contains **twelve** numbered facts after the addendum, not eleven.

### Fact 1 — mostly correct, with one type-system conflation

`cmd_send` does write the stated headers, at actual HEAD approximately `bin/khala:2525-2685`, and the conduit parses only `From`, `Subject`, and `Priority`, at `link/conduit.go:669-708`.

Two corrections:

- `Type: entry` is a **stream-object type**, written by `cmd_say`; it is not one of the mail-envelope types accepted in `spool`/`inbox`. `DESIGN.md:457-490` defines mail as `message | ack | bounce | notice`.
- The existing `queue_infrastructure_message` is not usable as the proposed notice constructor without redesign: it requires a reference message, derives the ID deterministically from that reference, always writes `Refs`, and fixes `Expires` to `ref-epoch + 30 days`, at `bin/khala:1341-1415`.

“No current producer creates notice” is correct at this HEAD.

### Fact 2 — code result correct; explanation of the channel path is stronger than the repository proves

The socket doorbell is `later` only when every pending letter has `Priority: later`, at `link/conduit.go:1044-1072`. The channel request merely sets `meta.later = "1"`; the channel server forwards `content` and `meta` in `notifications/claude/channel` and supplies no explicit queue-priority parameter, at `link/conduit.go:970-1013` and `plugin/channel/server.ts:550-586`.

Therefore:

- “Khala cannot pass a channel priority other than metadata” is verified.
- “CC unconditionally queues the channel notification as `next`” is an external CC behavioral claim, not something this repository proves.

### Fact 3 — code diagnosis correct; the transcript timeline is not in the repository

The race exists exactly as described: `scan` reads `new/`, computes `letters`, and later calls `maybeRing`; `maybeRing` does not re-read `new/` before writing, at `link/conduit.go:384-414` and `669-837`.

The particular steno timeline and “pending 1, drain 0” observation are not checked into the reviewed tree, so they are supporting operational evidence rather than repo-verifiable facts.

### Fact 4 — correct

`heartbeat` writes via temp plus `mv` to `presence/<identity>@<node>`, at `bin/khala:403-417`. `send`, `say`, and every `inbox` mode invoke it. Therefore `send --as gpu-guard` really does create or refresh a session-shaped heartbeat for `gpu-guard`.

### Fact 5 — incorrect runtime-path generalization

The runtime root is **not always** `/run/user/<uid>/khala`:

- `KHALA_RUNTIME_DIR` overrides it.
- Linux uses `/run/user/<uid>/khala` only when the parent directory is a real directory owned by the UID.
- Otherwise Linux and other platforms fall back to `/tmp/khala-<uid>`.
- macOS normally uses `$TMPDIR/khala-<uid>`.

The four runtime subdirectories are correct. The four replicated object classes are also correct. See `link/runtime.go:123-160` and `link/install.go:39-84`.

### Fact 6 — correct

At the pinned HEAD, expiry is checked before a regular spool message is installed in an inbox, at `bin/khala:1806-1831`, but there is no subsequent `new/` or `cur/` expiry. `reconcile_cycle` prunes delivered-log entries, streams, minds, presence and dead-session stream state, but not inboxes or `outbox/{acked,dead}`, at `bin/khala:2230-2265`.

There is an additional omission not called out in §1: `deliver_fire_and_forget` does **not validate `Expires` at all**, so a current-format notice can be installed even when already expired.

### Fact 7 — correct

The precedence is exactly:

`explicit --as` → set `KHALA_SESSION`, even if empty → valid one-line `.khala-session` → error,

at `bin/khala:190-216`.

### Fact 8 — not repo-verifiable

The CC `2.1.258` allowlist string and binary inspection are not present in this tree. The khala channel adapter’s development-channel logic is present, but it does not establish the asserted contents of that CC binary.

### Fact 9 — verified against the official plugin source, not against khala itself

The current official Anthropic Telegram plugin explicitly says there must be exactly one `getUpdates` consumer per token and that a second consumer causes `409 Conflict`; polling is performed inside the stdio MCP child. Thus the architectural premise is valid, but its source is external to this repository. `external_plugins/telegram/server.ts:57-64, 990-1015`.

### Fact 10 — not reproducible from the reviewed tree

At this HEAD, `link/go.mod:1-7` contains only `fsnotify` and `x/sys`; there is no pinned Telegram module, build record, proxy probe, or static-binary result. The scratchpad result may be correct, but it is not auditable from this commit.

### Fact 11 — measurements not repo-verifiable; its conclusion is now obsolete

The 29/29 transcript count, latency distribution, and CC-version observations are not present in this tree. More importantly, its conclusion that further B measurements are unnecessary except perhaps permission-prompt behavior is contradicted by fact 12/addendum: “turn opened” is not a sufficient processing metric. Permission-prompt and account-limit states are now mandatory B measurements.

### Fact 12 — periodic behavior is code-verifiable; `retry: N` interpretation is wrong

The conduit does schedule a successfully written generation for another attempt after ten minutes, at `link/conduit.go:209-222, 821-844`.

But the draft says the existing `attemptIndex` can be exposed directly as the number of prior missed rings. That is false:

- `attemptIndex` increments **before** the delivery attempt.
- Failed socket/channel writes also consume an attempt index.
- A successful channel write followed by a failed compatibility socket echo is another ambiguous case.

Thus `attemptIndex` is an attempt count, not a count of doorbells known to have opened a turn, and certainly not a count the session “missed.” `link/conduit.go:710-837`.

---

# 2. A — ranked failure modes and smallest closing spec change

## 1. P0: notice custody is lost after relay acceptance, before destination installation — A3

There are three separate problems.

First, the draft’s proposed constructor does not match the existing helper. `queue_infrastructure_message`:

- requires `Refs`;
- derives its ID from the referenced message;
- generates a 30-day expiry from the reference epoch;
- always writes into `spool/for/<node>`;
- does **not** directly install a self-addressed object into `inbox`.

See `bin/khala:1341-1415`. A dedicated notice writer is required.

Second, the Go link path and rsync fallback have different custody semantics:

- In the Go path, a dial-side source spool candidate has `deleteAfterStored=false`; the source copy remains. A hub’s transit copy is removable only after the downstream peer returns `STORED`. The receiver validates size and digest, synchronizes its temporary file, atomically installs it, synchronizes the directory, and only then returns success. `link/watch.go:322-367`, `link/pump.go:414-563`, `link/install.go:144-244`.
- In the rsync fallback, the source pushes to the mailbox without source removal, but after the rest of `exchange_with_endpoint` succeeds, `remove_pushed_infrastructure` deletes every local `ack|bounce|notice`. The destination node has not necessarily pulled or installed that notice. `bin/khala:1622-1634, 1637-1708`.

So this sequence loses a notice:

1. Source rsyncs notice to mailbox.
2. Source deletes its spool copy.
3. Mailbox disk disappears.
4. Destination has never pulled the notice.

That is precisely the disappearing-relay case R4 was designed around.

**Smallest spec change:** remove `notice` from `remove_pushed_infrastructure`. The originating node retains the notice in its source spool until `Expires`; repeated pushes are deduplicated at the destination. Every spool copy may be silently pruned after a valid `Expires`, but **mailbox custody is not delivery custody**. This preserves “no outbox, no user-visible ack” while restoring at-least-once delivery as long as the source node’s disk survives.

Also require the destination to validate `From`, `To`, `Id`, `Type`, `Urgency`, and `Expires` before inbox installation. Today `deliver_fire_and_forget` validates only `To`, at `bin/khala:1862-1904`.

---

## 2. P0: the five-line mutable watcher marker has no safe ownership model — A4

The current presence installer treats presence as an uninterpreted mutable blob and atomically overwrites the existing path. It performs no schema validation, no monotonicity check, and no conflict detection, at `link/install.go:225-244`. The `now+86400` future-epoch rule applies only to `stream` and `mind`, not to presence, at `link/install.go:193-220`.

Consequences:

- A delayed `active` copy can overwrite a later `retired` copy.
- Two machines configured with different owners can each compute and publish incompatible `active|silent` state.
- If the watcher node updates `last-notify` and the owner node updates `active|silent`, there are two writers to one replicated path.
- `owner: steno` is ambiguous; ownership needs to be a full address such as `steno@b200`.
- Clock skew can cause premature or delayed dead-man transitions if the owner compares its clock directly to a remote epoch.
- Generic current CLI GC is incompatible with the format. `prune_presence` skips only `.watching` and determines age from the first line. A declaration whose first line is a fixed epoch can be deleted after `retain` days even while it remains active. `bin/khala:2165-2203`.
- Existing `khala presence` accepts only a bare address or `.watching`; an unhandled `.watcher` suffix is an invalid heartbeat filename.

**Smallest sound spec change:**

- Make the replicated watcher object **source-owned only**.
- Remove replicated `active|silent`; the owner derives that state locally.
- Store the full `Owner-Address`.
- Add a monotonic `Generation: <epoch>.<counter>`.
- Every notification refresh produces a higher generation carrying `Last-Notify`.
- Retirement is a higher-generation tombstone, never deletion.
- The installer accepts a replacement only when the generation is greater; equal generation with different bytes is quarantined.
- The owner’s dead-man timer is based on **local first-observed time for the latest generation**, not direct subtraction of remote and local wall clocks.
- Exempt active watcher declarations from generic presence retention; retain retired tombstones for a defined conflict horizon.

A mind-style immutable generation family is cleaner, but a generation-checked, single-writer presence object is the minimum viable correction. Do not let the owner write fields back into the source-owned marker.

---

## 3. P0: retention clocks and deduplication horizons are underspecified — A5

A raw “delete files whose mtime is older than 30 days” implementation is wrong because all relevant state changes are renames:

- inbox drain: `new/<Id> → cur/<Id>`;
- ack settlement: `outbox/new/<Id> → outbox/acked/<Id>`;
- expiry: `outbox/new/<Id> → outbox/dead/<Id>`.

A rename preserves the file’s mtime. Therefore:

- a message that waited 31 days in `new` can be deleted immediately after its first drain;
- a message acknowledged after 31 days can disappear from `acked` immediately;
- a long-lived message moved to `dead` can disappear before any forensic inspection.

The relevant moves are at `bin/khala:1928-1988` and in the inbox drain around `bin/khala:3890-3960`.

There is also a deduplication hole. `log/delivered` is retained for a fixed 60 days, while `send -e` accepts an arbitrary nonnegative TTL. If:

1. a delivered body is removed from `cur` after 30 days;
2. its dedup entry is removed after 60 days;
3. a source still retransmits the same live message because it had a TTL greater than 60 days,

the recipient can install it again. `bin/khala:2014-2043`.

**Smallest spec change:**

- Define retention age as **time entered this state**, never inode mtime.
- Persist `installed-at`, `drained-at`, `acked-at`, and `dead-at` in a compact state index or sidecar.
- Keep a header/digest/dedup tombstone until at least `Expires + grace`; alternatively cap all message TTLs below the dedup horizon.
- Separate body retention from reference metadata.

Recommended defaults:

| Type/state | Body retention | Metadata/dedup retention |
| --- | --- | --- |
| `message`/future `operator`, `new` | never silently delete | through `Expires + grace` |
| `message`/`operator`, `cur` | 90 days configurable | 180–365 days |
| `notice`, `new | cur` | until `Expires` |
| `outbox/acked` | 30 days | 90–180 days |
| `outbox/dead` | 90–180 days | same or longer |

`In-Reply-To` delivery itself does not require the ancestor body, but a useful dashboard, audit trail, and conversation reconstruction need at least `Id`, `From`, `To`, `Date`, `Type`, `Subject`, `In-Reply-To`, digest, and state timestamps. Yes, retention should be per-Type and per-state.

---

## 4. P1: malformed envelope parsing can incorrectly suppress a ring — A1

Supported khala paths mostly protect against partial arrival:

- CLI writers stage and hard-link or rename atomically.
- Inbox delivery uses `atomic_copy`.
- The Go receiver verifies the digest and synchronizes before installation.

Thus a partial file in `inbox/new` mainly comes from unsupported in-place writers, bugs, or manual interference. Still, because `info` suppresses wake-up, its recognition rule must be fail-safe.

The current conduit parser:

- reads up to 64 KiB;
- ignores `Scanner.Err`;
- accepts duplicate headers implicitly, with later matches overwriting earlier interpretation;
- does not require a complete header section terminated by a blank line;
- hashes only IDs into the generation.

`link/conduit.go:669-738`.

**Correct default:** malformed classification should degrade toward ringing, but not toward a rapid retry loop.

Define:

- `Type` absent or `Type: message` from a 0.7.3 sender → ordinary mail ring rules.
- Unknown or duplicate `Type` → ring-set, marked malformed.
- `Type: notice` plus exactly one `Urgency: info` → info only.
- Missing, duplicate, or unknown `Urgency` on a notice → urgent ring-set.
- A notice may suppress ringing as `info` only when the full mandatory envelope is valid, the blank header terminator was seen, and `From` resolves to a declared watcher principal.
- Missing or malformed `Expires` → ring and report malformed; valid already-expired notice → no ring and immediate prune.
- `Urgency` on any non-notice type is ignored or rejected; it must not downgrade mail or future operator instructions.

Also include `(Id, effective lane, effective urgency, effective priority)`—or a digest of the validated control envelope—in the conduit generation. ID-only generation means a changed classification under the same file name is invisible to conduit state.

---

## 5. P1: info-only queues can become permanently invisible — A2

The current SessionStart hook performs one bounded `khala inbox --drain` invocation. Current CLI drain defaults are 20 objects and 64 KiB; the proposed split caps make the invisible-remainder problem more likely. A session with only info notices can therefore have:

- no doorbell;
- one bounded SessionStart drain;
- more info notices left behind;
- no future mail or SessionStart event to surface the remainder.

A notice larger than the per-lane byte cap is worse: without a creation-size limit or “consume one oversize item” rule, it can remain permanently undrainable.

`Priority: later` creates another edge:

- later mail plus info notices produces a later doorbell;
- a continuously active session may not see that doorbell until idle;
- after the ring-set portion drains, leftover infos again have no trigger.

**Add a maximum-age rule, in the conduit.** The conduit owns wake decisions; the CLI should only implement deterministic draining.

Recommended policy:

- Track recipient-local `first-seen` for an unchanged info-only generation.
- After six hours, emit one `later`-priority “stale info batch” nudge.
- If still unchanged, repeat at most once per 24 hours until drained or expired.
- Never place info in the urgent ten-minute re-ring schedule.
- Reset the timer when the info generation changes or becomes empty.
- Do not use sender `Date` or file mtime as the age clock.

Drain should reserve capacity and order lanes rather than simply scan filename order:

1. authenticated future `operator`;
2. ordinary messages and urgent notices;
3. info notices.

Within notices, urgent must not sit behind an info backlog. Enforce a maximum notice body/envelope size below the smallest drain byte budget, or permit one oversize object to be emitted in truncated form and moved to `cur`.

---

## 6. P1: “every ten minutes forever” has the right liveness property but the wrong frequency policy — A7

The measurement rules out a terminal retry cap: a cap of four would have lost exactly the alert that succeeded on the fifth turn. But fixed ten-minute retries forever permit an unbounded turn storm from:

- a multi-hour account limit;
- a permission dialog;
- a malformed object the CLI refuses to drain;
- an object larger than the drain cap;
- a forged urgent notice.

Use **no terminal cap, but lane-sensitive bounded-frequency backoff**:

- authenticated operator or urgent notice: every 10 minutes for the first hour, then every 30 minutes until drain or expiry;
- ordinary message: 10 minutes, 30 minutes, then at most every 2 hours;
- info-only generation: first nudge at six hours, then at most daily.

Reset the schedule on a generation change or successful drain. Suspend it when there is no verified live registration; resume when a verified registration returns. Validation and maximum-object-size enforcement are prerequisites, otherwise a permanently undrainable object becomes a permanent wake source.

For genuinely urgent notices, a default two-day expiry should also be reconsidered: expiry is effectively the terminal retry cap. Seven days is safer for operational alerts unless the source is expected to regenerate the condition.

---

## 7. P2: the pre-write recheck narrows rather than closes the race — A6

With the proposed recheck:

1. conduit scans generation `G`;
2. immediately before writing, conduit rescans and confirms `G`;
3. the CLI drains `G`;
4. conduit writes the stale doorbell.

The interval is shorter, but nonzero. The only full closure is synchronization shared with inbox drain—e.g. holding the brain lock across final scan and socket/channel write—or an acknowledgement protocol between drain and conduit. That is likely disproportionate for a benign stale wake.

The recheck should nevertheless ship, with precise state handling:

- perform it before incrementing the attempt/ring count and before assigning the attempt ID;
- if the set is empty, abort without journaling a delivery attempt;
- if generation changed, restart `maybeRing` using the new snapshot;
- reset `nextAttempt` for the new generation so an old ten-minute deadline does not suppress it.

A legitimate letter arriving after the final recheck is not inherently lost: fsnotify or the one-second periodic scan should observe a new generation. It may produce a second immediate ring after the first undercounted frame. The spec should say “narrows and bounds stale snapshots,” not “closes the window.”

---

## 8. P2: `retry: N` claims knowledge the conduit does not have — A8

Use:

```
ring-index: 5
pending-for: 47m
last-ring-ago: 10m
```

not:

```
retry: 4
```

`pending-for` should be based on recipient-local first observation of the unchanged ring generation. `ring-index` should count only **successfully written doorbells for that generation**, requiring a separate counter from `attemptIndex`.

The model-facing wording should be:

> This pending generation is unchanged after five doorbells.

It should not say earlier rings were “missed”: the addendum shows they opened turns, while transport-level failures may not have reached CC at all. The oldest-undrained age is the most actionable signal; ring count is useful secondary context.

---

# 3. B — user/operator lane

## B1. Simpler designs, ranked

### 1. One Telegram bot, topics in the user’s private chat

This is now the best topology. Telegram added forum-topic support for private chats in Bot API 9.3 on December 31, 2025. `createForumTopic` and `message_thread_id` now apply to a private chat with topic mode enabled as well as to forum supergroups. That eliminates the supergroup, admin-role, membership, General-topic, and group-migration machinery while preserving one bot, phone push, and one thread per session. [![](https://www.google.com/s2/favicons?domain=https://core.telegram.org&sz=128)Telegram+3![](https://www.google.com/s2/favicons?domain=https://core.telegram.org&sz=128)Telegram+3![](https://www.google.com/s2/favicons?domain=https://core.telegram.org&sz=128)Telegram+3](https://core.telegram.org/bots/features)

Use:

- the main/private-chat topic as fleet console;
- one private topic per `session@node`;
- numeric `chat_id` and `message_thread_id` as authority;
- topic names only as display labels.

The existing generic `CreateForumTopic` and `MessageThreadID` shapes should be sufficient, but this must be tested because the pinned khala tree does not yet pin the Telegram module.

### 2. One Telegram bot, one private supergroup with forum topics

This remains the fallback if private-chat topic UX or library behavior fails on the actual phone clients. It is the draft design, but operationally heavier.

### 3. One Discord private server, channel/thread per session

Functionally similar, with more account/application permission surface. It does not simplify the khala side and is less aligned with the already-tested Telegram path.

### 4. Matrix/Element rooms or threads

Better ownership and self-hosting options, but substantially more deployment and protocol work than a single Telegram gateway.

### 5. Dashboard PWA plus Web Push

It removes the messaging provider but replaces it with HTTPS origin management, push subscriptions, VAPID keys, service-worker lifecycle, notification permissions, mobile background restrictions, and a custom threaded UI. It is not the simpler v1.

Notification-only systems such as ntfy or Pushover are simpler only after relaxing bidirectional, per-session-thread requirements; they are not equivalent.

A distinct private Telegram **chat** per session is not preferable. Between one user and one bot there is one direct-chat container; creating many private groups to emulate chats is strictly more administration than using private topics. A mini-app can later complement the dashboard but should not be the primary push transport.

---

## B2. `Type: user` versus the non-goal

I accept the concept—owner-to-agent control is not arbitrary human-to-human messaging—but not the proposed names.

`Type: user` conflates three different things:

- the human actor;
- the network principal carrying the message;
- CC’s own `role: "user"` doorbell representation, which khala already emits at `link/conduit.go:945-960`.

Use:

```
Type: operator
From: khala-gateway@<gateway-node>
Actor: owner
Origin: telegram
Conversation: <opaque-stable-id>
Origin-Ref: <telegram update/message id or gateway event id>
```

Replies go to `khala-gateway@<gateway-node>` with `Conversation` and `In-Reply-To`/`Origin-Ref` preserved.

Also:

- Reserve `khala-gateway` explicitly; the current name grammar permits an ordinary CC session to bind that identity.
- Define a principal class such as `session | watcher | gateway`; do not infer class from a common name like `user`.
- Amend DESIGN §8 narrowly: “not arbitrary human-to-human messaging; a configured owner-to-session control adapter is allowed.” The current non-goal wording is at `DESIGN.md:340-354`.

---

## B3. Gateway authentication and prompt-injection authority

CLI flag omission is not an authenticity mechanism. Any same-UID process can construct a file with `Type: operator`, and the consequence is elevated model authority.

An HMAC with one fleet-shared key is also a poor fit: every verifier needs the secret, so every node that can read it can forge operator messages.

Use an Ed25519 gateway key pair:

- private key only on the gateway node;
- pinned public key and `Key-Id` on receiving nodes;
- signature covers a canonical representation of:
  - envelope version;
  - `Id`, `From`, `To`, `Date`, `Expires`;
  - `Type`, `Actor`, `Origin`, `Conversation`, `Origin-Ref`;
  - SHA-256 of the exact body bytes.

Verification must happen in trusted conduit/CLI code before the model sees an “operator-authenticated” label. The header cannot self-assert its own validity.

Policy:

- valid signature from a configured operator key → render as authenticated operator input;
- unsigned or invalid `Type: operator` → downgrade to an ordinary untrusted message with a conspicuous warning; never silently grant operator authority;
- enforce allowed Telegram numeric user ID and chat ID at ingress; do not authorize by username or display name;
- retain replay tombstones through `Expires + grace`.

Under the declared same-UID threat model this is provenance, not an absolute local security boundary: a malicious same-UID process on the gateway can steal the private key, and one on the receiver can replace verification code or public keys. It still materially prevents an ordinary peer session on another machine from casually impersonating the owner. A separate OS account or platform keychain is needed for stronger local isolation.

---

## B4. Telegram behavior at 30–60 topics

I found no documented topic-count cap in the official Bot API documentation or current topic changelog. The practical bottleneck is the fact that all topics share one chat’s send budget and one gateway queue, not 30–60 topic objects.

Telegram advises approximately one message per second per chat and about 20 messages per minute in a group; text messages are limited to 4096 characters after entity parsing. [![](https://www.google.com/s2/favicons?domain=https://core.telegram.org&sz=128)Telegram+2![](https://www.google.com/s2/favicons?domain=https://core.telegram.org&sz=128)Telegram+2](https://core.telegram.org/bots/faq)

Required engineering:

- one outbound queue with per-topic fairness;
- status/command messages ahead of bulk transcripts;
- coalescing repeated health events;
- obey `429` and `retry_after`;
- Unicode-safe chunking;
- either plain text chunks or recomputed entity offsets;
- one stable outbound event ID across chunks;
- store numeric thread IDs; names are mutable and non-authoritative;
- handle deleted, closed, recreated, or renamed topics;
- persist the topic mapping outside khala inbox retention.

The Bot API does not provide arbitrary chat-history retrieval. `getUpdates` is an update stream, and unconfirmed updates are retained for no longer than 24 hours. The gateway must durably journal and enqueue an inbound event before advancing its update offset. [![](https://www.google.com/s2/favicons?domain=https://core.telegram.org&sz=128)Telegram+1](https://core.telegram.org/bots/api)

Prefer private-chat topics. Multiple groups/chats add administration without adding isolation that the gateway queue and per-thread mapping do not already provide. A mini-app is a later UX enhancement.

---

## B5. Mandatory measurements before implementation

The draft’s single topic round-trip measurement is insufficient. These are mandatory:

1. **Full path latency:** phone → Telegram update → durable gateway journal → khala destination `new/` → doorbell → drain → reply letter → durable gateway outbound journal → Telegram topic. Measure local, remote, sleeping, idle, active-turn, permission-prompt, and account-limited cases.
2. **Inbound crash windows:** kill the gateway:

Derive khala `Id` deterministically from bot ID plus `update_id` so replay is harmless.
  - after receiving an update but before journal sync;
  - after journal sync but before khala enqueue;
  - after enqueue but before advancing the Telegram offset.
3. **Outbound crash windows:** kill it:

The gateway must not use a destructive drain as its only copy of an unposted reply.
  - after draining a session reply but before persisting outbound state;
  - after Telegram accepts the send but before recording success.
4. **Poller exclusivity and recovery:** second consumer, `409`, process restart, host restart, gateway failover, stale offset, duplicated updates, and outage beyond Telegram’s update-retention window.
5. **Burst/backpressure:** 30–60 topics, simultaneous replies, 429 handling, queue fairness, coalescing, and time-to-delivery for an urgent operator command behind bulk output.
6. **Topic lifecycle:** create, reuse, rename, close, delete, permission loss, bot removal, private-topic client behavior, and mapping reconstruction.
7. **Payload correctness:** 4096-character boundary, multi-byte Unicode, Markdown/entities, chunk ordering, replies to chunked messages, and unsupported attachments.
8. **Authority tests:** valid signature, invalid signature, unknown key, replay, changed body, changed destination, expired command, and peer-session forgery.
9. **CC non-processing states:** both permission prompt and five-hour usage limit are now mandatory. Record written doorbell, new-turn creation, actual model invocation, drain, and response as separate milestones.
10. **Health-signal precision:** measure how often `.ear + pending` fires during legitimate long turns, `Priority: later`, bounded drains, and ordinary replication delay.

---

## B6. “Listening but not processing” health signal

The raw condition is useful, but the proposed wording overclaims.

A live `.ear` establishes only:

- a recently verified registration/socket existed;
- the conduit believed it had a routable endpoint.

It does not establish:

- model availability;
- successful model invocation;
- absence of a permission prompt;
- absence of an account limit;
- that a delivered user turn was understood;
- that a reply can be produced.

There is also a data-availability problem: the gateway cannot derive “remote pending letters persist” from `.ear` alone because remote inboxes are not replicated. C must publish a redacted destination-generated status summary containing at least:

```
identity
pending-ring-count
pending-info-count
pending-generation
pending-first-seen
last-written-ring
written-ring-count
last-drain-at
last-drained-generation
```

False positives include:

- info notices intentionally awaiting piggyback;
- a fresh delivery still inside normal latency;
- `Priority: later` waiting for idle;
- a legitimate long tool call;
- bounded drain leaving a remainder;
- an oversize or malformed undrainable object;
- ear/status replication skew;
- session handoff between instances.

A false negative also matters: the session may drain an operator letter immediately and then fail or ignore it; pending disappears even though the instruction was not substantively processed.

Recommended notification:

> `steno@b200` ear seen 42s ago; operator generation `abc…` remains undrained for 18m after 3 written doorbells.

Do not say “not processing” or diagnose an account limit. Alert once per unchanged generation, clear on drain or generation change, and suppress when the ear becomes stale. Suggested initial thresholds: 15 minutes for authenticated operator/urgent input, 60 minutes for ordinary mail, and no such alert for info notices.

---

# 4. C — read-only dashboard

## C1. `.ear` load and object shape

Assuming approximately 30 registered identities total across eight nodes:

- per-session `.ear` gives about 30 file replacements per minute;
- in a seven-edge hub-and-spoke fan-out, roughly 210 tiny network installations per minute;
- more significantly, every presence event causes `scanPresence` to enumerate the presence directory, and each serve-side peer watcher does so independently. At a hub, the rough upper bound is on the order of

`30 events/min × 7 peer watchers × 30 files ≈ 6,300` candidate file reads/hashes per minute.

`scanPresence` behavior is at `link/watch.go:337-367`; presence is rescanned as part of each age-governed scan.

That load is acceptable on eight personal machines because the files are tiny, but the asymptotic shape is poor and produces unnecessary wakeups.

A single per-node snapshot is better:

```
presence/ears@b200.ears
```

containing all verified local listeners and minimal delivery telemetry. That reduces writes to at most eight per minute and presence fan-out to roughly 56 tiny installations per minute.

Requirements:

- atomic replacement;
- one writer: the local conduit;
- schema version;
- monotonic generation;
- bounded identity count and record size;
- omission means not listening;
- no socket paths, PIDs, Telegram IDs, subjects, or bodies;
- installer rejects generation regression and quarantines equal-generation/different-bytes conflicts.

Freshness should preferably use a local installer-observed timestamp. Direct comparison against a remote wall clock makes a `2 × 60s` expiry fragile under clock skew. The rsync fallback preserves source mtimes, so inode mtime is not automatically a receiver timestamp; store a local `seen-at` sidecar or explicitly refresh receiver-side metadata after validated installation.

This same per-node snapshot should carry the redacted pending/drain fields needed by B6. Avoid introducing separate `.ear`, `.processing`, and `.pending` heartbeat families.

---

## C2. Data to add now, and data not to expose

A dashboard on one node can read local inbox and runtime truth, but it cannot infer remote inbox state from existing replicated objects. Without a replicated redacted node summary, it is a **local dashboard plus remote presence view**, not a fleet dashboard.

Add now:

- per-letter state index:
  - installed, drained, acked, dead timestamps;
  - current state;
  - type;
  - expiry;
  - envelope/body digest;
- per-identity:
  - pending counts by lane;
  - oldest recipient-local pending age;
  - current generation;
  - last drain time and generation;
  - last written ring, ring count, and delivery result;
- per-link peer:
  - last successful HELLO;
  - last `STORED`;
  - queue depth by class;
  - last recoverable/fatal error;
- watcher:
  - latest declaration generation;
  - owner address;
  - cadence;
  - locally derived effective state;
- gateway:
  - last Telegram update offset;
  - inbound/outbound durable queue depths;
  - last API success and 429;
  - topic-mapping health;
- component versions and on-disk schema versions.

Do not expose by default on a tailnet port:

- message or notice bodies;
- subjects, which frequently contain secrets;
- raw Telegram IDs or `Origin-Ref`;
- bearer tokens or signing material;
- Unix socket paths;
- process IDs and process command lines;
- SSH coordinates, usernames, or raw config;
- model-account or usage-limit details;
- free-text mind focus/stance unless explicitly enabled.

Serving rules:

- loopback-only by default;
- explicit opt-in for tailnet binding;
- metadata-only remote mode;
- bearer in `Authorization`, never query strings;
- `Cache-Control: no-store`;
- restrictive CSP;
- no cross-origin access;
- constant-time token comparison;
- no filesystem path supplied by the HTTP client;
- `Lstat`/real-directory checks to avoid following attacker-created symlinks;
- no state-changing endpoints in the dashboard process.

---

# 5. Cross-cutting

## X1. Changes to make in A now so B and C do not force a rewrite

### 1. Reserve the final envelope vocabulary now

Use:

```
Envelope-Version: 1
Type: message | notice | operator | ack | bounce
Urgency: urgent | info          # notice only
Actor: owner                    # operator only
Origin: telegram | web | local  # operator only
Conversation: <opaque>
Origin-Ref: <opaque>
Key-Id: <id>
Signature: <base64>
```

Do not ship `Type: user`. Parsers should already reserve these names and reject duplicate control headers.

### 2. Do not reuse `queue_infrastructure_message` for notices

Current `DESIGN.md:457-480` says notices carry `Refs`; proposal A says they do not. Resolve that contradiction now. Give notice a dedicated writer with:

- a fresh ordinary message ID;
- no `Refs`;
- explicit `Urgency`;
- explicit `Expires`;
- no heartbeat side effect for the watcher identity;
- atomic direct spool creation.

### 3. Fix source custody before any notice is emitted

Origin notice remains in source spool until expiry. A relay accepting bytes is not delivery completion. This choice is also what a future operator lane needs if it ever bypasses the ordinary outbox.

### 4. Make principal class explicit

Introduce `session`, `watcher`, and `gateway` principals. Do not infer them from common identity names. Reserve gateway identities so a CC session cannot bind them.

An info notice should be allowed to suppress a ring only when its sender resolves as a valid watcher principal; otherwise fail toward ringing.

### 5. Replace the five-line multi-writer marker

Use source-owned, generation-checked watcher declarations/tombstones. Use one per-node ears/status snapshot for C and B6. The owner derives silence locally and does not mutate the source marker.

### 6. Define state timestamps and tombstones now

A/C/B all need:

- installed-at;
- drained-at;
- acked/dead-at;
- local first-seen;
- last-written-ring;
- last-drained-generation.

Do not postpone these until the dashboard. Retrofitting them after 30-day deletion has begun cannot reconstruct historical transitions.

### 7. Define drain precedence and maximum object sizes

The future order should be:

1. authenticated operator;
2. ordinary messages and urgent notices;
3. info notices.

Give each lane reserved count/byte capacity. Enforce object-size limits at creation and ingress so every valid object is drainable.

### 8. Define generation as effective behavior, not only filenames

Conduit generation should incorporate the validated ring class, urgency, priority, and expiry status. Persist local `first-seen` and successfully written ring count. These are required for A7, dashboard health, and B6.

---

## X2. What a 0.7.3 link actually does with `.watcher` or `.ear`

`presenceNode` strips only `.watching`. For `steno@b200.ear` or `gpu-guard@b200.watcher`, it interprets the node portion as `b200.ear` or `b200.watcher`, which is invalid. `link/config.go:115-123`.

Behavior depends on which side is old:

### Old 0.7.3 sender scanning its filesystem

`scanPresence` calls `presenceNode`; an unknown suffix fails validation and is simply skipped. There is no quarantine and ordinarily no log entry. `link/watch.go:350-367`.

### Old 0.7.3 receiver offered such an object by a newer peer

The receiver’s destination validation fails. It sends a recoverable:

```
ERROR INVALID_OFFER
```

logs the invalid offer, and continues the connection. It does **not** install or quarantine the object, and does **not** disconnect. `link/pump.go:205-252`, `link/install.go:50-62`.

### The future-epoch rule does not help

Presence is excluded from the `now + 86400` check. That check applies only to `stream` and `mind`, at `link/install.go:193-220`.

### Correct rollout

The proposed order is directionally correct but incomplete:

1. **New link binary everywhere**, with suffix-aware parsing, schema validation, and generation-regression protection.
2. **New CLI everywhere**, including:
  - shell rsync presence glob;
  - `cmd_presence`;
  - `cmd_minds`;
  - `prune_presence`;
  - any watcher display/reconcile parser.
3. Only then create watcher or ears markers.

The current rsync fallback pushes only:

```
presence/*@<self>
presence/*@<self>.watching
```

at `bin/khala:1676-1686`; new suffixes will not replicate through that path until the CLI changes.

Creating markers after only the Go binary upgrade is therefore unsafe: the fallback will omit them, and old CLI commands may reject or incorrectly age-prune them. The actual compatibility outcome is **silent skip on an old sender, recoverable refusal on an old receiver, no quarantine, no disconnect**.

The minimum pre-ship gates for A are therefore: source-retained notice custody, generation-checked single-writer watcher state, and transition-time/dedup-aware retention.
