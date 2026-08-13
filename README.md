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
- **The ear — `khala watch`**: exits the moment mail lands in the session's
  inbox, so a Claude Code background task wakes the session. With a live
  nerve, send-to-wake is second-scale end to end.

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

## Optional: the nerve cord (`khala link`, second-scale propagation)

```sh
cd link && go build -o ~/.khala/bin/khala-link .   # or cross-build with GOOS/GOARCH
nohup khala link >> ~/.khala/log/link.log 2>&1 &
```

One link per node; a flock singleton makes repeat starts harmless. It
reconnects by itself with jitter after sleep or network loss. If it is down,
sync/watch carry the mail at minute-scale — the link only lowers latency.

## What the plugin does (the last mile)

- **SessionStart** installs/updates the bundled CLI, drains the session inbox
  into context (capped), and ensures the node link is up.
- **Stop** re-arms the mail watch for sessions that opted in, so an idle
  session is always wakeable by mail.
- The **khala skill** teaches the session safe usage.

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
