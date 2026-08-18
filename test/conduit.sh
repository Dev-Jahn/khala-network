#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO:-/NHNHOME/jahn/go-toolchain/bin/go}
RIG=${KHALA_TEST_ROOT:-${HOME}/.khala-conduit-test-$$}
BIN=$RIG/khala-link
RUNTIME_BASE=$RIG/runtime
LISTENER=$ROOT/test/conduit-listener.py
CHANNEL_LISTENER=$ROOT/test/channel-listener.py
PIDS=

cleanup() {
    for cleanup_pid in $PIDS; do
        kill "$cleanup_pid" 2>/dev/null || :
        wait "$cleanup_pid" 2>/dev/null || :
    done
    for cleanup_status in "$RIG"/*/run/link.status; do
        [ -f "$cleanup_status" ] || continue
        cleanup_pid=$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$cleanup_status")
        [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || :
    done
    rm -rf -- "$RIG"
}

fail() {
    fail_step=$1
    shift
    printf 'FAIL %s — %s\n' "$fail_step" "$*" >&2
    if [ -d "$RIG" ]; then
        find "$RIG" -maxdepth 5 -type f -print | sort >&2
    fi
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

wait_file() {
    wait_path=$1
    wait_limit=$2
    wait_i=0
    while [ ! -e "$wait_path" ] && [ "$wait_i" -lt "$wait_limit" ]; do
        sleep 0.05
        wait_i=$((wait_i + 1))
    done
    [ -e "$wait_path" ]
}

line_count() {
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d ' '
    else
        printf '0\n'
    fi
}

wait_lines() {
    wait_lines_path=$1
    wait_lines_count=$2
    wait_lines_limit=$3
    wait_lines_i=0
    while [ "$(line_count "$wait_lines_path")" -lt "$wait_lines_count" ] && \
        [ "$wait_lines_i" -lt "$wait_lines_limit" ]; do
        sleep 0.05
        wait_lines_i=$((wait_lines_i + 1))
    done
    [ "$(line_count "$wait_lines_path")" -ge "$wait_lines_count" ]
}

init_home() {
    init_target=$1
    KHALA_HOME=$init_target "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" || \
        fail setup "khala init failed: $(tr '\n' ' ' < "$RIG/init.err")"
    mkdir -p "$init_target/bin"
    cp "$BIN" "$init_target/bin/khala-link"
}

runtime_env() {
    env KHALA_RUNTIME_DIR="$RUNTIME_BASE" KHALA_TEST_BOOT_ID=conduit-test-boot \
        KHALA_CLAUDE_SESSIONS_DIR="$RIG/cc-sessions" "$@"
}

start_listener() {
    listener_name=$1
    listener_session=$2
    listener_socket=$RIG/$listener_name.sock
    listener_output=$RIG/$listener_name.frames
    listener_ready=$RIG/$listener_name.ready
    "$RIG/venv/bin/python" "$LISTENER" "$listener_socket" "$listener_output" \
        "$listener_ready" >"$RIG/$listener_name.listener.out" \
        2>"$RIG/$listener_name.listener.err" &
    LISTENER_PID=$!
    PIDS="$PIDS $LISTENER_PID"
    wait_file "$listener_ready" 100 || fail setup "$listener_name listener did not bind"
    mkdir -p "$RIG/cc-sessions"
    printf '{"pid":%s,"sessionId":"%s","name":"%s","version":"2.1.233","messagingSocketPath":"%s"}\n' \
        "$LISTENER_PID" "$listener_session" "$listener_session" "$listener_socket" \
        > "$RIG/cc-sessions/$LISTENER_PID.json"
    LISTENER_SOCKET=$listener_socket
    LISTENER_OUTPUT=$listener_output
}

start_channel_listener() {
    channel_name=$1
    channel_instance=$2
    channel_socket=$RUNTIME_BASE/channels/$channel_instance.sock
    channel_output=$RIG/$channel_name.channel-frames
    channel_ready=$RIG/$channel_name.channel-ready
    "$RIG/venv/bin/python" "$CHANNEL_LISTENER" "$channel_socket" "$channel_output" \
        "$channel_ready" >"$RIG/$channel_name.channel.out" \
        2>"$RIG/$channel_name.channel.err" &
    CHANNEL_LISTENER_PID=$!
    PIDS="$PIDS $CHANNEL_LISTENER_PID"
    wait_file "$channel_ready" 100 || fail setup "$channel_name channel listener did not bind"
    CHANNEL_SOCKET=$channel_socket
    CHANNEL_OUTPUT=$channel_output
}

register_session() {
    register_home=$1
    register_identity=$2
    register_session_id=$3
    register_pid=$4
    register_socket=$5
    register_kind=$6
    register_phase=$7
    register_extra=${8-}
    # shellcheck disable=SC2086
    runtime_env KHALA_HOME="$register_home" KHALA_SESSION="$register_identity" \
        "$KHALA" bind --register "$register_phase" --session-id "$register_session_id" \
        --pid "$register_pid" --socket "$register_socket" --kind "$register_kind" \
        --cc-version 2.1.233 $register_extra
}

stage_letter() {
    stage_home=$1
    stage_identity=$2
    stage_seq=$3
    stage_from=${4-sender@alpha}
    stage_extra=${5-}
    stage_dir=$stage_home/inbox/$stage_identity/new
    mkdir -p "$stage_dir"
    cat > "$stage_dir/1700000000.1.$stage_seq.sender@alpha" <<EOF
Khala: 0.1
Id: 1700000000.1.$stage_seq.sender@alpha
From: $stage_from
To: $stage_identity@alpha
Date: 2026-08-16T00:00:00Z
Type: message
Subject: conduit-$stage_seq${stage_extra:+
$stage_extra}
Expires: 1999999999

body-$stage_seq
EOF
}

start_conduit() {
    conduit_home=$1
    shift
    env KHALA_RUNTIME_DIR="$RUNTIME_BASE" KHALA_TEST_BOOT_ID=conduit-test-boot \
        KHALA_CLAUDE_SESSIONS_DIR="$RIG/cc-sessions" KHALA_HOME="$conduit_home" \
        KHALA_CONDUIT_TEST_SCAN_INTERVAL=50ms \
        "$@" "$BIN" conduit &
    CONDUIT_PID=$!
    PIDS="$PIDS $CONDUIT_PID"
}

stop_pid() {
    stop_target=$1
    kill "$stop_target" 2>/dev/null || :
    wait "$stop_target" 2>/dev/null || :
}

mkdir -p "$RIG" "$RUNTIME_BASE" "$RIG/cc-sessions" || fail setup "fixture mkdir failed"
trap cleanup EXIT HUP INT TERM
(uv venv --python 3.13 "$RIG/venv" >/dev/null) || fail setup "test Python venv failed"
(cd "$ROOT/link" && CGO_ENABLED=0 "$GO" build -o "$BIN" .) || fail setup "Go build failed"

# H20 — a live channel child replaces the CC socket doorbell for the
# generation. A dead channel is recorded and falls back to the CC socket for
# the next generation, never delivering through both paths.
H20_HOME=$RIG/h20-home
init_home "$H20_HOME"
start_listener h20-cc h20-session
H20_CC_PID=$LISTENER_PID
H20_CC_SOCKET=$LISTENER_SOCKET
H20_CC_FRAMES=$LISTENER_OUTPUT
H20_REG=$(register_session "$H20_HOME" channelled h20-session "$H20_CC_PID" \
    "$H20_CC_SOCKET" interactive ready) || fail H20 "ready registration failed"
H20_INSTANCE=$(printf '%s\n' "$H20_REG" | sed -n 's/^instance //p')
start_channel_listener h20 "$H20_INSTANCE"
H20_CHANNEL_PID=$CHANNEL_LISTENER_PID
H20_CHANNEL_SOCKET=$CHANNEL_SOCKET
H20_CHANNEL_FRAMES=$CHANNEL_OUTPUT
runtime_env "$BIN" runtime register-channel --instance "$H20_INSTANCE" \
    --session-id h20-session --channel-socket "$H20_CHANNEL_SOCKET" \
    --caller-pid "$H20_CHANNEL_PID" >/dev/null || fail H20 "channel registration failed"
stage_letter "$H20_HOME" channelled 20 reel@bw2 "Priority: later"
start_conduit "$H20_HOME" env KHALA_CONDUIT_TEST_BACKOFF=500ms
H20_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H20_CHANNEL_FRAMES" 1 40 || fail H20 "live channel did not receive doorbell"
sleep 0.15
[ "$(line_count "$H20_CC_FRAMES")" -eq 0 ] || fail H20 "CC socket also received successful channel generation"
uv run --no-project python - "$H20_CHANNEL_FRAMES" <<'PY' || fail H20 "channel request JSON/shape invalid"
import json, sys
request = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert request["v"] == 1
assert request["content"] == "reel@bw2 · conduit-20\n1 letter — run khala_drain"
assert "KHALA-CONDUIT/1" not in request["content"]
assert "generation" not in request["content"]
assert "attempt" not in request["content"]
assert request["meta"]["from"] == "reel@bw2"
assert request["meta"]["subject"] == "conduit-20"
assert request["meta"]["pending"] == "1"
assert request["meta"]["user"] == "reel@bw2"
assert len(request["meta"]["generation"]) == 64
assert request["meta"]["attempt"]
assert request["meta"]["later"] == "1"
PY
grep -R -q '"via":"channel"' "$RUNTIME_BASE/deliveries/channelled/$H20_INSTANCE" || \
    fail H20 "channel delivery journal omitted via=channel"
runtime_env KHALA_HOME="$H20_HOME" "$BIN" runtime status > "$RIG/h20-status.out" || \
    fail H20 "runtime status failed"
grep -q $'SOCKET\tCHANNEL\tCC_VERSION' "$RIG/h20-status.out" || fail H20 "status omitted CHANNEL column"
grep -q $'channelled\t.*\tyes\tyes\t2.1.233' "$RIG/h20-status.out" || fail H20 "status did not show the registered channel"

stop_pid "$H20_CHANNEL_PID"
stage_letter "$H20_HOME" channelled 21 clawd@mini
wait_lines "$H20_CC_FRAMES" 1 40 || fail H20 "dead channel did not fall back to CC socket"
[ "$(line_count "$H20_CHANNEL_FRAMES")" -eq 1 ] || fail H20 "dead channel recorded another request"
uv run --no-project python - "$RUNTIME_BASE/deliveries/channelled/$H20_INSTANCE" <<'PY' || \
    fail H20 "socket fallback journal omitted channelError"
import glob, json, os, sys
journals = []
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    with open(path, encoding="utf-8") as journal_file:
        journals.append(json.load(journal_file))
latest = max(journals, key=lambda journal: journal["attemptedAt"])
assert latest["via"] == "socket", latest
assert latest["status"] == "written", latest
assert latest["channelError"], latest
PY
grep -q 'channel doorbell.*failed' "$H20_HOME/log/conduit.log" || fail H20 "channel failure was not logged"
pass H20 "live channel replaces the socket; dead channel is journaled and falls back once"
stop_pid "$H20_CONDUIT_PID"
stop_pid "$H20_CC_PID"

# H1/H2 — durable new/ remains authoritative and generations coalesce.
H1_HOME=$RIG/h1-home
init_home "$H1_HOME"
start_listener h1 h1-session
H1_LISTENER_PID=$LISTENER_PID
H1_SOCKET=$LISTENER_SOCKET
H1_FRAMES=$LISTENER_OUTPUT
H1_REGISTER=$(register_session "$H1_HOME" eddy h1-session "$H1_LISTENER_PID" \
    "$H1_SOCKET" interactive ready) || fail H1 "ready registration failed"
stage_letter "$H1_HOME" eddy 1 reel@bw2
start_conduit "$H1_HOME" env KHALA_CONDUIT_TEST_BACKOFF=500ms
H1_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H1_FRAMES" 1 40 || fail H1 "no frame within 2s"
sleep 0.15
[ "$(line_count "$H1_FRAMES")" -eq 1 ] || fail H1 "first generation rang more than once before backoff"
[ -f "$H1_HOME/inbox/eddy/new/1700000000.1.1.sender@alpha" ] || fail H1 "conduit consumed new/"
uv run --no-project python - "$H1_FRAMES" <<'PY' || fail H1 "frame JSON/shape invalid"
import json, sys
frame = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert frame["type"] == "user"
assert frame["message"]["role"] == "user"
assert frame["message"]["content"].startswith("KHALA-CONDUIT/1")
assert frame["priority"] == "next", frame["priority"]
assert ":" in frame["msg_id"]
PY
pass H1 "one valid doorbell arrived (priority next) and the letter remained in new/"

stage_letter "$H1_HOME" eddy 2 clawd@mini
wait_lines "$H1_FRAMES" 2 40 || fail H2 "second generation did not ring"
stage_letter "$H1_HOME" eddy 3 pen@b200
sleep 0.15
[ "$(line_count "$H1_FRAMES")" -eq 2 ] || fail H2 "third generation bypassed outstanding backoff"
wait_lines "$H1_FRAMES" 3 20 || fail H2 "third generation did not ring after backoff"
pass H2 "generation changes ring once and a burst remains coalesced until backoff"

stop_pid "$H1_CONDUIT_PID"
stop_pid "$H1_LISTENER_PID"

# H19 — doorbell priority: next by default; later only when every pending
# letter carries "Priority: later" (khala send --later); one ordinary letter in
# the batch keeps next; the header is read from the envelope, never the body.
H19_HOME=$RIG/h19-home
init_home "$H19_HOME"
start_listener h19 h19-session
H19_LISTENER_PID=$LISTENER_PID
H19_SOCKET=$listener_socket
H19_FRAMES=$LISTENER_OUTPUT
register_session "$H19_HOME" quiet h19-session "$H19_LISTENER_PID" \
    "$H19_SOCKET" interactive ready >/dev/null || fail H19 "ready registration failed"
stage_letter "$H19_HOME" quiet 1 reel@bw2 "Priority: later"
start_conduit "$H19_HOME" env KHALA_CONDUIT_TEST_BACKOFF=500ms
H19_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H19_FRAMES" 1 40 || fail H19 "later-only generation did not ring"
uv run --no-project python - "$H19_FRAMES" 1 later <<'PY' || fail H19 "later-only batch was not rung as later"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
frame = json.loads(lines[int(sys.argv[2]) - 1])
assert frame["priority"] == sys.argv[3], frame["priority"]
PY
stage_letter "$H19_HOME" quiet 2 clawd@mini
wait_lines "$H19_FRAMES" 2 40 || fail H19 "mixed generation did not ring"
uv run --no-project python - "$H19_FRAMES" 2 next <<'PY' || fail H19 "one ordinary letter did not lift the batch to next"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
frame = json.loads(lines[int(sys.argv[2]) - 1])
assert frame["priority"] == sys.argv[3], frame["priority"]
PY
stop_pid "$H19_CONDUIT_PID"
stop_pid "$H19_LISTENER_PID"
# a body line "Priority: later" is not a header
H19B_HOME=$RIG/h19b-home
init_home "$H19B_HOME"
start_listener h19b h19b-session
H19B_LISTENER_PID=$LISTENER_PID
H19B_FRAMES=$LISTENER_OUTPUT
register_session "$H19B_HOME" bodyonly h19b-session "$H19B_LISTENER_PID" \
    "$listener_socket" interactive ready >/dev/null || fail H19 "ready registration failed (body case)"
stage_letter "$H19B_HOME" bodyonly 1 reel@bw2
printf 'Priority: later\n' >> "$H19B_HOME/inbox/bodyonly/new/1700000000.1.1.sender@alpha"
start_conduit "$H19B_HOME" env KHALA_CONDUIT_TEST_BACKOFF=500ms
H19B_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H19B_FRAMES" 1 40 || fail H19 "body-case generation did not ring"
uv run --no-project python - "$H19B_FRAMES" 1 next <<'PY' || fail H19 "a body line was honoured as a Priority header"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
frame = json.loads(lines[int(sys.argv[2]) - 1])
assert frame["priority"] == sys.argv[3], frame["priority"]
PY
stop_pid "$H19B_CONDUIT_PID"
stop_pid "$H19B_LISTENER_PID"
pass H19 "doorbell is next by default, later only when every letter asks, and only via the envelope"

# H13 — a written doorbell is the one outstanding wake: the same generation is
# not rung again on the fast backoff (measured 2026-08-16: 6 attempts / 4
# visible duplicates in a 23-second turn). Only a generation change re-rings.
H13_HOME=$RIG/h13-home
init_home "$H13_HOME"
start_listener h13 h13-session
H13_LISTENER_PID=$LISTENER_PID
H13_SOCKET=$LISTENER_SOCKET
H13_FRAMES=$LISTENER_OUTPUT
register_session "$H13_HOME" h13id h13-session "$H13_LISTENER_PID" \
    "$H13_SOCKET" interactive ready >/dev/null || fail H13 "ready registration failed"
stage_letter "$H13_HOME" h13id 1 reel@bw2
start_conduit "$H13_HOME" env KHALA_CONDUIT_TEST_BACKOFF=200ms KHALA_CONDUIT_TEST_REWRITE_AFTER=30s
H13_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H13_FRAMES" 1 40 || fail H13 "no frame within 2s"
sleep 3
[ "$(line_count "$H13_FRAMES")" -eq 1 ] || fail H13 "written generation was re-rung within 3s (got $(line_count "$H13_FRAMES") frames)"
stage_letter "$H13_HOME" h13id 2 clawd@mini
wait_lines "$H13_FRAMES" 2 40 || fail H13 "generation change did not ring"
sleep 1
[ "$(line_count "$H13_FRAMES")" -eq 2 ] || fail H13 "second written generation was re-rung"
stop_pid "$H13_CONDUIT_PID"
stop_pid "$H13_LISTENER_PID"
pass H13 "a written doorbell is not re-rung on the fast backoff; only a generation change rings again"

# H3 — not-ready/missing sockets journal failure, then late-bind succeeds.
H3_HOME=$RIG/h3-home
init_home "$H3_HOME"
start_listener h3 h3-session
H3_PID=$LISTENER_PID
H3_SOCKET=$LISTENER_SOCKET
H3_FRAMES=$LISTENER_OUTPUT
H3_REG=$(register_session "$H3_HOME" late h3-session "$H3_PID" \
    "$RIG/missing.sock" interactive starting) || fail H3 "starting registration failed"
H3_INSTANCE=$(printf '%s\n' "$H3_REG" | sed -n 's/^instance //p')
stage_letter "$H3_HOME" late 4
start_conduit "$H3_HOME" env KHALA_CONDUIT_TEST_BACKOFF=200ms
H3_CONDUIT_PID=$CONDUIT_PID
sleep 0.3
[ "$(line_count "$H3_FRAMES")" -eq 0 ] || fail H3 "starting registration received a frame"
find "$RUNTIME_BASE/deliveries/late/$H3_INSTANCE" -name '*.json' \
    -exec grep -l '"status":"failed"' {} \; > "$RIG/h3-failed-journals"
[ -s "$RIG/h3-failed-journals" ] || fail H3 "failed attempt was not journaled"
register_session "$H3_HOME" late h3-session "$H3_PID" "$H3_SOCKET" interactive ready \
    "--instance $H3_INSTANCE" >/dev/null || fail H3 "late ready update failed"
wait_lines "$H3_FRAMES" 1 40 || fail H3 "socket appearance did not recover delivery"
[ -f "$H3_HOME/inbox/late/new/1700000000.1.4.sender@alpha" ] || fail H3 "failed/recovered path consumed new/"
pass H3 "unready/missing sockets fail durably and recover when the socket appears"
stop_pid "$H3_CONDUIT_PID"
stop_pid "$H3_PID"

# H14 — resume race: the lease was claimed before the Claude registry file
# existed (pid unknown → lease pid 0); once the registration resolves the pid,
# the conduit heals the lease and rings instead of failing forever with
# "pid/start mismatch" (measured 2026-08-16, ink `claude --resume`).
H14_HOME=$RIG/h14-home
init_home "$H14_HOME"
start_listener h14 h14-session
H14_PID=$LISTENER_PID; H14_SOCKET=$LISTENER_SOCKET; H14_FRAMES=$LISTENER_OUTPUT
# hide the registry entry so bind cannot learn the pid; register with pid 0
mv "$RIG/cc-sessions/$H14_PID.json" "$RIG/h14-registry.hidden"
H14_REG=$(register_session "$H14_HOME" resumed h14-session 0 "$H14_SOCKET" interactive ready) || \
    fail H14 "registration without registry failed"
H14_INSTANCE=$(printf '%s\n' "$H14_REG" | sed -n 's/^instance //p')
printf '%s\n' "$H14_REG" | grep -q '^owner yes$' || fail H14 "did not own lease"
uv run --no-project python - "$RUNTIME_BASE/identities/resumed.lease" <<'PY' || fail H14 "lease unexpectedly already carried a pid"
import json, sys
lease = json.load(open(sys.argv[1]))
assert lease["pid"] == 0, lease
PY
# registry lands later (resume ordering)
mv "$RIG/h14-registry.hidden" "$RIG/cc-sessions/$H14_PID.json"
stage_letter "$H14_HOME" resumed 5
start_conduit "$H14_HOME" env KHALA_CONDUIT_TEST_BACKOFF=200ms
H14_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H14_FRAMES" 1 60 || fail H14 "conduit never rang after the registry landed (lease pid stayed 0)"
uv run --no-project python - "$RUNTIME_BASE/identities/resumed.lease" "$H14_PID" <<'PY' || fail H14 "lease was not healed with the live pid"
import json, sys
lease = json.load(open(sys.argv[1]))
assert lease["pid"] == int(sys.argv[2]), lease
assert lease["pidStart"], lease
PY
[ -f "$H14_HOME/inbox/resumed/new/1700000000.1.5.sender@alpha" ] || fail H14 "healed path consumed new/"
pass H14 "a lease claimed before the Claude registry existed is healed with the live pid and rung"
stop_pid "$H14_CONDUIT_PID"
stop_pid "$H14_PID"

# H4/H5/H6 — exclusive lease, worker exclusion, epoch-only takeover.
H4_HOME=$RIG/h4-home
init_home "$H4_HOME"
start_listener owner owner-session
OWNER_PID=$LISTENER_PID; OWNER_SOCKET=$LISTENER_SOCKET; OWNER_FRAMES=$LISTENER_OUTPUT
OWNER_REG=$(register_session "$H4_HOME" shared owner-session "$OWNER_PID" "$OWNER_SOCKET" \
    interactive ready) || fail H4 "owner registration failed"
OWNER_INSTANCE=$(printf '%s\n' "$OWNER_REG" | sed -n 's/^instance //p')
start_listener claimant claimant-session
CLAIM_PID=$LISTENER_PID; CLAIM_SOCKET=$LISTENER_SOCKET; CLAIM_FRAMES=$LISTENER_OUTPUT
CLAIM_REG=$(register_session "$H4_HOME" shared claimant-session "$CLAIM_PID" "$CLAIM_SOCKET" \
    interactive ready) || fail H4 "claimant registration failed"
CLAIM_INSTANCE=$(printf '%s\n' "$CLAIM_REG" | sed -n 's/^instance //p')
printf '%s\n' "$OWNER_REG" | grep -q '^owner yes$' || fail H4 "first claimant did not own lease"
printf '%s\n' "$CLAIM_REG" | grep -q '^owner no$' || fail H4 "second claimant became owner"
stage_letter "$H4_HOME" shared 5
start_conduit "$H4_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s
H4_CONDUIT_PID=$CONDUIT_PID
wait_lines "$OWNER_FRAMES" 1 40 || fail H4 "lease owner was not rung"
[ "$(line_count "$CLAIM_FRAMES")" -eq 0 ] || fail H4 "non-owner was rung"
H4_PROJECT=$RIG/h4-project
mkdir -p "$H4_PROJECT"
printf '%s\n' shared > "$H4_PROJECT/.khala-session"
HOME=$RIG KHALA_HOME=$H4_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE KHALA_TEST_BOOT_ID=conduit-test-boot \
    KHALA_CLAUDE_SESSION_ID=h4-hook-session KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    CLAUDE_PROJECT_DIR=$H4_PROJECT PATH=$H4_HOME/bin:$ROOT/bin:/usr/bin:/bin \
    "$ROOT/plugin/hooks/session-start.sh" <<<'{"session_id":"h4-hook-session"}' \
    >"$RIG/h4-hook.out" 2>"$RIG/h4-hook.err" || fail H4 "non-owner SessionStart failed"
grep -q 'you are not the receiver of shared' "$RIG/h4-hook.out" || fail H4 "non-owner hook warning missing"
[ -f "$H4_HOME/inbox/shared/new/1700000000.1.5.sender@alpha" ] || fail H4 "non-owner hook drained mail"
pass H4 "only the lease owner is rung; a second SessionStart warns and drains nothing"

WORKER_REG=$(register_session "$H4_HOME" worker worker-session "$CLAIM_PID" "$CLAIM_SOCKET" \
    worker ready) || fail H5 "worker registration failed"
printf '%s\n' "$WORKER_REG" | grep -q '^owner no$' || fail H5 "worker owned lease without opt-in"
pass H5 "non-interactive registration cannot acquire a lease without opt-in"

old_epoch=$(uv run --no-project python - "$RUNTIME_BASE/identities/shared.lease" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["epoch"])
PY
)
runtime_env KHALA_HOME="$H4_HOME" KHALA_SESSION=shared KHALA_SESSION_INSTANCE="$CLAIM_INSTANCE" \
    KHALA_CLAUDE_SESSION_ID=claimant-session "$KHALA" bind --takeover >/dev/null || \
    fail H6 "takeover failed"
new_epoch=$(uv run --no-project python - "$RUNTIME_BASE/identities/shared.lease" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["epoch"])
PY
)
[ "$new_epoch" -eq "$((old_epoch + 1))" ] || fail H6 "takeover did not bump epoch exactly once"
kill -0 "$OWNER_PID" 2>/dev/null || fail H6 "takeover signalled the prior owner"
stage_letter "$H4_HOME" shared 6
wait_lines "$CLAIM_FRAMES" 1 40 || fail H6 "new owner was not rung after takeover"
kill -0 "$OWNER_PID" 2>/dev/null || fail H6 "old owner died after conduit reroute"
pass H6 "takeover bumps only the epoch, reroutes delivery, and sends no signal"

# H15 — a bind run from inside ANOTHER session (whose environment exports
# CLAUDE_CODE_MESSAGING_SOCKET, as every Bash child of a Claude Code session
# does) must not re-point an existing registration at that foreign socket.
# Measured 2026-08-16: this suite, run from a live session, silently rewired
# the takeover claimant to the runner's own inbox.
H15_REG_SOCKET=$(uv run --no-project python - "$RUNTIME_BASE/sessions/$CLAIM_INSTANCE.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["socketPath"])
PY
)
[ "$H15_REG_SOCKET" = "$CLAIM_SOCKET" ] || fail H15 "precondition: claimant socket is $H15_REG_SOCKET"
runtime_env KHALA_HOME="$H4_HOME" KHALA_SESSION=shared KHALA_SESSION_INSTANCE="$CLAIM_INSTANCE" \
    KHALA_CLAUDE_SESSION_ID=claimant-session CLAUDE_CODE_MESSAGING_SOCKET="$RIG/foreign.sock" \
    "$KHALA" bind --register ready --instance "$CLAIM_INSTANCE" --session-id claimant-session \
    --pid "$CLAIM_PID" --kind interactive --cc-version 2.1.233 >/dev/null || fail H15 "re-bind failed"
H15_AFTER=$(uv run --no-project python - "$RUNTIME_BASE/sessions/$CLAIM_INSTANCE.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["socketPath"])
PY
)
[ "$H15_AFTER" = "$CLAIM_SOCKET" ] || fail H15 "environment socket replaced the registration's socket ($H15_AFTER)"
runtime_env KHALA_HOME="$H4_HOME" KHALA_SESSION=shared KHALA_SESSION_INSTANCE="$CLAIM_INSTANCE" \
    KHALA_CLAUDE_SESSION_ID=claimant-session CLAUDE_CODE_MESSAGING_SOCKET="$RIG/foreign.sock" \
    "$KHALA" bind --register ready --instance "$CLAIM_INSTANCE" --session-id claimant-session \
    --pid "$CLAIM_PID" --socket "$RIG/explicit.sock" --kind interactive --cc-version 2.1.233 >/dev/null || fail H15 "explicit re-bind failed"
H15_EXPLICIT=$(uv run --no-project python - "$RUNTIME_BASE/sessions/$CLAIM_INSTANCE.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["socketPath"])
PY
)
[ "$H15_EXPLICIT" = "$RIG/explicit.sock" ] || fail H15 "explicit --socket was not honoured ($H15_EXPLICIT)"
pass H15 "an inherited CLAUDE_CODE_MESSAGING_SOCKET never re-points an existing registration; explicit --socket does"

# H16 — bind --release by Claude session id must not remove a LIVE registration
# owned by another process. `claude --resume` reuses the session id, so a late
# SessionEnd of the old process would otherwise delete the new session's
# registration (measured 2026-08-17: steno resumed 4x and was left deaf).
H16_HOME=$RIG/h16-home
init_home "$H16_HOME"
start_listener h16 h16-session
H16_PID=$LISTENER_PID; H16_SOCKET=$LISTENER_SOCKET
H16_REG=$(register_session "$H16_HOME" resumer h16-session "$H16_PID" "$H16_SOCKET" interactive ready) || \
    fail H16 "registration failed"
H16_INSTANCE=$(printf '%s\n' "$H16_REG" | sed -n 's/^instance //p')
# foreign caller (this shell is not an ancestor of the listener's registration pid) releases by session id
runtime_env KHALA_HOME="$H16_HOME" KHALA_SESSION=resumer "$KHALA" bind --release --session-id h16-session >/dev/null || \
    fail H16 "release by session id errored"
[ -f "$RUNTIME_BASE/sessions/$H16_INSTANCE.json" ] || fail H16 "release by session id deleted a live foreign registration"
uv run --no-project python - "$RUNTIME_BASE/identities/resumer.lease" <<'PY' || fail H16 "lease was released under a live owner"
import json, sys
lease = json.load(open(sys.argv[1]))
assert lease["state"] == "owned", lease
PY
# explicit instance still releases
runtime_env KHALA_HOME="$H16_HOME" KHALA_SESSION=resumer "$KHALA" bind --release --instance "$H16_INSTANCE" >/dev/null || \
    fail H16 "release by instance errored"
[ ! -f "$RUNTIME_BASE/sessions/$H16_INSTANCE.json" ] || fail H16 "release by explicit instance did not remove"
# a registration whose process has since died releases by session id
H16_REG2=$(register_session "$H16_HOME" resumer h16-session "$H16_PID" "$H16_SOCKET" interactive ready) || \
    fail H16 "second registration failed"
H16_INSTANCE2=$(printf '%s\n' "$H16_REG2" | sed -n 's/^instance //p')
stop_pid "$H16_PID"
runtime_env KHALA_HOME="$H16_HOME" KHALA_SESSION=resumer "$KHALA" bind --release --session-id h16-session >/dev/null || \
    fail H16 "release of dead-pid registration errored"
[ ! -f "$RUNTIME_BASE/sessions/$H16_INSTANCE2.json" ] || fail H16 "dead-pid registration was not released by session id"
pass H16 "release by session id spares a live foreign registration; explicit instance and dead pids still release"
stop_pid "$H4_CONDUIT_PID"
stop_pid "$OWNER_PID"
stop_pid "$CLAIM_PID"

# H7/H9 are hook-level gates: no identity refuses; non-owner never drains;
# ready registration survives a drain lock deadline.
H7_HOME=$RIG/h7-home
init_home "$H7_HOME"
H7_PROJECT=$RIG/h7-project
mkdir -p "$H7_PROJECT"
HOME=$RIG KHALA_HOME=$H7_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE \
    KHALA_TEST_BOOT_ID=conduit-test-boot CLAUDE_PROJECT_DIR=$H7_PROJECT \
    PATH=$H7_HOME/bin:$ROOT/bin:/usr/bin:/bin \
    "$ROOT/plugin/hooks/session-start.sh" </dev/null >"$RIG/h7.out" 2>"$RIG/h7.err" || \
    fail H7 "identity refusal hook exited nonzero"
grep -q 'KHALA_SESSION' "$RIG/h7.out" || fail H7 "identity instruction missing"
[ ! -d "$H7_HOME/inbox" ] || [ -z "$(find "$H7_HOME/inbox" -path '*/cur/*' -type f -print -quit)" ] || \
    fail H7 "identity refusal moved mail"

H9_PROJECT=$RIG/h9-project
mkdir -p "$H9_PROJECT"
printf '%s\n' timed > "$H9_PROJECT/.khala-session"
stage_letter "$H7_HOME" timed 7
mkdir -p "$H7_HOME/run/brain.lock.d"
printf '%s\npid %s contention\n' "$(date +%s)" "$$" > "$H7_HOME/run/brain.lock.d/owner"
h9_reconcile_pids=
h9_loop=1
while [ "$h9_loop" -le 3 ]; do
    setsid sh -c 'while :; do KHALA_HOME=$1 "$2" reconcile >/dev/null 2>&1 || :; done' \
        sh "$H7_HOME" "$KHALA" &
    h9_reconcile_pid=$!
    h9_reconcile_pids="$h9_reconcile_pids $h9_reconcile_pid"
    h9_loop=$((h9_loop + 1))
done
start_conduit "$H7_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s
H9_CONDUIT_PID=$CONDUIT_PID
h9_wait=0
while ! runtime_env KHALA_HOME="$H7_HOME" "$BIN" runtime daemon-status >/dev/null 2>&1 && \
    [ "$h9_wait" -lt 40 ]; do
    sleep 0.05
    h9_wait=$((h9_wait + 1))
done
[ "$h9_wait" -lt 40 ] || fail H9 "fixture conduit did not become live"
H7_OWNER=$(register_session "$H7_HOME" taken h7-owner "$$" "$RIG/h7-missing.sock" \
    interactive ready) || fail H7 "live owner registration failed"
printf '%s\n' "$H7_OWNER" | grep -q '^owner yes$' || fail H7 "fixture owner did not get lease"
stage_letter "$H7_HOME" taken 11
H7_TAKEN_PROJECT=$RIG/h7-taken-project
mkdir -p "$H7_TAKEN_PROJECT"
printf '%s\n' taken > "$H7_TAKEN_PROJECT/.khala-session"
HOME=$RIG KHALA_HOME=$H7_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE KHALA_TEST_BOOT_ID=conduit-test-boot \
    KHALA_CLAUDE_SESSION_ID=h7-other KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    CLAUDE_PROJECT_DIR=$H7_TAKEN_PROJECT PATH=$H7_HOME/bin:$ROOT/bin:/usr/bin:/bin \
    "$ROOT/plugin/hooks/session-start.sh" <<<'{"session_id":"h7-other"}' \
    >"$RIG/h7-taken.out" 2>"$RIG/h7-taken.err" || fail H7 "non-owner hook failed"
grep -q 'you are not the receiver of taken' "$RIG/h7-taken.out" || fail H7 "non-owner warning missing"
[ -f "$H7_HOME/inbox/taken/new/1700000000.1.11.sender@alpha" ] || fail H7 "non-owner moved mail"
pass H7 "SessionStart refuses inference and a valid non-owner consumes no mail"
h9_started=$(uv run --no-project python - <<'PY'
import time
print(time.monotonic())
PY
)
HOME=$RIG KHALA_HOME=$H7_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE \
    KHALA_TEST_BOOT_ID=conduit-test-boot KHALA_SESSION_INSTANCE=h9-instance \
    KHALA_CLAUDE_SESSION_ID=h9-session KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    CLAUDE_PROJECT_DIR=$H9_PROJECT PATH=$H7_HOME/bin:$ROOT/bin:/usr/bin:/bin \
    "$ROOT/plugin/hooks/session-start.sh" <<<'{"session_id":"h9-session"}' \
    >"$RIG/h9.out" 2>"$RIG/h9.err" || fail H9 "contended hook exited nonzero"
h9_finished=$(uv run --no-project python - <<'PY'
import time
print(time.monotonic())
PY
)
h9_elapsed=$(uv run --no-project python - "$h9_started" "$h9_finished" <<'PY'
import sys
print(float(sys.argv[2]) - float(sys.argv[1]))
PY
)
uv run --no-project python - "$h9_elapsed" <<'PY' || fail H9 "hook exceeded 12s: ${h9_elapsed}s"
import sys
assert float(sys.argv[1]) < 12.0
PY
grep -R -q '"phase":"ready"' "$RUNTIME_BASE/sessions" || fail H9 "registration never reached ready"
[ -f "$H7_HOME/inbox/timed/new/1700000000.1.7.sender@alpha" ] || fail H9 "timed-out drain consumed/misplaced mail"
rm -rf -- "$H7_HOME/run/brain.lock.d"
for h9_reconcile_pid in $h9_reconcile_pids; do
    kill -- "-$h9_reconcile_pid" 2>/dev/null || :
    wait "$h9_reconcile_pid" 2>/dev/null || :
done
pass H9 "contended SessionStart ${h9_elapsed}s (<12s), ready preceded the 10s drain timeout"
stop_pid "$H9_CONDUIT_PID"

# H8 — journal recovery suppresses an immediate duplicate; failed writes retry.
H8_HOME=$RIG/h8-home
init_home "$H8_HOME"
start_listener h8 h8-session
H8_PID=$LISTENER_PID; H8_SOCKET=$LISTENER_SOCKET; H8_FRAMES=$LISTENER_OUTPUT
register_session "$H8_HOME" restart h8-session "$H8_PID" "$H8_SOCKET" interactive ready \
    >/dev/null || fail H8 "registration failed"
stage_letter "$H8_HOME" restart 8
start_conduit "$H8_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s
H8_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H8_FRAMES" 1 40 || fail H8 "first written frame missing"
stop_pid "$H8_CONDUIT_PID"
start_conduit "$H8_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s
H8_CONDUIT_PID=$CONDUIT_PID
sleep 0.3
[ "$(line_count "$H8_FRAMES")" -eq 1 ] || fail H8 "restart duplicated written unchanged generation"
pass H8 "restart restores written/failed journal state without an immediate duplicate"
stop_pid "$H8_CONDUIT_PID"
stop_pid "$H8_PID"

# H10 — watch retreats only for its own verified, socket-backed registration.
H10_HOME=$RIG/h10-home
init_home "$H10_HOME"
start_listener h10 h10-session
H10_PID=$LISTENER_PID; H10_SOCKET=$LISTENER_SOCKET
H10_REG=$(register_session "$H10_HOME" watcher h10-session "$H10_PID" "$H10_SOCKET" \
    interactive ready) || fail H10 "watch registration failed"
H10_INSTANCE=$(printf '%s\n' "$H10_REG" | sed -n 's/^instance //p')
start_conduit "$H10_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s
H10_CONDUIT_PID=$CONDUIT_PID
wait_i=0
while ! grep -R -q '"conduitVerified":true' "$RUNTIME_BASE/sessions" 2>/dev/null && \
    [ "$wait_i" -lt 40 ]; do
    sleep 0.05
    wait_i=$((wait_i + 1))
done
KHALA_HOME=$H10_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE KHALA_TEST_BOOT_ID=conduit-test-boot \
    KHALA_SESSION=watcher KHALA_SESSION_INSTANCE=$H10_INSTANCE \
    "$KHALA" watch --session watcher --interval 1 --max-wait 1 >"$RIG/h10.out" 2>"$RIG/h10.err" || \
    fail H10 "verified watch did not retreat 0"
grep -Fqx 'conduit has the ear' "$RIG/h10.out" || fail H10 "retreat line differs"
printf 'self alpha\nmailbox alpha\npeer alpha %s\nttl 120\n' "$H10_HOME" > "$H10_HOME/config"
KHALA_HOME=$H10_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE KHALA_TEST_BOOT_ID=conduit-test-boot \
    KHALA_SESSION=legacy "$KHALA" watch --session legacy --interval 1 --max-wait 3 \
    >"$RIG/h10-legacy.out" 2>"$RIG/h10-legacy.err" &
H10_WATCH_PID=$!
PIDS="$PIDS $H10_WATCH_PID"
sleep 0.2
kill -0 "$H10_WATCH_PID" 2>/dev/null || fail H10 "unverified watch retreated early"
stage_letter "$H10_HOME" legacy 10
wait "$H10_WATCH_PID" || fail H10 "legacy watch did not wake on a letter"
grep -q '^1$' "$RIG/h10-legacy.out" || fail H10 "legacy watch output missing letter count"
pass H10 "watch retreats only when verified and otherwise retains legacy wake behavior"
stop_pid "$H10_CONDUIT_PID"
stop_pid "$H10_PID"

# H11 — all runtime writers reject a symlink root.
H11_HOME=$RIG/h11-home
init_home "$H11_HOME"
H11_RUNTIME=$RIG/h11-runtime
mkdir -p "$RIG/h11-target"
ln -s "$RIG/h11-target" "$H11_RUNTIME"
if env KHALA_RUNTIME_DIR=$H11_RUNTIME KHALA_TEST_BOOT_ID=conduit-test-boot KHALA_HOME=$H11_HOME \
    "$BIN" conduit >"$RIG/h11.out" 2>"$RIG/h11.err"; then
    fail H11 "conduit accepted a symlink runtime"
fi
grep -qi 'symlink' "$RIG/h11.err" || fail H11 "symlink refusal was unclear"
H11_PROJECT=$RIG/h11-project
mkdir -p "$H11_PROJECT"
printf '%s\n' symlinked > "$H11_PROJECT/.khala-session"
HOME=$RIG KHALA_HOME=$H11_HOME KHALA_RUNTIME_DIR=$H11_RUNTIME \
    KHALA_TEST_BOOT_ID=conduit-test-boot KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    KHALA_CLAUDE_SESSION_ID=h11-session CLAUDE_PROJECT_DIR=$H11_PROJECT \
    PATH=$H11_HOME/bin:$ROOT/bin:/usr/bin:/bin "$ROOT/plugin/hooks/session-start.sh" \
    <<<'{"session_id":"h11-session"}' >"$RIG/h11-hook.out" 2>"$RIG/h11-hook.err" || \
    fail H11 "symlink hook exited nonzero"
grep -qi 'symlink' "$RIG/h11-hook.out" || fail H11 "hook symlink refusal was unclear"
[ -z "$(find "$RIG/h11-target" -mindepth 1 -print -quit)" ] || fail H11 "symlink target was written"
pass H11 "conduit and SessionStart refuse a symlink runtime root"

# H12 — only the dial process may launch periodic reconcile; serve is per-peer singleton.
H12_A=$RIG/h12-a
H12_B=$RIG/h12-b
init_home "$H12_A"
init_home "$H12_B"
printf 'self alpha\nmailbox beta\npeer beta direct-test-carrier\nttl 120\n' > "$H12_A/config"
printf 'self beta\nmailbox beta\npeer beta direct-test-carrier\nttl 120\n' > "$H12_B/config"
KHALA_HOME=$H12_A KHALA_BRAIN=$KHALA KHALA_LINK_TEST_SERVE_HOME=$H12_B \
    KHALA_LINK_TEST_SERVE_NODE=beta KHALA_LINK_TEST_SCAN_INTERVAL=100ms \
    "$BIN" >"$RIG/h12-dial.out" 2>"$RIG/h12-dial.err" &
H12_DIAL_PID=$!
PIDS="$PIDS $H12_DIAL_PID"
wait_file "$H12_B/run/serve.alpha.lock" 100 || fail H12 "first serve did not acquire peer guard"
if ! KHALA_HOME=$H12_B KHALA_BRAIN=$KHALA "$BIN" --serve --peer alpha \
    </dev/null >"$RIG/h12-second.out" 2>"$RIG/h12-second.err"; then
    fail H12 "second serve did not exit 0"
fi
H12_SECONDS=${H12_SECONDS:-60}
h12_end=$(( $(date +%s) + H12_SECONDS ))
while [ "$(date +%s)" -lt "$h12_end" ]; do
    if [ -f "$H12_A/run/brain.lock.d/owner" ]; then
        h12_owner=$(sed -n '2s/^pid \([0-9][0-9]*\) .*/\1/p' \
            "$H12_A/run/brain.lock.d/owner" 2>/dev/null) || h12_owner=
        if [ -n "$h12_owner" ]; then
            h12_parent=$(ps -o ppid= -p "$h12_owner" 2>/dev/null | tr -d ' ')
            [ -z "$h12_parent" ] || [ "$h12_parent" = "$H12_DIAL_PID" ] || \
                fail H12 "non-dial process $h12_parent owned periodic brain reconcile"
        fi
    fi
    [ ! -d "$H12_B/run/brain.lock.d" ] || \
        fail H12 "serve-side brain.lock.d appeared"
    sleep 0.05
done
pass H12 "dial alone reconciles and duplicate per-peer serve exits 0"

# H17 — XDG_RUNTIME_DIR belongs to the caller, not the node singleton. An
# explicit KHALA_RUNTIME_DIR must select one plane across differing XDG values.
H17_RIG=$RIG/h17
H17_HOME=$H17_RIG/home
H17_RUNTIME=$H17_RIG/rt
H17_XDG_A=$H17_RIG/xdg-a
H17_XDG_B=$H17_RIG/xdg-b
mkdir -p "$H17_RUNTIME" "$H17_XDG_A" "$H17_XDG_B"
init_home "$H17_HOME"
env KHALA_HOME=$H17_HOME KHALA_RUNTIME_DIR=$H17_RUNTIME XDG_RUNTIME_DIR=$H17_XDG_A \
    KHALA_TEST_BOOT_ID=h17-test-boot KHALA_CONDUIT_TEST_SCAN_INTERVAL=50ms \
    "$BIN" conduit >"$H17_RIG/a.out" 2>"$H17_RIG/a.err" &
H17_CONDUIT_PID=$!
PIDS="$PIDS $H17_CONDUIT_PID"
wait_file "$H17_RUNTIME/conduit.status.json" 100 || fail H17 "conduit A wrote no status"
h17_wait=0
while ! grep -q 'started pid=' "$H17_HOME/log/conduit.log" 2>/dev/null && \
    [ "$h17_wait" -lt 100 ]; do
    sleep 0.05
    h17_wait=$((h17_wait + 1))
done
[ "$h17_wait" -lt 100 ] || fail H17 "conduit A did not log its start"
env KHALA_HOME=$H17_HOME KHALA_RUNTIME_DIR=$H17_RUNTIME XDG_RUNTIME_DIR=$H17_XDG_B \
    KHALA_TEST_BOOT_ID=h17-test-boot "$BIN" runtime daemon-status >/dev/null 2>"$H17_RIG/daemon-b.err" || \
    fail H17 "runtime daemon-status from XDG environment B did not see conduit A"
find "$RIG" -name conduit.status.json -type f -print | sort > "$H17_RIG/status.before"
h17_started_before=$(grep -c 'started pid=' "$H17_HOME/log/conduit.log" 2>/dev/null || :)
env KHALA_HOME=$H17_HOME KHALA_RUNTIME_DIR=$H17_RUNTIME XDG_RUNTIME_DIR=$H17_XDG_B \
    KHALA_TEST_BOOT_ID=h17-test-boot "$BIN" conduit \
    >"$H17_RIG/b.out" 2>"$H17_RIG/b.err" &
H17_SECOND_PID=$!
PIDS="$PIDS $H17_SECOND_PID"
h17_wait=0
while kill -0 "$H17_SECOND_PID" 2>/dev/null && [ "$h17_wait" -lt 40 ]; do
    sleep 0.05
    h17_wait=$((h17_wait + 1))
done
if kill -0 "$H17_SECOND_PID" 2>/dev/null; then
    stop_pid "$H17_SECOND_PID"
    fail H17 "second conduit from XDG environment B did not exit immediately"
fi
wait "$H17_SECOND_PID"
h17_second_status=$?
[ "$h17_second_status" -eq 0 ] || fail H17 "second conduit exited $h17_second_status"
find "$RIG" -name conduit.status.json -type f -print | sort > "$H17_RIG/status.after"
cmp -s "$H17_RIG/status.before" "$H17_RIG/status.after" || fail H17 "second conduit wrote another status file"
h17_started_after=$(grep -c 'started pid=' "$H17_HOME/log/conduit.log" 2>/dev/null || :)
[ "$h17_started_after" -eq "$h17_started_before" ] || fail H17 "second conduit logged started pid="
env KHALA_HOME=$H17_HOME KHALA_RUNTIME_DIR=$H17_RUNTIME XDG_RUNTIME_DIR=$H17_XDG_A \
    KHALA_TEST_BOOT_ID=h17-test-boot "$BIN" runtime status > "$H17_RIG/status-a.out" || \
    fail H17 "runtime status failed in environment A"
env KHALA_HOME=$H17_HOME KHALA_RUNTIME_DIR=$H17_RUNTIME XDG_RUNTIME_DIR=$H17_XDG_B \
    KHALA_TEST_BOOT_ID=h17-test-boot "$BIN" runtime status > "$H17_RIG/status-b.out" || \
    fail H17 "runtime status failed in environment B"
h17_runtime_a=$(sed -n '1p' "$H17_RIG/status-a.out")
h17_runtime_b=$(sed -n '1p' "$H17_RIG/status-b.out")
[ "$h17_runtime_a" = "runtime: $H17_RUNTIME" ] || fail H17 "environment A printed $h17_runtime_a"
[ "$h17_runtime_a" = "$h17_runtime_b" ] || fail H17 "runtime lines differ across XDG environments"
grep -Fq "\"runtime\":\"$H17_RUNTIME\"" "$H17_RUNTIME/conduit.status.json" || \
    fail H17 "conduit status omitted the chosen runtime root"
stop_pid "$H17_CONDUIT_PID"
pass H17 "one explicit runtime plane survives differing XDG environments and rejects a second conduit"

# H18 — even after obtaining a replacement lock inode, a live status record
# prevents a second conduit from overwriting the singleton's state.
H18_RIG=$RIG/h18
H18_HOME=$H18_RIG/home
H18_RUNTIME=$H18_RIG/rt
mkdir -p "$H18_RUNTIME"
init_home "$H18_HOME"
H18_SHELL_START=$(env KHALA_TEST_BOOT_ID=h18-test-boot "$BIN" runtime process-start --pid $$) || \
    fail H18 "could not read the test shell process start"
printf '{"bootId":"h18-test-boot","pid":%s,"pidStart":"%s","runtime":"%s"}\n' \
    "$$" "$H18_SHELL_START" "$H18_RUNTIME" > "$H18_RUNTIME/conduit.status.json"
cp "$H18_RUNTIME/conduit.status.json" "$H18_RIG/status.before"
env KHALA_HOME=$H18_HOME KHALA_RUNTIME_DIR=$H18_RUNTIME KHALA_TEST_BOOT_ID=h18-test-boot \
    "$BIN" conduit >"$H18_RIG/live.out" 2>"$H18_RIG/live.err" || \
    fail H18 "live-status guard did not exit 0"
grep -Fq "another conduit is live (pid=$$); exiting" "$H18_HOME/log/conduit.log" || \
    fail H18 "live-status guard log is missing"
grep -q 'started pid=' "$H18_HOME/log/conduit.log" && fail H18 "guarded conduit logged a start"
cmp -s "$H18_RIG/status.before" "$H18_RUNTIME/conduit.status.json" || \
    fail H18 "guarded conduit overwrote the live status"
sleep 30 &
H18_DEAD_PID=$!
PIDS="$PIDS $H18_DEAD_PID"
H18_DEAD_START=$(env KHALA_TEST_BOOT_ID=h18-test-boot "$BIN" runtime process-start --pid "$H18_DEAD_PID") || \
    fail H18 "could not read the fixture process start"
stop_pid "$H18_DEAD_PID"
printf '{"bootId":"h18-test-boot","pid":%s,"pidStart":"%s","runtime":"%s"}\n' \
    "$H18_DEAD_PID" "$H18_DEAD_START" "$H18_RUNTIME" > "$H18_RUNTIME/conduit.status.json"
env KHALA_HOME=$H18_HOME KHALA_RUNTIME_DIR=$H18_RUNTIME KHALA_TEST_BOOT_ID=h18-test-boot \
    KHALA_CONDUIT_TEST_SCAN_INTERVAL=50ms "$BIN" conduit \
    >"$H18_RIG/dead.out" 2>"$H18_RIG/dead.err" &
H18_CONDUIT_PID=$!
PIDS="$PIDS $H18_CONDUIT_PID"
h18_wait=0
while ! grep -q "\"pid\":$H18_CONDUIT_PID" "$H18_RUNTIME/conduit.status.json" 2>/dev/null && \
    [ "$h18_wait" -lt 100 ]; do
    sleep 0.05
    h18_wait=$((h18_wait + 1))
done
[ "$h18_wait" -lt 100 ] || fail H18 "dead status did not allow a fresh conduit to start"
kill -0 "$H18_CONDUIT_PID" 2>/dev/null || fail H18 "fresh conduit is not live"
grep -Fq "started pid=$H18_CONDUIT_PID runtime=$H18_RUNTIME" "$H18_HOME/log/conduit.log" || \
    fail H18 "fresh conduit did not log its start"
stop_pid "$H18_CONDUIT_PID"
pass H18 "a live status survives a replaced lock inode; a dead status permits startup"

bash -n "$ROOT/bin/khala" "$ROOT/plugin/hooks/lib.sh" \
    "$ROOT/plugin/hooks/session-start.sh" "$ROOT/plugin/hooks/stop.sh" \
    "$ROOT/plugin/hooks/session-end.sh" || fail syntax "bash -n failed"

printf 'RESULT: PASS\n'
printf 'Conduit H1-H20 delivery, channel routing, lease, hook, restart, watch, runtime, and link properties passed\n'
