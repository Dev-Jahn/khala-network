# khala-network

Account-independent mail between Claude Code sessions across your machines.

Khala joins the Claude Code sessions running on a fleet of machines — cloud
containers, lab servers, laptops — into one store-and-forward network that
depends on no Claude account, no shared filesystem, and no third-party server.
A message to a sleeping machine waits on the sender's disk and is delivered
when a path opens; nothing is ever silently dropped.

## How it works

One design, three organs. Every node owns its slice of a single logical mail
tree on disk; everything else exists to make those slices converge.

- **Brain — `bin/khala`** (bash 3.2 compatible, zero dependencies beyond
  ssh/rsync/coreutils): all semantics. `send` is a durable enqueue; delivery,
  acks, dedup, bounces, and expiry are decided only by the owner of each path.
  Every on-disk format is plain text you can read with grep.
- **Nerve — `khala link`** (single Go binary, optional): a zero-semantics
  file-event pump that keeps node trees converging within seconds. It runs
  over a plain ssh pipe — spokes dial `ssh <hub> khala link --serve`, so the
  hub needs no daemon, no new port, no new credentials.
- **Ear — `khala watch`**: exits the moment mail lands in a session's inbox,
  so a Claude Code background task wakes the session. With a live link the
  whole path is second-scale; without one, everything still arrives on the
  next `khala sync`.

Messages are at-least-once with receiver-side dedup. Undeliverable mail
bounces back to the sender; a bounce that cannot be delivered is laid to rest
in a dead-letter box, never retried forever. Khala never types into a
session's input line — the input line is the user's identity; delivery is by
mailbox only.

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
khala send alice@hub -m "build finished"    # body via -m or stdin
khala sync                                  # one exchange cycle (idempotent)
khala inbox --drain                         # read your mail
khala presence                              # who is alive / asleep / watching
```

## Optional: the link (second-scale propagation)

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
