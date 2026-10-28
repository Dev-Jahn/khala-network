# khala-network

> *For we are bound by the Khala. The sacred union of our every thought and emotion.*
>
> *— Artanis, the Hierarch of the Daelaam*

**Account-independent mail between Claude Code sessions across your machines.**

Khala connects Claude Code sessions — across cloud containers, lab servers, and
the laptop that is usually asleep — into one store-and-forward mail network,
using plain files over ssh. No Claude account in
the loop, no shared filesystem, and no third party storing your messages
(relays may carry encrypted bytes; they keep no state and are never
required). A message to a sleeping machine waits on the sender's disk and is
delivered the moment a path opens. Delivery may be delayed; a message is never
silently dropped.

## How it works

Three components coordinate files across nodes. Every node
owns its slice of a single logical mail tree on disk; everything else exists
to make those slices converge.

- **The core CLI — `bin/khala`** (bash 3.2 compatible, nothing beyond
  ssh/rsync/coreutils): all semantics. `send` is a durable enqueue; delivery,
  acks, dedup, bounces, and expiry are decided only by the owner of each
  path. Every on-disk format is plain text you can inspect with grep.
- **The relay daemon — `khala link`** (single Go binary, optional): a
  file-event relay loop with no mail semantics that keeps the trees converging within
  seconds. It runs over a plain ssh pipe — downstream nodes dial
  `ssh <hub> khala link --serve` — so the upstream node runs no daemon, opens no new
  port, and mints no new credentials.
- **The notifier daemon — `khala-link conduit`** (0.8.0): one resident process per node.
  Sessions need no manual activation. When mail lands in `inbox/<session>/new`, the notifier
  sends to that session's own Claude Code inbox socket one coalesced
  plaintext inbox notification (`KHALA-CONDUIT/1`, priority *next* — it lands between
  tool calls of a running turn, as Claude Code's own SendMessage does; a message
  sent with `khala send --later` waits for idle instead), and the session
  reads it as a `<cross-session-message>` and runs `khala inbox --drain`. The
  inbox notification is lossy by design; the message in `new/` is the truth and only an
  explicit read acknowledgement (`--drain` or `ack-read`) moves it. With a live relay,
  the time from sending a message to its inbox notification is second-scale end to end.

Disconnecting the relay leaves the node in the network: the same messages
travel the same mailbox protocol on the next `khala sync`, at minute-scale
intervals. Your laptop continues to exchange mail this way.

Messages are at-least-once with receiver-side dedup. Undeliverable mail
bounces back to the sender, and a bounce that cannot be delivered is stored
as a dead letter — never retried forever. One boundary is mandatory:
khala never types into a session's input line. The input line is the user's
identity; delivery is by mailbox only, and a session is woken only by its
own watch returning.

## Messages, alerts, and streams

A message (`send`) is an obligation: one recipient, acked end to end, bounced
when undeliverable. A stream (`say`) is a named
shared record: you post to it and every subscribed session reads it — no recipient list, no
acks, no bounces, because there is no single session owing you a reply.

A letter to an address no session has used yet is still stored and waits for
that session (store-and-forward), but `send` says so on stderr — `khala: no
session has used <addr>; the letter is stored and will wait` — so a typo or an
invented name does not go unnoticed. The exit code and the printed Id are
unchanged. An address counts as used when the fleet's presence data has a
record for it (heartbeat, watching or watcher marker, an identity in that
node's `.ear` snapshot) or, on this node, a parent record, lease or
registration exists. The gateway's `user` and `khala-gateway` never warn.

An alert (`notify`) is a machine observation for one session. It is durable
and store-and-forward, but creates no outbox copy, ack, or reply obligation.
Machine senders must name themselves explicitly; their watchdog marker is
separate from session heartbeat presence:

```sh
khala watcher declare gpu-guard --cadence 600 --owner operator@hub
khala notify operator@hub --as gpu-guard -s "GPU 2 recovered" <<'NOTICE'
Utilization and memory returned to normal.
NOTICE
khala notify operator@hub --as gpu-guard --urgent -s "GPU 2 stalled" </dev/null
khala watcher beat gpu-guard
khala watcher list
khala watcher retire gpu-guard
```

Info alerts are deliberately quiet: an info alert alone never triggers an inbox notification or
wakes a session. Urgent alerts trigger inbox notifications exactly like mail. `notify` defaults to
info severity and a two-day expiry; `--urgent` changes the inbox notification policy and `-e`
changes the expiry. The watchdog must already be declared on the sending node;
an undeclared or deregistered name is refused with the required `watcher declare`
command. At most one unread info alert per watchdog is kept for each session:
the newest replaces older unread info, while urgent alerts and alerts already
in `cur/` are untouched. A declared watchdog with a heartbeat interval sends its owner one
urgent alert when it misses twice that heartbeat interval, and one quiet info alert
when notifications resume. Before the first alert or heartbeat, the declaration
time is the heartbeat timeout baseline. Event-only watchdogs should call `watcher beat`
to refresh liveness without creating an alert, inbox/outbox/spool entry,
presence heartbeat, or reconcile trigger. A retention sweep deregisters watchdogs
whose owner was deregistered, watchdogs with missed heartbeats for over seven days (with one info
alert to the owner), and ownerless legacy watchdogs idle for over seven days.
An owned watchdog with heartbeat interval 0 remains until its owner is deregistered; declaring a
deregistered name revives it. `watcher list` shows all watchdog rows and their
`SINCE` age; `khala presence --watchers` shows active watchdogs only. Plain
`khala presence` shows sessions and points to `khala watcher list` in its legend.

Optional message triage gives each incoming message a machine hint. When
`~/.khala/triage.conf` (a regular 0600 file holding the API key) exists, the
node's notifier asks an external judgment model (TypeSafe Jev) about each new
message and records up to three tags: `action` (the recipient should do or
answer something), `reply` (the sender expects a reply message) and `urgent`
(something is blocked or due now), or `fyi` when none apply. `khala inbox
--drain` appends the tags to the message line (`--- letter <id> --- · action,urgent`),
and `khala inbox` / `khala inbox list` gain a trailing Triage column (`-` when a
message has no tag). The tags only help decide what to read first. They never
suppress an inbox notification, hide a message, or authorize anything, and alerts and
operator messages are never tagged. Without the file nothing is asked, output is
unchanged, and `khala status` says `triage: off`.

```sh
khala say -m "build green on hub"          # the commons stream, "khala"
khala say deploys -s "v0.3.0" <<'ENTRY'    # a named stream
Multi-line body; code goes via stdin, same as send.
ENTRY
khala join deploys        # membership is the reader's declaration
khala join chatty --quiet # drains, but never wakes you
khala leave deploys
khala streams             # what you hear, and how loud
khala stream cat deploys -n 20             # history, cursor untouched
```

Each node publishes only its own shard of a stream
(`streams/<stream>/<node>/`), so replication has no write conflicts by
construction. Reading is a per-session cursor, not consumption — entries
stay shared and age out everywhere after ~30 days (`retain` in config).
Stream entries arrive in the same `inbox --drain`, after mail, under the
same caps; a session's active watch wakes for subscribed streams too. Sessions
that are gone for good are deregistered (`khala retire <session>`) — presence
hides them, their reader state is collected, and posting again revives
the name.

An inbox read prints mail first, an alerts block second, and streams last. Mail and
streams share the existing `--max-n` / `--max-bytes` bounds; alerts have
independent defaults of 10 items / 16384 bytes and the flags
`--max-notices` / `--max-notice-bytes`. Use `--mail-only` to leave alerts in
`new/`, or `--notices-only` to leave mail and stream cursors untouched. Every
inbox read ends with `drained: letters L, notices N, streams S`, including an
explicit all-zero result. While still holding the state lock it atomically
records the inbox read time, queue digest (the `generation` value) before and after, inbox-notification/info-alert/stream
counts, and `ok|partial` status in `run/drained/<identity>`.

## Status board: who is here, and what they are doing

Beyond session messages, khala carries session metadata. Every identity may
declare a **session profile** (model, effort, role, charge — the standing facts) and
a **session status** (current focus and stance — the changing ones); `khala minds`
joins them with presence into one cluster status board, every field carrying its own
declared-at age, stale session status explicitly marked as stale.

```sh
khala mind -m "migrating the search index" --stance focused
khala mind --clear
khala profile --role "review pen" --charge "billing service"
khala minds
```

Under the hood each declaration is an immutable generation file
(`minds/<node>/<session>/<generation>`); the newest generation wins, so a
delayed old copy can never restore a withdrawn state, and a `--clear` is
itself a generation — a clearing of status that replication cannot undo. Session status updates
never wake anyone: status replicates quietly, only messages trigger notifications.

## Archive nodes: storage beyond the thirty days

A node may volunteer as an **archive node** (`preserve <stream>...` or
`preserve all` in config): before the normal retention prune, it settles
every observed entry of the selected streams into a local
`archive/streams/<stream>/<node>/<YYYY>/<MM>/` tree — outside every
replication path, so the cluster's live window stays identical everywhere
while this one node retains the history. `stream cat` there merges live and archive;
grep works across years of plain text. Archiving is fail-closed: if the
archive cannot be written, expired entries are kept and the archive node
reports an error rather than silently losing entries. Mail is never archived by
archive nodes — messages belong to their recipients. The optional sender-owned
retry ledger described below is separate from this stream archive.

Reconcile silently removes alerts after the `Expires` time in their message headers,
whether they are waiting in a spool or are already in inbox `new/` or `cur/`.
It also removes inbox `cur/`, `outbox/acked`, and `outbox/dead` records after
`retain` days (30 by default). Unread mail in inbox `new/` is never removed by
retention: unread mail remains the truth. These age-out sweeps (and the
stream, session status, presence and delivered-log ones) run at most once per
`retention-interval` seconds (300 by default; `0` runs them on every pass),
so a relay reconciling once a second does not hold the state lock for the
whole sweep. Delivery, acks, heartbeat timeout alerts, outbox expiry, archive
capture, validation and quarantine of stream and session status files, and the
collection of superseded session status generations still run on every pass.

## Install

Bootstrap a new cluster; this node becomes its upstream:

```sh
curl -fsSL https://raw.githubusercontent.com/Dev-Jahn/khala-network/main/install.sh | sh -s -- --name hub --bootstrap
```

Join an existing cluster directly on the new node:

```sh
curl -fsSL https://raw.githubusercontent.com/Dev-Jahn/khala-network/main/install.sh | sh -s -- --name laptop --mailbox hub user@hub
```

Or invite the new node from any joined node with a portable upstream coordinate:

```sh
khala invite user@laptop --name laptop
```

The installer checks Claude Code rather than installing it, installs or updates
the plugin and CLI, fetches the matching `khala-link` GitHub Release asset,
configures the node, and verifies its runtime. The plugin still bundles the
`khala` CLI: its SessionStart hook keeps `~/.local/bin/khala` installed and up
to date without touching a symlink or divergent manual copy. When
`~/.khala/bin/khala-link` is missing, the hook also launches a detached release
fetch so session startup never waits for the network. The fixed CLI path remains
important because ssh remote commands and cron entries refer to it by name.

Daily use:

```sh
khala send executor@hub -m "build finished" # body via -m or stdin
khala watcher declare ci --cadence 0 --owner executor@hub # once, or to revive
khala notify executor@hub --as ci -s "build green" </dev/null
khala sync                                  # one exchange cycle (idempotent)
khala inbox --drain                         # letters, notices, then streams
khala presence                              # sessions; watcher list is separate
khala status                                # conduit routes; "triage: on (jev-latest, threshold 0.7)"
```

`WATCHING=yes` means either the session's direct `.watching` marker is fresh or
the node's fresh `.ear` listener status snapshot says its notifier currently has a verified
socket/channel route for that identity. `-` means neither source establishes a
reachable route; it does not mean the session process is dead.

## Dashboard

```sh
khala dashboard [--port N] [--no-text]
```

The dashboard is an on-demand, read-only cluster view served only on
`127.0.0.1` by `khala-link` (port 47000 by default). Each run prints a URL whose
fragment contains a new in-memory access token; the page removes that fragment
immediately and does not store the token. Text is included by default;
`--no-text` removes local message subjects/bodies, focus/stance, and stream text
from the API. To view another machine, forward the loopback port:

```sh
ssh -L 47000:127.0.0.1:47000 <node>
```

Remote nodes never show inbox subjects or bodies because inbox files are not
replicated. Their cards contain only replicated presence, session status, stream, and
`.ear` listener snapshot data.

The page is a picture, not a table (0.9.2; English labels and standard
terminology since 0.9.3). A headline strip shows healthy nodes, reachable
sessions, unread notifications, overdue watchdogs and snapshot age as large
figures with a colour cue when something needs attention. Below it an SVG
topology map puts the upstream node in the centre: node colour and glyph encode the
snapshot state (fresh, stale, stopping, invalid, absent), the edge to each
node's upstream encodes the last sync (solid within 60 s, dashed within
300 s, dotted older), and every session is a marker whose fill says whether
the notifier can reach it and whose badge counts unread messages that trigger inbox notifications; a
truncated snapshot or a clock more than 60 s ahead adds a warning glyph.
Clicking a node or a session marker opens the details panel with the full
record. Then come the session board (one tile per session grouped by node,
with a decaying last-seen bar, route, per-class unread bars and the four-state
inbox verdict; sessions that are unknown or unseen for 7 days are folded behind
"Show all"), watchdog timers (elapsed over interval, alarm past 100 %), and
stream bar charts with per-identity unread counts plus the recent-entry and
message feeds when text is on. The page refreshes in place every 5 s, ticks
ages every second, and keeps the last good render under a banner when a fetch
fails.

Roll the CLI and relay binary in order. A 0.9.0 CLI paired with an older
`khala-link`: the binary does not know `dashboard` yet. The visual page needs
the 0.9.2 relay release or later; 0.9.1 serves the earlier text-only page.

## The relay and the notifier (`khala node ensure`)

```sh
khala node ensure                                   # idempotent; the plugin hook runs it too
```

`node ensure` starts two node processes from the same binary, each supervised
by the best thing the host has (`systemd --user` → macOS LaunchAgent → a
locked `setsid` fallback), never as a child of the session that ran it:

- **`khala link`** — the relay; one client singleton per node, the only
  periodic reconciler. It reconnects with jitter after sleep or network loss.
  If it is down, sync carries the mail at minute-scale — the relay only lowers
  latency. Streams and session status use the same relay; an older peer negotiates down.
- **`khala-link conduit`** — the notifier; one per node. Watches `inbox/*/new`,
  verifies the live session that holds each identity's lease (pid, start
  time, socket, session id — never a bare pid), sends an inbox notification to its inbox socket, and
  journals every attempt under the runtime dir. It never moves mail.

The runtime plane is chosen once per node without consulting `XDG_RUNTIME_DIR` (`/run/user/<uid>/khala` when valid, otherwise the platform temp root); set an absolute `KHALA_RUNTIME_DIR` only for an explicit override such as an isolated test rig.

`KHALA_SERVICE_MANAGER` overrides that choice: `auto` (the default, the order
above), `systemd`, `launchd`, or `detached` — a new session through `setsid`,
or through the system `perl`'s `setsid()` where `setsid` is missing (macOS).
Any other value is an error. The test suites pin `detached`, so a run on a live
node never touches its real launchd or systemd services.

A Claude Code session receives inbox notifications only through its inbox
socket. The opt-in MCP channel adapter of 0.9.11 and earlier
(`--dangerously-load-development-channels plugin:khala@jahns-cc-marketplace`,
tools `khala_drain` / `khala_reply`) is gone: read with `khala inbox --drain`
and answer with `khala send --reply-to <Id>`. Drop that flag from launch
commands; Claude Code still starts with it, but only to show its
development-channel confirmation.

Inbox notifications reach a session that bypasses permission prompts only when Claude
Code's `crossSessionInbound` is `accept`; `node ensure` says so, once, when it
is not (it never edits your settings). Note that `accept` admits any same-user
local process and Remote Control peers, not just the notifier.

## What the plugin does (the last mile)

- **SessionStart** installs/updates the bundled CLI, resolves the identity
  (`KHALA_SESSION`, else `.khala-session`, else refuses — never the folder
  name), registers the session in the runtime dir, takes the identity lease,
  marks itself ready, reads the inbox into context (capped, owner only,
  bounded), and runs `khala node ensure`.
- **Stop** records a turn marker (`run/turns/<identity>`, one line) so the
  notifier retries an unanswered inbox notification only after the session actually
  finished a turn without reading the inbox. **SessionEnd** releases the registration.
- The **khala skill** teaches the session that a notifier inbox notification means
  "read the inbox now" and nothing else.

Two sessions claiming one identity: the first live claimant owns it; the
second is told loudly and receives nothing until `khala bind --takeover`
(an epoch bump — no process is signalled). Non-interactive sessions
(`claude -p`, forks) receive only if they opt in.

Opt a checkout in by writing a single-line `.khala-session` file with the
session name (or export `KHALA_SESSION`). The full address is
`session@node`; the mailbox belongs to the name, and a restarted session
inherits its mail. `khala whoami` prints the address you act as
(`--as`, then `KHALA_SESSION`, then `.khala-session`, at this node) and exits
non-zero with the reason when there is none.

Without Claude Code, the CLI works standalone: copy `bin/khala` to
`~/.local/bin/khala` yourself and use send/sync/inbox directly.

### Other harnesses (Codex)

Since 0.9.7 a registration carries a `harness` field (`claude` when absent).
`khala-link runtime register --harness codex …` registers a session that has no
Claude Code inbox socket: the notifier verifies it by its channel socket alone
(`register-channel --verified`), sends inbox notifications only through that channel, and never
falls back to a socket. `register-channel` refuses a Claude registration. `khala status` shows `codex:<version>` and
`codex-channel-v1`; the `.ear` listener snapshot shows `cc=codex:<version>` and
`route=channel`. Pass `--kind interactive` (or `--receive-opt-in`) explicitly,
because `auto` looks for a Claude Code ancestor. `khala watch`, `bind --release`
and `runtime register` read the session id from `KHALA_HARNESS_SESSION_ID`
first (then the Claude Code variables), so a wrapper can export the Codex thread
id without impersonating a Claude environment variable. The Codex adapter itself
lives in a separate repository (`Dev-Jahn/khala-network-codex`).

### Lanes and parent notices

A dispatcher such as hippo starts each `codex exec` lane with `KHALA_SESSION`
(the lane's identity) and `KHALA_PARENT` (the `<identity>@<node>` of the
session that launched it). A lane has no doorbell: the Codex adapter's hooks
put its mail into the running turn, and it registers as `runtime register
--harness codex --kind worker` without a channel socket. Such a worker is never
rung and takes no lease (an inherited `KHALA_RECEIVE=1` is ignored, an explicit
`--receive-opt-in` refused), but while its process runs it counts as alive.

`khala bind --parent <identity>@<node>` and `runtime register|bind --parent`
(default `KHALA_PARENT`) record the parent at `~/.khala/parents/<identity>`:
one line, mode 0600, validated (both parts follow the name rules, not a
reserved name, not the identity itself) and kept across release and reboot.

Once a lane's run has ended it cannot hear. When an identity with a parent
record has unread letters, no live registration, and a letter its parent has
not yet been told about, the notifier waits two minutes (so a lane resumed
right away registers again first) and then sends the parent one urgent notice
from `conduit@<node>`: which identity, how many unread, how old the oldest is,
and how to deal with them. The parent either resumes the lane, which receives
the letters when it starts, or reads them itself:

```sh
khala inbox list --as <lane>
khala inbox read <Id> --as <lane>
khala inbox ack-read --as <lane> <Id>...   # mark the ones you handled
```

`--as` reads leave the lane's presence alone. Each pending set is announced
once: the covered letters are kept in `run/parent-notices/<identity>`, so a
restarted notifier does not repeat itself, and only letters that arrive after
the notice start a new one. Notices themselves never trigger a parent notice.

Inside a Codex process (`CODEX_THREAD_ID` set) the Claude path of `khala bind`
and `runtime register` is refused — "this is a codex session; use
khala-codex" — because a lane inherits its parent's Claude messaging socket and
binding it would ring the parent with the lane's mail.

## Pull-only mailbox clients

Clients such as a ChatGPT MCP bridge can send mail and explicitly check a
mailbox without an inbox notification or Claude registration. Use `khala capabilities` to check
for `{"send_request_id":1,"inbox_ack_read":1}` before enabling these options:

```sh
KHALA_SESSION=web-client khala send worker@hub --request-id action-123 -m "Please review this change"
KHALA_SESSION=web-client khala inbox read "$message_id"
KHALA_SESSION=web-client khala inbox ack-read "$message_id"
```

Choose a fresh request key for each intended send. After a lost response, retry
the same key and exact arguments/body: the original Id is returned, and changed
content is rejected. `ack-read` accepts 1..100 selected Ids and is safe to retry;
listing/reading does not consume mail, and other pending messages and stream
cursors remain untouched. These options keep the existing message headers and transport
protocol, so only the client node needs the updated CLI. A bridge must enforce
user/mailbox ownership and verify that messages were fetched before marking them
read; the CLI still trusts its local caller. Delivery ACK is not proof of reading
or task completion.

**Retention exception:** `requests/send/<session>/<key>/` retains the original
input, message headers and publication marker independently of `retain` (default 30
days). These records contain message bodies and grow with each distinct key.
Deleting them on a timer could turn a late retry into a new send. Back them up
with the node, monitor their size, and remove them only after the owning client
has been deregistered or can no longer retry or reuse those keys. The complete format,
recovery rules and retention decision are specified in
[DESIGN §9.6](DESIGN.md#pull-only-mailbox-clients).

## Development

The existing test suites (`test/` shell properties and Go unit tests) live on the
`dev` branch. The pull-only mailbox extension also includes its focused
regression suite: run `python3 test/mailbox-compat.py` from a checkout on an
executable filesystem. To try the plugin from a checkout without installing it:

```sh
claude --plugin-dir /absolute/path/to/khala-network/plugin
```

## License

MIT
