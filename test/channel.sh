#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO:-/NHNHOME/jahn/go-toolchain/bin/go}
BUN=${BUN:-$(command -v bun)}
SERVER=${KHALA_CHANNEL_SERVER:-$ROOT/plugin/channel/server.ts}
CASE=${1:-all}
RIG=${KHALA_TEST_ROOT:-${HOME}/.khala-channel-test-$$}
BIN=$RIG/bin/khala-link
HOME_RIG=$RIG/home
KHALA_HOME_RIG=$RIG/khala-home
RUNTIME=$RIG/runtime
CC_SESSIONS=$RIG/cc-sessions
SESSION_ID=h21-session
IDENTITY=h21
PROJECT_DIR=$RIG/project
PIDS=

case $CASE in
    all|fast|h21a|h21b|h21c) ;;
    *) printf 'usage: %s [all|fast|h21a|h21b|h21c]\n' "$0" >&2; exit 2 ;;
esac

cleanup() {
    for cleanup_pid in $PIDS; do
        kill "$cleanup_pid" 2>/dev/null || :
        wait "$cleanup_pid" 2>/dev/null || :
    done
    rm -rf -- "$RIG"
}

fail() {
    printf 'FAIL H21 — %s\n' "$*" >&2
    [ ! -f "$RIG/channel.err" ] || cat "$RIG/channel.err" >&2
    exit 1
}

wait_file() {
    wait_path=$1
    wait_i=0
    while [ ! -e "$wait_path" ] && [ "$wait_i" -lt 100 ]; do
        sleep 0.05
        wait_i=$((wait_i + 1))
    done
    [ -e "$wait_path" ]
}

mkdir -p "$RIG/bin" "$HOME_RIG" "$CC_SESSIONS" "$HOME/.cache/khala-go-tmp" \
    "$HOME/.cache/khala-go-build" || exit 1
trap cleanup EXIT HUP INT TERM
mkdir -p "$PROJECT_DIR" && printf '%s\n' "$IDENTITY" > "$PROJECT_DIR/.khala-session" || fail "project fixture"

(cd "$ROOT/link" && GOTMPDIR=$HOME/.cache/khala-go-tmp \
    GOCACHE=$HOME/.cache/khala-go-build CGO_ENABLED=0 "$GO" build -o "$BIN" .) || \
    fail "Go build failed"
ln -s "$KHALA" "$RIG/bin/khala" || fail "khala PATH shim failed"
KHALA_HOME=$KHALA_HOME_RIG "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" || \
    fail "khala init failed"
mkdir -p "$KHALA_HOME_RIG/bin"
cp "$BIN" "$KHALA_HOME_RIG/bin/khala-link"

uv venv --python 3.13 "$RIG/venv" >/dev/null || fail "test Python venv failed"
CC_SOCKET=$RIG/cc.sock
"$RIG/venv/bin/python" "$ROOT/test/conduit-listener.py" "$CC_SOCKET" \
    "$RIG/cc.frames" "$RIG/cc.ready" >"$RIG/cc.out" 2>"$RIG/cc.err" &
CC_PID=$!
PIDS="$PIDS $CC_PID"
wait_file "$RIG/cc.ready" || fail "CC socket listener did not bind"
CC_SOCKET_2=$RIG/cc-2.sock
"$RIG/venv/bin/python" "$ROOT/test/conduit-listener.py" "$CC_SOCKET_2" \
    "$RIG/cc-2.frames" "$RIG/cc-2.ready" >"$RIG/cc-2.out" 2>"$RIG/cc-2.err" &
CC_PID_2=$!
PIDS="$PIDS $CC_PID_2"
wait_file "$RIG/cc-2.ready" || fail "second CC socket listener did not bind"
printf '{"pid":%s,"sessionId":"%s","name":"h21","version":"2.1.234","messagingSocketPath":"%s","cwd":"%s"}\n' \
    "$CC_PID" "$SESSION_ID" "$CC_SOCKET" "$PROJECT_DIR" > "$CC_SESSIONS/$CC_PID.json"
# The channel child under Claude Code runs with the plugin directory as cwd and
# without CLAUDE_CODE_SESSION_ID/KHALA_SESSION; it must find its session and
# project through its parent process's registry entry. The MCP client below
# rewrites this second registry entry to its own pid before spawning the child.
CHILD_REGISTRY=$CC_SESSIONS/child-parent.json
printf '{"pid":0,"sessionId":"%s","name":"h21","version":"2.1.234","messagingSocketPath":"%s","cwd":"%s"}\n' \
    "$SESSION_ID" "$CC_SOCKET" "$PROJECT_DIR" > "$CHILD_REGISTRY"

REGISTER=$(env KHALA_HOME=$KHALA_HOME_RIG KHALA_RUNTIME_DIR=$RUNTIME \
    KHALA_TEST_BOOT_ID=channel-test-boot KHALA_CLAUDE_SESSIONS_DIR=$CC_SESSIONS \
    KHALA_SESSION=$IDENTITY "$KHALA" bind --register ready --session-id "$SESSION_ID" \
    --pid "$CC_PID" --socket "$CC_SOCKET" --kind interactive --cc-version 2.1.234) || \
    fail "session registration failed"
INSTANCE=$(printf '%s\n' "$REGISTER" | sed -n 's/^instance //p')
[ -n "$INSTANCE" ] || fail "session registration returned no instance"
REGISTRATION=$RUNTIME/sessions/$INSTANCE.json
SESSION_ID_2=h21-session-2
REGISTER_2=$(env KHALA_HOME=$KHALA_HOME_RIG KHALA_RUNTIME_DIR=$RUNTIME \
    KHALA_TEST_BOOT_ID=channel-test-boot KHALA_CLAUDE_SESSIONS_DIR=$CC_SESSIONS \
    KHALA_SESSION=$IDENTITY "$KHALA" bind --register ready --session-id "$SESSION_ID_2" \
    --pid "$CC_PID_2" --socket "$CC_SOCKET_2" --kind interactive --cc-version 2.1.234) || \
    fail "second session registration failed"
INSTANCE_2=$(printf '%s\n' "$REGISTER_2" | sed -n 's/^instance //p')
[ -n "$INSTANCE_2" ] || fail "second session registration returned no instance"
[ "$INSTANCE" != "$INSTANCE_2" ] || fail "second session registration reused the first instance"
REGISTRATION_2=$RUNTIME/sessions/$INSTANCE_2.json

SDK_ROOT=$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7/node_modules
[ -d "$SDK_ROOT/@modelcontextprotocol/sdk" ] || fail "telegram MCP SDK cache missing"
ln -s "$SDK_ROOT" "$RIG/node_modules" || fail "MCP SDK rig symlink failed"

# A child without a khala identity must stay connected as an inert MCP server
# (Claude Code quarantines a plugin server that closes stdio right after
# connecting: ~/.claude/mcp-needs-auth-cache.json), log one line, write no
# MCP frames on its own, and exit 0 when stdin closes.
mkdir -p "$RIG/no-identity"
H21_INBOX=$KHALA_HOME_RIG/inbox/$IDENTITY
reset_inbox() {
    mkdir -p "$H21_INBOX/new" "$H21_INBOX/cur" || fail "inbox fixture directories"
    rm -f -- "$H21_INBOX/new/1700000000.1.8.sender@alpha" \
        "$H21_INBOX/cur/1700000000.1.8.sender@alpha"
    cat > "$H21_INBOX/new/1700000000.1.8.sender@alpha" <<'EOF'
Khala: 0.1
Id: 1700000000.1.8.sender@alpha
From: sender@alpha
To: h21@alpha
Date: 2026-08-18T00:00:00Z
Type: message
Subject: H21 drain
Expires: 1999999999

body from H21 inbox
EOF
}

set_child_registry() {
    registry_session_id=$1
    printf '{"pid":0,"sessionId":"%s","name":"h21","version":"2.1.234","messagingSocketPath":"%s","cwd":"%s"}\n' \
        "$registry_session_id" "$CC_SOCKET" "$PROJECT_DIR" > "$CHILD_REGISTRY"
}

PLUGIN_CWD=$RIG/plugin-cwd
mkdir -p "$PLUGIN_CWD"

run_client() {
    client_scenario=$1
    shift
    env -u KHALA_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        HOME=$HOME_RIG KHALA_HOME=$KHALA_HOME_RIG KHALA_RUNTIME_DIR=$RUNTIME \
        KHALA_TEST_BOOT_ID=channel-test-boot KHALA_CLAUDE_SESSIONS_DIR=$CC_SESSIONS \
        KHALA_CHANNEL_POLL_MS=200 NODE_PATH=$RIG/node_modules PATH=$RIG/bin:/usr/bin:/bin \
        "$RIG/venv/bin/python" "$ROOT/test/channel-mcp-client.py" \
        --bun "$BUN" --server "$SERVER" --scenario "$client_scenario" \
        --registration "$REGISTRATION" --inbox "$H21_INBOX" \
        --outbox "$KHALA_HOME_RIG/outbox/new" --channels-dir "$RUNTIME/channels" \
        --cwd "$PLUGIN_CWD" --registry-pid-file "$CHILD_REGISTRY" \
        --stderr "$RIG/channel.err" "$@"
}

if [ "$CASE" = all ] || [ "$CASE" = fast ]; then
    (cd "$RIG/no-identity" && env -u KHALA_SESSION -u CLAUDE_CODE_SESSION_ID HOME=$HOME_RIG NODE_PATH=$RIG/node_modules \
        KHALA_CLAUDE_SESSIONS_DIR=$RIG/empty-sessions PATH=$RIG/bin:/usr/bin:/bin \
        "$BUN" "$SERVER" >"$RIG/no-identity.out" 2>"$RIG/no-identity.err") < <(sleep 2) || \
        fail "no-identity child did not exit 0 on stdin close"
    [ ! -s "$RIG/no-identity.out" ] || fail "no-identity child wrote MCP stdout unprompted"
    [ "$(wc -l < "$RIG/no-identity.err" | tr -d ' ')" -eq 1 ] || fail "no-identity child did not log exactly one line"
    grep -q 'no valid session identity' "$RIG/no-identity.err" || fail "no-identity explanation differs"

    set_child_registry "$SESSION_ID"
    reset_inbox
    run_client full || fail "fast MCP/channel/reply protocol failed"
    printf 'ok H21 fast — registry-ready child attached, forwarded, drained, replied, and cleaned up\n'
fi

if [ "$CASE" = all ] || [ "$CASE" = h21a ]; then
    set_child_registry h21-resume-temp
    reset_inbox
    run_client full --late-session-id "$SESSION_ID" || fail "H21a late session-id attach failed"
    printf 'ok H21a — child stayed connected, listed tools before attach, re-resolved the resumed session id, and completed H21\n'
fi

if [ "$CASE" = all ] || [ "$CASE" = h21b ]; then
    set_child_registry h21-never-matches
    run_client orphan --registration-2 "$REGISTRATION_2" || fail "H21b socketpair EOF cleanup failed"
    printf 'ok H21b — socketpair stdin EOF stopped the waiting child without a socket or registration orphan\n'
fi

if [ "$CASE" = all ] || [ "$CASE" = h21c ]; then
    set_child_registry "$SESSION_ID"
    run_client reattach --registration-2 "$REGISTRATION_2" --next-session-id "$SESSION_ID_2" || \
        fail "H21c session-change re-attach failed"
    printf 'ok H21c — attached child cleared its old instance, moved to the rewritten session, and answered there\n'
fi

printf 'RESULT: PASS\n'
printf 'Channel H21 fast, late-resume, socketpair EOF, re-attach, tools, doorbell, and cleanup properties passed\n'
