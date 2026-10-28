# Telegram gateway (`khala-link gateway`)

The gateway lets you talk to your Claude Code sessions from a phone. It uses one
Telegram bot and one Telegram group with **Topics** enabled (a forum
supergroup). Each session gets its own topic: what you write in the topic
arrives in the session's khala inbox, and what the session sends back appears in
the topic.

- The gateway is its own khala node named `gateway`, hosted on the Mac mini
  (the same way the ChatGPT bridge runs as node `chatgpt`). It has its own
  `KHALA_HOME`, its own relay (`khala link`) and the gateway daemon.
- Your messages are ordinary khala messages (`Type: message`) from the reserved
  sender `user`, so they arrive as `From: user@gateway`. Sessions answer with
  `khala send user@gateway --reply-to <Id>`.
- No new envelope type and no new header. The link between a khala message Id
  and the Telegram message it came from lives only in the gateway's state file.
- The gateway reads its inbox with the non-destructive pull API
  (`khala inbox list` / `inbox read` / `inbox ack-read`) and sends with
  `khala send --request-id tg-<update_id>`. A message is marked read only after
  it was posted to Telegram; a Telegram update is confirmed only after khala
  returned a message Id for it.

## Setup

### 1. Bot and group (Telegram app)

1. Talk to **@BotFather**: `/newbot`, choose a name and a username. Keep the
   token (`123456:ABC…`) secret.
2. Optional: `/setprivacy` → *Disable*. An admin bot receives all group
   messages anyway; this only makes it explicit (see measurement item 2).
3. Create a new group. In the group settings turn on **Topics**. Telegram
   converts it to a supergroup.
4. Add the bot to the group, promote it to **admin** and give it
   **Manage Topics**.
5. Get the chat id and your own user id. Before the gateway runs (two pollers
   on one token conflict with HTTP 409), write anything in the group, then:

   ```sh
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
   ```

   `message.chat.id` is the chat id (negative, `-100…`); `message.from.id` is
   your user id. Alternatively forward a group message to **@userinfobot**.

### 2. The `gateway` node (on the mini)

```sh
export KHALA_HOME=~/.local/share/khala-gateway/node
khala init gateway
cat >> "$KHALA_HOME/config" <<'EOF'
peer mini mini
mailbox mini
EOF
mkdir -p "$KHALA_HOME/bin"
cp ~/.khala/bin/khala-link "$KHALA_HOME/bin/khala-link"   # the same release as the mini
```

`peer mini <ssh alias>` must reach the mini's own node over ssh (loopback alias
is fine). `khala init` writes `self gateway`; keep it.

### 3. `gateway.conf`

`$KHALA_HOME/gateway.conf`, mode 0600, owned by you. One `key value` per line,
`#` starts a comment. An unknown key, a duplicate key or a malformed value stops
the gateway with exit status 2 and the reason on stderr.

```
adapter telegram
khala bin /Users/<you>/.local/bin/khala        # required, absolute
telegram token 123456:ABC...                   # or: telegram token-file /abs/path (0600)
telegram chat -1001234567890
telegram allow 11111111                        # numeric user ids; repeatable; empty = nobody may write
telegram chunk-limit 3                         # default 3
user expires 259200                            # seconds a message waits for delivery; default 3 days
stall-after 900                                # seconds of unread before "stalled"; default 15 min
poll-timeout 30                                # getUpdates long-poll seconds; default 30
notices forward off                            # off | urgent | all; recorded only (see below)
```

```sh
chmod 600 "$KHALA_HOME/gateway.conf"
KHALA_HOME=~/.local/share/khala-gateway/node ~/.local/share/khala-gateway/node/bin/khala-link gateway --once
```

`--once` polls once, relays the inbox once, posts status once and exits; the
log line `gateway: connected as @<bot> chat=<id> topics=<n>` confirms the token
and the chat.

### 4. launchd

Two agents: the relay of the gateway node and the gateway daemon. Their labels
must differ from the mini's own `dev.khala.link` / `dev.khala.conduit`.

`~/Library/LaunchAgents/dev.khala.gateway-node.link.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.khala.gateway-node.link</string>
<key>ProgramArguments</key><array>
  <string>/Users/YOU/.local/bin/khala</string><string>link</string>
</array>
<key>EnvironmentVariables</key><dict>
  <key>KHALA_HOME</key><string>/Users/YOU/.local/share/khala-gateway/node</string>
</dict>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
</dict></plist>
```

`~/Library/LaunchAgents/dev.khala.gateway.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.khala.gateway</string>
<key>ProgramArguments</key><array>
  <string>/Users/YOU/.local/share/khala-gateway/node/bin/khala-link</string><string>gateway</string>
</array>
<key>EnvironmentVariables</key><dict>
  <key>KHALA_HOME</key><string>/Users/YOU/.local/share/khala-gateway/node</string>
</dict>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>30</integer>
<key>RunAtLoad</key><true/>
</dict></plist>
```

```sh
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/dev.khala.gateway-node.link.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/dev.khala.gateway.plist
```

The gateway exits 2 on a configuration error; `ThrottleInterval` keeps launchd
from restarting it in a tight loop while you fix the file.

## Operation

### Files

| Path (under the gateway node's `KHALA_HOME`) | What |
|---|---|
| `gateway.conf` | configuration (0600) |
| `gateway.state.json` | topics (address ↔ topic id), reply threads (khala Id → Telegram message, pruned after 7 days), `offset`, last posted status, notice preferences. 0600, atomic writes. **Back it up**: a lost file loses the topic mapping |
| `run/gateway.pid` | `pid` and `start` of the running gateway, held with an exclusive lock; a second gateway on the same node refuses to start |
| `log/gateway.log` | log (rotated at 1 MiB); also written to stderr |
| `requests/send/user/tg-*` | khala's request ledger, one per Telegram update. Kept forever by design (README "Retention exception"); remove old ones by hand only while the gateway is stopped |

### Writing to a session

1. In **General**: `/open steno@b200`. The gateway checks the address and that
   node `b200` has a listener snapshot, then creates the topic `steno@b200`.
2. Write in that topic. Each Telegram message becomes one khala message: the
   subject is the first line (up to 80 characters), the body is the full text.
   Only text is relayed; photos and files get a one-line refusal.
3. A message in a topic that is not linked gets "use /open".

If the session never picks the message up, khala expires it after
`user expires` seconds (3 days) and the gateway answers the original Telegram
message with `not delivered: Delivery expired for <address>`.

### Replies

- A session's message to `user@gateway` is posted in the sender's topic. If
  the sender has no topic yet, the gateway creates one (first contact).
- With `--reply-to <Id>` of one of your messages, the post is a Telegram reply
  to your original message. Otherwise it is a plain post in the topic.
- A subject is shown as a first line `[subject]`.
- Long messages: up to 4096 UTF-16 units (Telegram's limit; Korean text is one
  unit per character, emoji two) are posted as is. Longer text is split at line
  boundaries into up to `telegram chunk-limit` (3) posts; beyond that the whole
  text is sent as one `.md` document with its first 300 characters as caption.
- Posting is limited to 20 posts per minute for the group; the rest waits in
  memory in order. On shutdown the gateway posts what it can in 10 seconds;
  messages not posted stay unread in khala and are posted after the restart.
- Delivery to Telegram is at least once: if the gateway dies after posting and
  before `ack-read`, the message is posted again after the restart.

### Status posts

Derived only from the replicated listener snapshots `presence/conduit@<node>.ear`
on the gateway node, for addresses that have a topic, every 30 seconds. A post
appears only when the status changes, at most once per 5 minutes per topic.

| Post | Meaning |
|---|---|
| `connected` | the session is registered and its listener is up (snapshot lists it with a route) |
| `stalled: unread for N min` | registered, but has had unread messages for at least `stall-after` (15 min). The age comes from the snapshot's `oldest-pending`, else `first-seen`, else the time the gateway first saw it unread |
| `disconnected` | the session is not in its node's snapshot, is listed without a route, or the snapshot is older than 10 minutes |

A snapshot written while the node's listener is stopping for a restart, or a
truncated snapshot that omits the session, changes nothing.

### General-topic commands

Only commands; any other text in General is ignored.

| Command | Effect |
|---|---|
| `/sessions` | every session in the cluster's snapshots (and every open topic): `address — status (N unread)` |
| `/open <name@node>` | create and record the session's topic |
| `/close <name@node>` | close the topic and forget it. Messages in transit still land in khala; the session's next reply opens a new topic |
| `/say <stream> <text>` | `khala say <stream> -m <text>` as `user` |
| `/notices <name@node> off\|urgent\|all` | record a notice preference (not acted on yet) |
| `/help` | the list |

Messages from Telegram users not listed in `telegram allow` are ignored (logged
once per user per hour); messages from other chats are ignored silently.

## Not done in this version

- **Notice forwarding.** Notices go to the session's inbox on its own node,
  which the gateway cannot see. `/notices` and `notices forward` only record the
  preference. Notices that arrive in the gateway's own inbox are marked read
  without a post.
- **Permission relay** (approving tool prompts from the phone).
- **Natural language** in the bot: routing is by topic, commands by `/`.
- Attachments and images from Telegram.
- Reaction on delivery, reopening closed topics, a second gateway for failover.
- The CLI does not yet reserve `user`. Until the B-CLI lane lands, `khala send
  --as user` succeeds, and any session could in principle name itself `user`.

## Measurements to record on the first live run

Design §8. Fill in the result and the date.

| # | Item | Result |
|---|---|---|
| 1 | How a General-topic message carries `message_thread_id` (absent / 1 / reply id). The adapter treats a message without `is_topic_message` as General, and the core also accepts thread 1 | |
| 2 | Whether an admin bot receives every topic message regardless of privacy mode | |
| 3 | Unit of the 4096 `sendMessage` limit (UTF-16 code units assumed; test with 2048 emoji + 1 character) | |
| 4 | Emoji set usable with `setMessageReaction` in a group (not used yet) | |
| 5 | Topic count limit (create 60 topics) | |
| 6 | Whether 20 posts/minute is per group or per topic | |
| 7 | Whether Claude Code still gates non-marketplace channels behind a flag | Moot (2026-10-28): khala no longer ships a Claude Code channel; sessions are notified through their inbox socket |
| 8 | What is lost when the gateway is stopped for more than 24 hours (Telegram keeps unconfirmed updates for 24 h) | |
| 9 | End-to-end timings: phone → `inbox/new` → notification → session reads → reply → topic | |
