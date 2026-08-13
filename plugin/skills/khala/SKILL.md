---
name: khala
description: Cross-machine session mail over the khala network — send letters, drain the inbox, keep the watch armed, read presence. Use when messaging another Claude Code session (same or another machine), when a khala letter arrives, or when asked about fleet presence.
---

# Khala

Use the session identity in this order: `KHALA_SESSION`, then the single-line
`.khala-session` in `CLAUDE_PROJECT_DIR`, then the project directory basename.
Names must match `[a-z0-9][a-z0-9-]*`; never lowercase or otherwise rewrite an
invalid name. A valid `.khala-session` is an explicit opt-in contract: the Stop
hook will refuse to leave the session idle without an armed watch. `KHALA_SESSION`
is the same explicit contract for that process.

Send a letter with:

```sh
khala send <session@node> -s "plain subject"
```

For a body containing code, backticks, shell syntax, or multiple lines, always
send it on stdin with a quoted heredoc; never put it in `-m`:

```sh
khala send <session@node> -s "plain subject" <<'KHALA_LETTER'
The body may contain `code` and $shell syntax literally.
KHALA_LETTER
```

Use `-m "plain one-line body"` only for literal plain text. Apply the same
discipline to every `-m` or `-s` shell argument: keep code and backticks out of
arguments, and keep the subject plain when the body needs the heredoc.

When the armed watch exits, treat the task notification as a wake: immediately
run `khala inbox --drain`, process the letters, then re-arm the one-shot ear as a
background task:

```sh
KHALA_SESSION=<session> khala watch --session <session> --interval 30
```

Use `run_in_background` for that command. Keep exactly one watch per session;
the singleton makes an accidental double arm harmless. Keep interval 30. A live
link reduces effective delivery latency to about one second, so shorter watch
intervals only add noise.

Run `khala presence` to read the fleet map. Its columns are identity, observed
state (`alive-here`, `alive-elsewhere`, `asleep`, or `unknown`), last-seen age,
and watching status. Presence is honest but limited: it reports recent Khala
activity, not process liveness, and `watching` means the ear is armed, not that
the Claude Code session is alive.

Never type into another session's pane and never signal another session's
processes. Delivery is always a durable mailbox write; waking is always the
receiver's own armed watch exiting into its own task-notification path. This
R13 identity boundary is non-negotiable.

The link is the node-level nerve. SessionStart ensures it is running when a
`khala-link` binary is installed. Check the mtime of
`$KHALA_HOME/run/link.fresh` (default home: `~/.khala`); a fresh marker means the
link is active. If the link is absent or stale, Khala remains fully functional
at the watch interval cadence through the same mailbox protocol.
