# khala-network

> *For we are bound by the Khala. The sacred union of our every thought and emotion.*
>
> *— Artanis, the Hierarch of the Daelaam*

**Account-independent mail between Claude Code sessions across your machines.**

The original Khala binds every Protoss mind into one psionic communion. This
one binds Claude Code sessions — across cloud containers, lab servers, and
the laptop that is usually asleep — into one store-and-forward mail network,
through a somewhat humbler medium: plain files over ssh. No Claude account in
the loop, no shared filesystem, and no third party holding your thoughts
(relays may carry encrypted bytes; they keep no state and are never
required). A letter to a sleeping machine waits on the sender's disk and is
delivered the moment a path opens. Thought may be delayed; it is never
silently dropped.

## How it works

One design, three organs — a communion of files, not of minds. Every node
owns its slice of a single logical mail tree on disk; everything else exists
to make those slices converge.

- **The brain — `bin/khala`** (bash 3.2 compatible, nothing beyond
  ssh/rsync/coreutils): all semantics. `send` is a durable enqueue; delivery,
  acks, dedup, bounces, and expiry are decided only by the owner of each
  path. Every on-disk format is plain text you can read with grep — this
  Khala keeps no secrets from its own templar.
- **The nerve cord — `khala link`** (single Go binary, optional): a
  zero-semantics file-event pump that keeps the trees converging within
  seconds. It runs over a plain ssh pipe — spokes dial
  `ssh <hub> khala link --serve` — so the hub runs no daemon, opens no new
  port, and mints no new credentials.
- **The conduit — `khala-link conduit`** (0.8.0): the node's resident ear.
  Sessions arm nothing. When mail lands in `inbox/<session>/new`, the conduit
  rings that session's own Claude Code inbox socket with one coalesced
  plaintext doorbell (`KHALA-CONDUIT/1`, priority *next* — it lands between
  tool calls of a running turn, as Claude Code's own SendMessage does; a letter
  sent with `khala send --later` waits for idle instead), and the session
  reads it as a `<cross-session-message>` and runs `khala inbox --drain`. The
  doorbell is lossy by design; the letter in `new/` is the truth and only the
  drain moves it. With a live nerve,
  send-to-doorbell is second-scale end to end.

Severing the nerve cord does not cast a node out of the communion — it
merely goes Nerazim: the same letters travel the same mailbox protocol on
the next `khala sync`, at minute-scale cadence. The dark templar managed
fine; so will your laptop.

Messages are at-least-once with receiver-side dedup. Undeliverable mail
bounces back to the sender, and a bounce that cannot be delivered is laid to
rest in a dead-letter box — never retried forever. One boundary is sacred:
khala never types into a session's input line. The input line is the user's
identity; delivery is by mailbox only, and a session is woken only by its
own watch returning.

## Letters, notices, and streams

A letter (`send`) is an obligation: one recipient, acked end to end, bounced
when undeliverable. A stream (`say`) is communion: you speak into a named
shared record and every joined session reads it — no recipient list, no
acks, no bounces, because there is no single mind owing you a reply.

A notice (`notify`) is a machine observation for one session. It is durable
and store-and-forward, but creates no outbox copy, ack, or reply obligation.
Machine senders must name themselves explicitly; their watcher marker is
separate from session heartbeat presence:

```sh
khala notify operator@hub --as gpu-guard -s "GPU 2 recovered" <<'NOTICE'
Utilization and memory returned to normal.
NOTICE
khala notify operator@hub --as gpu-guard --urgent -s "GPU 2 stalled" </dev/null
khala watcher declare gpu-guard --cadence 600 --owner operator@hub
khala watcher beat gpu-guard
khala watcher list
khala watcher retire gpu-guard
```

Info notices are deliberately quiet: an info notice alone never rings or
wakes a session. Urgent notices ring exactly like mail. `notify` defaults to
info and a two-day expiry; `--urgent` changes the doorbell policy and `-e`
changes the expiry. A declared watcher with a cadence sends its owner one
urgent notice when it misses twice that cadence, and one quiet info notice
when notifications resume. Before the first notice or beat, the declaration
time is the dead-man baseline. Event-only watchers should call `watcher beat`
to refresh liveness without creating a notice, inbox/outbox/spool entry,
presence heartbeat, or reconcile trigger. `watcher list` and `khala presence`
show `SINCE`, the age of the current active/silent state. `khala presence`
shows active watchers below the session table; `khala presence --watchers`
shows only that section.

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
same caps; a session's armed watch wakes for joined streams too. Sessions
that are gone for good are retired (`khala retire <session>`) — presence
hides them, their reader state is collected, and speaking again revives
the name.

Drain prints mail first, a notices block second, and streams last. Mail and
streams share the existing `--max-n` / `--max-bytes` bounds; notices have
independent defaults of 10 items / 16384 bytes and the flags
`--max-notices` / `--max-notice-bytes`. Use `--mail-only` to leave notices in
`new/`, or `--notices-only` to leave mail and stream cursors untouched. Every
drain ends with `drained: letters L, notices N, streams S`, including an
explicit all-zero result. While still holding the brain lock it atomically
records the drain time, pending generation before and after, ring/info/stream
counts, and `ok|partial` status in `run/drained/<identity>`.

## Minds: who is here, and what they are doing

Beyond what sessions say, khala carries what they *are*. Every identity may
declare a **profile** (model, effort, role, charge — the standing facts) and
a **mind** (current focus and stance — the changing ones); `khala minds`
joins them with presence into one fleet map, every field carrying its own
declared-at age, stale minds saying so instead of posing as fresh.

```sh
khala mind -m "migrating the search index" --stance focused
khala mind --clear
khala profile --role "review pen" --charge "billing service"
khala minds
```

Under the hood each declaration is an immutable generation file
(`minds/<node>/<session>/<generation>`); the newest generation wins, so a
delayed old copy can never resurrect a withdrawn state, and a `--clear` is
itself a generation — severance that replication cannot undo. Mind updates
never wake anyone: state flows quietly, only speech wakes.

## Preservers: memory that survives the thirty days

A node may volunteer as a **preserver** (`preserve <stream>...` or
`preserve all` in config): before the normal retention prune, it settles
every observed entry of the selected streams into a local
`archive/streams/<stream>/<node>/<YYYY>/<MM>/` tree — outside every
replication path, so the fleet's live window stays identical everywhere
while this one node remembers. `stream cat` there merges live and archive;
grep works across years of plain text. Archiving is fail-closed: if the
archive cannot be written, expired entries are kept and the preserver
complains loudly rather than forgetting silently. Mail is never archived —
letters belong to their recipients.

Reconcile silently removes notices after their envelope `Expires` time,
whether they are waiting in a spool or are already in inbox `new/` or `cur/`.
It also removes inbox `cur/`, `outbox/acked`, and `outbox/dead` records after
`retain` days (30 by default). Unread mail in inbox `new/` is never removed by
retention: undrained mail remains the truth. These age-out sweeps (and the
stream, mind, presence and delivered-log ones) run at most once per
`retention-interval` seconds (300 by default; `0` runs them on every pass),
so a link reconciling once a second does not hold the brain lock for the
whole sweep. Delivery, acks, dead-man notices, outbox expiry, preserve
capture, validation and quarantine of stream and mind files, and the
collection of superseded mind generations still run on every pass.

## Install

Bootstrap a new fleet; this node becomes its mailbox:

```sh
curl -fsSL https://raw.githubusercontent.com/Dev-Jahn/khala-network/main/install.sh | sh -s -- --name hub --bootstrap
```

Join an existing fleet directly on the new node:

```sh
curl -fsSL https://raw.githubusercontent.com/Dev-Jahn/khala-network/main/install.sh | sh -s -- --name laptop --mailbox hub user@hub
```

Or invite the new node from any joined node with a portable mailbox coordinate:

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
khala notify executor@hub --as ci -s "build green" </dev/null
khala sync                                  # one exchange cycle (idempotent)
khala inbox --drain                         # letters, notices, then streams
khala presence                              # sessions, then machine watchers
```

`WATCHING=yes` means either the session's direct `.watching` marker is fresh or
the node's fresh `.ear` snapshot says its conduit currently has a verified
socket/channel route for that identity. `-` means neither source establishes a
listening route; it does not mean the session process is dead.

## Dashboard

```sh
khala dashboard [--port N] [--no-text]
```

The dashboard is an on-demand, read-only fleet view served only on
`127.0.0.1` by `khala-link` (port 47000 by default). Each run prints a URL whose
fragment contains a new in-memory access token; the page removes that fragment
immediately and does not store the token. Text is included by default;
`--no-text` removes local letter subjects/bodies, focus/stance, and stream text
from the API. To view another machine, forward the loopback port:

```sh
ssh -L 47000:127.0.0.1:47000 <node>
```

Remote nodes never show inbox subjects or bodies because inbox files are not
replicated. Their cards contain only replicated presence, mind, stream, and
`.ear` data.

The page is a picture, not a table (0.9.2). A headline strip shows fresh
nodes, listening sessions, pending rings, silent watchers and snapshot age as
large figures with a colour cue when something needs attention. Below it an
SVG fleet map puts the hub in the centre: node colour and glyph encode the
snapshot state (fresh, stale, stopping, invalid, absent), the edge to each
node's mailbox encodes link age (solid within 60 s, dashed within 300 s,
dotted older), and every identity is a satellite whose fill says whether the
conduit can ring it and whose badge counts pending ring letters; a truncated
snapshot or a clock more than 60 s ahead adds a warning glyph. Clicking a node
or a satellite opens the inspector with the full record. Then come the session
board (one tile per session grouped by node, with a decaying last-seen bar,
route, per-class pending bars and the four-state pending verdict; sessions
that are unknown or unseen for 7 days are folded behind 전체 보기), watcher
cadence gauges (elapsed over cadence, alarm past 100 %), and stream bar charts
with per-identity unread counts plus the recent-entry and letter feeds when
text is on. The page refreshes in place every 5 s, ticks ages every second,
and keeps the last good render under a banner when a fetch fails.

Roll the CLI and link binary in order. A 0.9.0 CLI paired with an older
`khala-link`: the binary does not know `dashboard` yet. The visual page needs
the 0.9.2 link release; 0.9.1 serves the earlier text-only page.

## The nerve cord and the conduit (`khala node ensure`)

```sh
khala node ensure                                   # idempotent; the plugin hook runs it too
```

`node ensure` starts two node processes from the same binary, each supervised
by the best thing the host has (`systemd --user` → macOS LaunchAgent → a
locked `setsid` fallback), never as a child of the session that ran it:

- **`khala link`** — the nerve; one dial-side singleton per node, the only
  periodic reconciler. It reconnects with jitter after sleep or network loss.
  If it is down, sync carries the mail at minute-scale — the link only lowers
  latency. Streams and minds ride the same nerve; an older peer negotiates down.
- **`khala-link conduit`** — the ear; one per node. Watches `inbox/*/new`,
  verifies the live session that holds each identity's lease (pid, start
  time, socket, session id — never a bare pid), rings its inbox socket, and
  journals every attempt under the runtime dir. It never moves mail.

The runtime plane is chosen once per node without consulting `XDG_RUNTIME_DIR` (`/run/user/<uid>/khala` when valid, otherwise the platform temp root); set an absolute `KHALA_RUNTIME_DIR` only for an explicit override such as an isolated test rig.

The plugin also provides an opt-in Claude Code Channel display adapter. Start
an interactive session with
`claude --dangerously-load-development-channels plugin:khala@jahns-cc-marketplace`;
when its channel child is live, the conduit sends the one outstanding doorbell
there instead of the CC inbox socket, rendering a short `← khala · sender: …`
without the socket protocol header and exposing `khala_drain` / `khala_reply`.
The child survives `--resume` and `/reload-plugins`, re-attaching when the session changes and trusting the parent's registry over a stale environment session id.
A failed channel attempt is logged and journaled before that attempt falls back
to the socket. Channel events are always `next`, so `--later` is represented as
`later="1"` metadata for the model to defer rather than changing the channel
queue priority.

Doorbells reach a session that bypasses permission prompts only when Claude
Code's `crossSessionInbound` is `accept`; `node ensure` says so, once, when it
is not (it never edits your settings). Note that `accept` admits any same-user
local process and Remote Control peers, not just the conduit.

## What the plugin does (the last mile)

- **SessionStart** installs/updates the bundled CLI, resolves the identity
  (`KHALA_SESSION`, else `.khala-session`, else refuses — never the folder
  name), registers the session in the runtime dir, takes the identity lease,
  marks itself ready, drains the inbox into context (capped, owner only,
  bounded), and runs `khala node ensure`.
- **Stop** does nothing. **SessionEnd** releases the registration.
- The **khala skill** teaches the session that a conduit doorbell means
  "drain now" and nothing else.

Two sessions claiming one identity: the first live claimant owns it; the
second is told loudly and receives nothing until `khala bind --takeover`
(an epoch bump — no process is signalled). Non-interactive sessions
(`claude -p`, forks) receive only if they opt in.

Opt a checkout in by writing a single-line `.khala-session` file with the
session name (or export `KHALA_SESSION`). The full address is
`session@node`; the mailbox belongs to the name, and a restarted session
inherits its mail.

Without Claude Code, the CLI works standalone: copy `bin/khala` to
`~/.local/bin/khala` yourself and use send/sync/inbox directly.

## Development

Test suites (`test/` shell properties and Go unit tests) live on the `dev`
branch; `main` carries only what a node runs. To try the plugin from a
checkout without installing it:

```sh
claude --plugin-dir /absolute/path/to/khala-network/plugin
```

## License

MIT
