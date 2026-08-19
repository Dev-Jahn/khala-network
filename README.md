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
- **The conduit — `khala-link conduit`** (0.6.0): the node's resident ear.
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

## Two kinds of thought: letters and streams

A letter (`send`) is an obligation: one recipient, acked end to end, bounced
when undeliverable. A stream (`say`) is communion: you speak into a named
shared record and every joined session reads it — no recipient list, no
acks, no bounces, because there is no single mind owing you a reply.

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

## Install

```sh
claude plugin marketplace add Dev-Jahn/jahns-cc-marketplace
claude plugin install khala@jahns-cc-marketplace
```

That is the whole install. The plugin bundles the `khala` CLI and its
SessionStart hook keeps `~/.local/bin/khala` installed and up to date (it
never touches a symlink or a manually installed copy — it says so instead).
The CLI still needs the fixed path because ssh remote commands and cron
entries on other machines refer to it by that name.

Then, once per machine, join the fleet:

```sh
khala init laptop        # your node alias: [a-z0-9][a-z0-9-]*
```

and declare your fleet in `~/.khala/config` (one line = one fact; endpoint
candidates may be ssh aliases from `~/.ssh/config`, host coordinates, or
absolute paths for same-machine testing):

```
self laptop
peer laptop laptop
peer hub hub                # ssh alias defined in ~/.ssh/config
mailbox hub                 # post-office priority; delete the self entry
ttl 120                     # presence freshness in seconds
```

The hub is just any node the others can reach over ssh — its own config says
`self hub` and `mailbox hub`, and it simply waits.

Daily use:

```sh
khala send executor@hub -m "build finished" # body via -m or stdin
khala sync                                  # one exchange cycle (idempotent)
khala inbox --drain                         # read your mail
khala presence                              # who is alive / asleep / watching
```

## The nerve cord and the conduit (`khala node ensure`)

```sh
cd link && go build -o ~/.khala/bin/khala-link .   # or cross-build with GOOS/GOARCH
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
