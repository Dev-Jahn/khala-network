#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO:-$(command -v go)}
RIG=${KHALA_TEST_ROOT:-${HOME}/.khala-conduit-test-$$}
BIN=$RIG/khala-link
RUNTIME_BASE=$RIG/runtime
LISTENER=$ROOT/test/conduit-listener.py
CHANNEL_LISTENER=$ROOT/test/channel-listener.py
PIDS=
. "$ROOT/test/lib/isolate.sh"

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
    listener_mode=${3-}
    listener_socket=$RIG/$listener_name.sock
    listener_output=$RIG/$listener_name.frames
    listener_ready=$RIG/$listener_name.ready
    "$RIG/venv/bin/python" "$LISTENER" ${listener_mode:+"$listener_mode"} "$listener_socket" \
        "$listener_output" "$listener_ready" >"$RIG/$listener_name.listener.out" \
        2>"$RIG/$listener_name.listener.err" &
    LISTENER_PID=$!
    PIDS="$PIDS $LISTENER_PID"
    wait_file "$listener_ready" 100 || fail setup "$listener_name listener did not bind"
    mkdir -p "$RIG/cc-sessions"
    listener_started=$("$RIG/venv/bin/python" -c 'import time; print(time.time_ns() // 1000000)')
    printf '{"pid":%s,"sessionId":"%s","name":"%s","version":"2.1.233","messagingSocketPath":"%s","startedAt":%s}\n' \
        "$LISTENER_PID" "$listener_session" "$listener_session" "$listener_socket" "$listener_started" \
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
trap 'cleanup; isolate_cleanup' EXIT HUP INT TERM
(uv venv --python 3.13 "$RIG/venv" >/dev/null) || fail setup "test Python venv failed"
(cd "$ROOT/link" && CGO_ENABLED=0 "$GO" build -o "$BIN" .) || fail setup "Go build failed"

# H20 — a Codex registration (harness codex, the khala-network-codex bridge) is
# rung only through its verified channel socket, never through a Claude socket,
# even one inherited in its environment. A dead channel is journaled as a failed
# attempt with no fallback.
H20_HOME=$RIG/h20-home
init_home "$H20_HOME"
start_listener h20-cc h20-claude-session
H20_CC_PID=$LISTENER_PID
H20_CC_SOCKET=$LISTENER_SOCKET
H20_CC_FRAMES=$LISTENER_OUTPUT
register_session "$H20_HOME" claudeside h20-claude-session "$H20_CC_PID" \
    "$H20_CC_SOCKET" interactive ready >/dev/null || fail H20 "Claude registration failed"
sleep 300 &
H20_CODEX_PID=$!
PIDS="$PIDS $H20_CODEX_PID"
H20_INSTANCE=0123456789abcdef01234567
start_channel_listener h20 "$H20_INSTANCE"
H20_CHANNEL_PID=$CHANNEL_LISTENER_PID
H20_CHANNEL_SOCKET=$CHANNEL_SOCKET
H20_CHANNEL_FRAMES=$CHANNEL_OUTPUT
runtime_env KHALA_HOME="$H20_HOME" CLAUDE_CODE_MESSAGING_SOCKET="$H20_CC_SOCKET" \
    "$BIN" runtime register --identity channelled --instance "$H20_INSTANCE" \
    --session-id h20-thread --harness codex --kind interactive --phase ready \
    --pid "$H20_CODEX_PID" --caller-pid "$H20_CHANNEL_PID" --cc-version 0.153.4 \
    >"$RIG/h20-register.out" || fail H20 "Codex registration failed"
grep -qx 'owner yes' "$RIG/h20-register.out" || fail H20 "Codex registration does not own its lease"
runtime_env "$BIN" runtime register-channel --instance "$H20_INSTANCE" \
    --session-id h20-thread --channel-socket "$H20_CHANNEL_SOCKET" \
    --caller-pid "$H20_CHANNEL_PID" --verified >/dev/null || fail H20 "channel registration failed"
stage_letter "$H20_HOME" channelled 20 reel@bw2 "Priority: later"
start_conduit "$H20_HOME" env KHALA_CONDUIT_TEST_BACKOFF=500ms
H20_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H20_CHANNEL_FRAMES" 1 40 || fail H20 "live channel did not receive inbox notification"
sleep 0.15
[ "$(line_count "$H20_CC_FRAMES")" -eq 0 ] || fail H20 "a Claude socket received the Codex inbox notification"
uv run --no-project python - "$H20_CHANNEL_FRAMES" <<'PY' || fail H20 "channel request JSON/shape invalid"
import json, sys
request = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert request["v"] == 1
assert request["content"] == "reel@bw2 · conduit-20\n1 letters, 0 notices — run khala_drain"  # C3 (0.8.0)
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
assert request["meta"]["notices"] == "0" and request["meta"]["urgent"] == "0" and request["meta"]["retry"] == "0"  # C3 (0.8.0)
PY
grep -R -q '"via":"channel"' "$RUNTIME_BASE/deliveries/channelled/$H20_INSTANCE" || \
    fail H20 "channel delivery journal omitted via=channel"
runtime_env KHALA_HOME="$H20_HOME" "$BIN" runtime status > "$RIG/h20-status.out" || \
    fail H20 "runtime status failed"
grep -q $'SOCKET\tCHANNEL\tCC_VERSION\tADAPTER' "$RIG/h20-status.out" || fail H20 "status omitted CHANNEL column"
grep -q $'^channelled\t.*\t-\tyes\tcodex:0.153.4\tcodex-channel-v1\t' "$RIG/h20-status.out" || \
    fail H20 "status did not show the Codex channel"
grep -q $'^claudeside\t.*\tyes\t-\t2.1.233\tsocket-v1\t' "$RIG/h20-status.out" || \
    fail H20 "status did not show the Claude socket alone"
H20_EAR=$H20_HOME/presence/conduit@alpha.ear
h20_wait=0
while ! grep -q '^identity name=channelled principal=session listening=yes route=channel phase=ready cc=codex:0.153.4 ' \
    "$H20_EAR" 2>/dev/null && [ "$h20_wait" -lt 100 ]; do
    sleep 0.05
    h20_wait=$((h20_wait + 1))
done
[ "$h20_wait" -lt 100 ] || fail H20 "listener snapshot did not show route=channel cc=codex:"
grep -q '^identity name=claudeside principal=session listening=yes route=socket ' "$H20_EAR" || \
    fail H20 "listener snapshot did not show the Claude socket route"

mkdir -p "$H20_HOME/run/drained"
mkdir -p "$H20_HOME/inbox/channelled/cur"
mv "$H20_HOME/inbox/channelled/new/1700000000.1.20.sender@alpha" "$H20_HOME/inbox/channelled/cur/"
printf 'drain 1 %s - - 0 0 0 ok\n' "$(date +%s)" > "$H20_HOME/run/drained/channelled"
stop_pid "$H20_CHANNEL_PID"
stage_letter "$H20_HOME" channelled 21 clawd@mini
h20_wait=0
while ! grep -R -q '"status":"failed"' "$RUNTIME_BASE/deliveries/channelled/$H20_INSTANCE" 2>/dev/null && \
    [ "$h20_wait" -lt 100 ]; do
    sleep 0.05
    h20_wait=$((h20_wait + 1))
done
[ "$h20_wait" -lt 100 ] || fail H20 "dead channel attempt was not journaled as failed"
sleep 0.3
[ "$(line_count "$H20_CC_FRAMES")" -eq 0 ] || fail H20 "dead channel fell back to a Claude socket"
[ "$(line_count "$H20_CHANNEL_FRAMES")" -eq 1 ] || fail H20 "dead channel recorded another request"
grep -R -q '"via":"socket"' "$RUNTIME_BASE/deliveries/channelled/$H20_INSTANCE" && \
    fail H20 "a Codex attempt was journaled via socket"
grep -q "registration $H20_INSTANCE not verified: Codex channel socket is invalid" "$H20_HOME/log/conduit.log" || \
    fail H20 "dead channel was not logged"
pass H20 "Codex rings only its channel; a dead channel fails without fallback"
stop_pid "$H20_CONDUIT_PID"
stop_pid "$H20_CODEX_PID"
stop_pid "$H20_CC_PID"

# H1 — durable new/ remains authoritative.
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
[ -f "$H1_HOME/inbox/eddy/new/1700000000.1.1.sender@alpha" ] || fail H1 "notifier consumed new/"
uv run --no-project python - "$H1_FRAMES" <<'PY' || fail H1 "frame JSON/shape invalid"
import json, sys
frame = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert frame["type"] == "user"
assert frame["message"]["role"] == "user"
assert frame["message"]["content"].startswith("KHALA-CONDUIT/1")
assert frame["priority"] == "next", frame["priority"]
assert ":" in frame["msg_id"]
PY
pass H1 "one valid inbox notification arrived (priority next) and the message remained in new/"
stop_pid "$H1_CONDUIT_PID"
stop_pid "$H1_LISTENER_PID"

# H19 — inbox notification priority: next by default; later only when every pending
# message carries "Priority: later" (khala send --later); one ordinary message in
# the batch keeps next.
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
wait_lines "$H19_FRAMES" 1 40 || fail H19 "later-only generation did not send an inbox notification"
uv run --no-project python - "$H19_FRAMES" 1 later <<'PY' || fail H19 "later-only batch was not rung as later"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
frame = json.loads(lines[int(sys.argv[2]) - 1])
assert frame["priority"] == sys.argv[3], frame["priority"]
PY
mkdir -p "$H19_HOME/run/drained"
mkdir -p "$H19_HOME/inbox/quiet/cur"
mv "$H19_HOME/inbox/quiet/new/1700000000.1.1.sender@alpha" "$H19_HOME/inbox/quiet/cur/"
printf 'drain 1 %s - - 0 0 0 ok\n' "$(date +%s)" > "$H19_HOME/run/drained/quiet"
stage_letter "$H19_HOME" quiet 2 clawd@mini
wait_lines "$H19_FRAMES" 2 40 || fail H19 "mixed generation did not send an inbox notification"
uv run --no-project python - "$H19_FRAMES" 2 next <<'PY' || fail H19 "one ordinary message did not lift the batch to next"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
frame = json.loads(lines[int(sys.argv[2]) - 1])
assert frame["priority"] == sys.argv[3], frame["priority"]
PY
stop_pid "$H19_CONDUIT_PID"
stop_pid "$H19_LISTENER_PID"
pass H19 "inbox notification is next by default and later only when every message asks"

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
# the notifier heals the lease and notifies instead of failing forever with
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
wait_lines "$H14_FRAMES" 1 60 || fail H14 "notifier never sent an inbox notification after the registry landed (lease pid stayed 0)"
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
start_conduit "$H4_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s KHALA_CONDUIT_TEST_REWRITE_AFTER=30s
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
[ -f "$H4_HOME/inbox/shared/new/1700000000.1.5.sender@alpha" ] || fail H4 "non-owner hook read mail"
pass H4 "only the lease owner is notified; a second SessionStart warns and reads nothing"

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
kill -0 "$OWNER_PID" 2>/dev/null || fail H6 "old owner died after notifier reroute"
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

# H25 — the session socket's auth token (D18 r3 B). The bind SessionStart makes
# (explicit --socket = its own CLAUDE_CODE_MESSAGING_SOCKET) keeps the token from
# the environment in the 0600 registration; the conduit writes the auth line
# before the frame, and a session without a token gets the frame alone. The
# token appears nowhere else: not in runtime status, .ear, journals or the log.
H25_HOME=$RIG/h25-home
init_home "$H25_HOME"
H25_TOKEN=h25tokensentinel0123456789abcdef
start_listener h25 h25-session --all-lines
H25_PID=$LISTENER_PID; H25_SOCKET=$LISTENER_SOCKET; H25_FRAMES=$LISTENER_OUTPUT
H25_REG=$(runtime_env KHALA_HOME="$H25_HOME" KHALA_SESSION=sealed \
    CLAUDE_CODE_MESSAGING_SOCKET="$H25_SOCKET" CLAUDE_CODE_MESSAGING_TOKEN="$H25_TOKEN" \
    "$KHALA" bind --register ready --session-id h25-session --pid 0 --socket "$H25_SOCKET" \
    --kind interactive --cc-version 2.1.312) || fail H25 "registration failed"
H25_INSTANCE=$(printf '%s\n' "$H25_REG" | sed -n 's/^instance //p')
start_listener h25-plain h25-plain-session --all-lines
H25_PLAIN_PID=$LISTENER_PID; H25_PLAIN_FRAMES=$LISTENER_OUTPUT
register_session "$H25_HOME" plain h25-plain-session 0 "$LISTENER_SOCKET" interactive ready >/dev/null || \
    fail H25 "plain registration failed"
stage_letter "$H25_HOME" sealed 25
stage_letter "$H25_HOME" plain 26
start_conduit "$H25_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s KHALA_CONDUIT_TEST_REWRITE_AFTER=30s \
    KHALA_CONDUIT_TEST_EAR_INTERVAL=30s
H25_CONDUIT_PID=$CONDUIT_PID
wait_lines "$H25_FRAMES" 2 60 || fail H25 "the session with a token was not rung"
wait_lines "$H25_PLAIN_FRAMES" 1 60 || fail H25 "the session without a token was not rung"
wait_file "$H25_HOME/presence/conduit@alpha.ear" 100 || fail H25 "snapshot was not written"
uv run --no-project python - "$H25_FRAMES" "$H25_PLAIN_FRAMES" "$H25_TOKEN" \
    "$RUNTIME_BASE/sessions/$H25_INSTANCE.json" <<'PY' || fail H25 "frames or registration wrong"
import json, os, sys
sealed = open(sys.argv[1], encoding="utf-8").read().splitlines()
plain = open(sys.argv[2], encoding="utf-8").read().splitlines()
assert len(sealed) == 2 and sealed[0] == '{"type":"auth","token":"%s"}' % sys.argv[3], sealed
assert json.loads(sealed[1])["message"]["content"].startswith("KHALA-CONDUIT/1"), sealed
assert len(plain) == 1 and json.loads(plain[0])["message"]["content"].startswith("KHALA-CONDUIT/1"), plain
assert os.stat(sys.argv[4]).st_mode & 0o777 == 0o600
assert json.load(open(sys.argv[4]))["messagingToken"] == sys.argv[3]
PY
runtime_env KHALA_HOME="$H25_HOME" "$BIN" runtime status > "$RIG/h25-status.out" || fail H25 "runtime status failed"
grep -q '^sealed' "$RIG/h25-status.out" || fail H25 "runtime status lacks the identity"
! grep -qF "$H25_TOKEN" "$RIG/h25-status.out" || fail H25 "runtime status leaked the token"
h25_leaks=$(grep -rlF "$H25_TOKEN" "$RUNTIME_BASE" "$H25_HOME")
[ "$h25_leaks" = "$RUNTIME_BASE/sessions/$H25_INSTANCE.json" ] || fail H25 "token outside the registration: $h25_leaks"
pass H25 "SessionStart's socket token rides the auth line before the frame and lives only in the 0600 registration"
stop_pid "$H25_CONDUIT_PID"
stop_pid "$H25_PID"
stop_pid "$H25_PLAIN_PID"
runtime_env KHALA_HOME="$H25_HOME" "$BIN" runtime release --session-id h25-session >/dev/null &&
    runtime_env KHALA_HOME="$H25_HOME" "$BIN" runtime release --session-id h25-plain-session >/dev/null ||
    fail H25 "releasing the dead registrations failed"

# H9 — a hook-level gate: the ready registration survives an inbox-read lock deadline.
H9_HOME=$RIG/h9-home
init_home "$H9_HOME"
H9_PROJECT=$RIG/h9-project
mkdir -p "$H9_PROJECT"
printf '%s\n' timed > "$H9_PROJECT/.khala-session"
stage_letter "$H9_HOME" timed 7
mkdir -p "$H9_HOME/run/brain.lock.d"
printf '%s\npid %s contention\n' "$(date +%s)" "$$" > "$H9_HOME/run/brain.lock.d/owner"
h9_reconcile_pids=
# Each contention loop leads its own process group, so it is killed whole:
# setsid(1) is util-linux; on macOS the system perl makes the same setsid(2).
if command -v setsid >/dev/null 2>&1; then
    h9_own_session=(setsid)
else
    h9_own_session=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n";
        exec { $ARGV[0] } @ARGV or die "exec: $!\n"' --)
fi
h9_loop=1
while [ "$h9_loop" -le 3 ]; do
    "${h9_own_session[@]}" sh -c 'while :; do KHALA_HOME=$1 "$2" reconcile >/dev/null 2>&1 || :; done' \
        sh "$H9_HOME" "$KHALA" &
    h9_reconcile_pid=$!
    h9_reconcile_pids="$h9_reconcile_pids $h9_reconcile_pid"
    h9_loop=$((h9_loop + 1))
done
start_conduit "$H9_HOME" env KHALA_CONDUIT_TEST_BACKOFF=2s
H9_CONDUIT_PID=$CONDUIT_PID
h9_wait=0
while ! runtime_env KHALA_HOME="$H9_HOME" "$BIN" runtime daemon-status >/dev/null 2>&1 && \
    [ "$h9_wait" -lt 40 ]; do
    sleep 0.05
    h9_wait=$((h9_wait + 1))
done
[ "$h9_wait" -lt 40 ] || fail H9 "fixture notifier did not become live"
h9_started=$(uv run --no-project python - <<'PY'
import time
print(time.monotonic())
PY
)
HOME=$RIG KHALA_HOME=$H9_HOME KHALA_RUNTIME_DIR=$RUNTIME_BASE \
    KHALA_TEST_BOOT_ID=conduit-test-boot KHALA_SESSION_INSTANCE=h9-instance \
    KHALA_CLAUDE_SESSION_ID=h9-session KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    CLAUDE_PROJECT_DIR=$H9_PROJECT PATH=$H9_HOME/bin:$ROOT/bin:/usr/bin:/bin \
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
grep -q '"phase":"ready"' "$RUNTIME_BASE/sessions/h9-instance.json" || fail H9 "registration never reached ready"
[ -f "$H9_HOME/inbox/timed/new/1700000000.1.7.sender@alpha" ] || fail H9 "timed-out inbox read consumed/misplaced mail"
rm -rf -- "$H9_HOME/run/brain.lock.d"
for h9_reconcile_pid in $h9_reconcile_pids; do
    kill -- "-$h9_reconcile_pid" 2>/dev/null || :
    wait "$h9_reconcile_pid" 2>/dev/null || :
done
pass H9 "contended SessionStart ${h9_elapsed}s (<12s), ready preceded the 10s inbox read timeout"
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

# H10 — watch retreats only for a verified path that can actually hear.
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
while ! grep -q '"conduitVerified":true' "$RUNTIME_BASE/sessions/$H10_INSTANCE.json" 2>/dev/null && \
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
wait "$H10_WATCH_PID" || fail H10 "legacy watch did not wake on a message"
grep -q '^1$' "$RIG/h10-legacy.out" || fail H10 "legacy watch output missing message count"
pass H10 "watch yields for a verified socket path and watches directly without one"
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
    fail H11 "notifier accepted a symlink runtime"
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
pass H11 "notifier and SessionStart refuse a symlink runtime root"

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
                fail H12 "non-dial process $h12_parent owned periodic core CLI reconcile"
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
wait_file "$H17_RUNTIME/conduit.status.json" 100 || fail H17 "notifier A wrote no status"
h17_wait=0
while ! grep -q 'started pid=' "$H17_HOME/log/conduit.log" 2>/dev/null && \
    [ "$h17_wait" -lt 100 ]; do
    sleep 0.05
    h17_wait=$((h17_wait + 1))
done
[ "$h17_wait" -lt 100 ] || fail H17 "notifier A did not log its start"
env KHALA_HOME=$H17_HOME KHALA_RUNTIME_DIR=$H17_RUNTIME XDG_RUNTIME_DIR=$H17_XDG_B \
    KHALA_TEST_BOOT_ID=h17-test-boot "$BIN" runtime daemon-status >/dev/null 2>"$H17_RIG/daemon-b.err" || \
    fail H17 "runtime daemon-status from XDG environment B did not see notifier A"
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
    fail H17 "second notifier from XDG environment B did not exit immediately"
fi
wait "$H17_SECOND_PID"
h17_second_status=$?
[ "$h17_second_status" -eq 0 ] || fail H17 "second notifier exited $h17_second_status"
find "$RIG" -name conduit.status.json -type f -print | sort > "$H17_RIG/status.after"
cmp -s "$H17_RIG/status.before" "$H17_RIG/status.after" || fail H17 "second notifier wrote another status file"
h17_started_after=$(grep -c 'started pid=' "$H17_HOME/log/conduit.log" 2>/dev/null || :)
[ "$h17_started_after" -eq "$h17_started_before" ] || fail H17 "second notifier logged started pid="
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
    fail H17 "notifier status omitted the chosen runtime root"
stop_pid "$H17_CONDUIT_PID"
pass H17 "one explicit runtime plane survives differing XDG environments and rejects a second notifier"

# H18 — even after obtaining a replacement lock inode, a live status record
# prevents a second notifier from overwriting the singleton's state.
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
grep -q 'started pid=' "$H18_HOME/log/conduit.log" && fail H18 "guarded notifier logged a start"
cmp -s "$H18_RIG/status.before" "$H18_RUNTIME/conduit.status.json" || \
    fail H18 "guarded notifier overwrote the live status"
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
[ "$h18_wait" -lt 100 ] || fail H18 "dead status did not allow a fresh notifier to start"
kill -0 "$H18_CONDUIT_PID" 2>/dev/null || fail H18 "fresh notifier is not live"
grep -Fq "started pid=$H18_CONDUIT_PID runtime=$H18_RUNTIME" "$H18_HOME/log/conduit.log" || \
    fail H18 "fresh notifier did not log its start"
stop_pid "$H18_CONDUIT_PID"
pass H18 "a live status survives a replaced lock inode; a dead status permits startup"

# H21 — one real listener snapshot is bounded, leak-free, transition-driven,
# and replaced by an empty snapshot on clean shutdown.
H21_HOME=$RIG/h21-home
init_home "$H21_HOME"
printf 'peer mini h21-peer-sentinel.invalid\n' >> "$H21_HOME/config"
start_listener h21-socket-sentinel h21-session
H21_LISTENER_PID=$LISTENER_PID
H21_SOCKET=$LISTENER_SOCKET
H21_REG=$(register_session "$H21_HOME" earsafe h21-session "$H21_LISTENER_PID" \
    "$H21_SOCKET" interactive ready) || fail H21 "ready registration failed"
H21_INSTANCE=$(printf '%s\n' "$H21_REG" | sed -n 's/^instance //p')
stage_letter "$H21_HOME" earsafe 21 sentinel-sender@alpha "h21-subject-sentinel"
printf '\nh21-body-sentinel\n' >> "$H21_HOME/inbox/earsafe/new/1700000000.1.21.sender@alpha"
start_conduit "$H21_HOME" env KHALA_CONDUIT_TEST_EAR_INTERVAL=30s \
    KHALA_CONDUIT_TEST_BACKOFF=500ms
H21_CONDUIT_PID=$CONDUIT_PID
H21_EAR=$H21_HOME/presence/conduit@alpha.ear
wait_file "$H21_EAR" 100 || fail H21 "initial snapshot was not written"
h21_wait=0
while ! grep -q '^identity name=earsafe ' "$H21_EAR" 2>/dev/null && [ "$h21_wait" -lt 100 ]; do
    sleep 0.05
    h21_wait=$((h21_wait + 1))
done
[ "$h21_wait" -lt 100 ] || fail H21 "identity did not enter the snapshot"
uv run --no-project python - "$H21_EAR" <<'PY' || fail H21 "snapshot shape/caps failed"
import pathlib, sys
path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
lines = data.decode().splitlines()
assert len(data) <= 16 * 1024, len(data)
assert lines[:10] == [
    "ears 1", "node alpha", lines[2], lines[3], "interval 30", "state running",
    "complete yes", lines[7],
    "mailbox -", "link -",
], lines[:10]
assert lines[2].startswith("generation ")
assert lines[3].startswith("written-at ")
assert lines[7].startswith("component conduit release=") and lines[7].endswith(" adapter=1 ears=1"), lines[7]
rows = [line for line in lines if line.startswith("identity name=earsafe ")]
assert len(rows) == 1, rows
fields = rows[0].split()
required = {
    "principal=session", "listening=yes", "route=socket", "phase=ready",
    "cc=2.1.233", "reason=-", "pending-ring=1", "pending-info=0",
    "pending-operator=0", "last-drain-before=-", "last-drain-after=-",
}
assert required <= set(fields), fields
assert len(rows[0].encode()) <= 1024
PY
for h21_sentinel in h21-peer-sentinel h21-socket-sentinel h21-subject-sentinel \
    h21-body-sentinel sentinel-sender "$H21_INSTANCE" "$H21_LISTENER_PID"; do
    ! grep -Fq "$h21_sentinel" "$H21_EAR" || fail H21 "snapshot leaked $h21_sentinel"
done
! grep -q '/' "$H21_EAR" || fail H21 "snapshot leaked a path separator"
H21_PENDING=$(runtime_env KHALA_HOME="$H21_HOME" "$BIN" runtime pending-generation \
    --identity earsafe 2>"$RIG/h21.pending.err") || fail H21 "pending-generation failed"
[ ! -s "$RIG/h21.pending.err" ] || fail H21 "pending-generation wrote stderr"
H21_PENDING_GENERATION=${H21_PENDING%% *}
uv run --no-project python - "$LISTENER_OUTPUT" "$H21_PENDING_GENERATION" <<'PY' || \
    fail H21 "pending-generation differs from the notification frame"
import json, sys
frame = json.loads(open(sys.argv[1], encoding="utf-8").readline())
content = frame["message"]["content"].splitlines()
assert "generation: " + sys.argv[2] in content, (content, sys.argv[2])
PY
cp "$H21_EAR" "$RIG/h21.before-pending"
stage_letter "$H21_HOME" earsafe 22 another@alpha
sleep 0.6
cmp -s "$RIG/h21.before-pending" "$H21_EAR" || fail H21 "pending-only change rewrote snapshot"
runtime_env KHALA_HOME="$H21_HOME" "$BIN" runtime release --identity earsafe \
    --instance "$H21_INSTANCE" >/dev/null || fail H21 "runtime release failed"
H21_OLD_GENERATION=$(sed -n 's/^generation //p' "$RIG/h21.before-pending")
h21_wait=0
while [ "$h21_wait" -lt 60 ]; do
    H21_NEW_GENERATION=$(sed -n 's/^generation //p' "$H21_EAR" 2>/dev/null || :)
    [ -n "$H21_NEW_GENERATION" ] && [ "$H21_NEW_GENERATION" -gt "$H21_OLD_GENERATION" ] && break
    sleep 0.05
    h21_wait=$((h21_wait + 1))
done
[ "$h21_wait" -lt 60 ] || fail H21 "lease-release transition took more than 3 seconds"
! grep -q '^identity name=earsafe ' "$H21_EAR" || fail H21 "released-only identity remained in snapshot"
stop_pid "$H21_CONDUIT_PID"
[ "$(grep -c '^identity ' "$H21_EAR" || :)" -eq 0 ] || fail H21 "clean shutdown snapshot retained identities"
grep -q '^state stopping$' "$H21_EAR" || fail H21 "clean shutdown snapshot did not say stopping"
pass H21 "listener snapshot is exact, leak-free, transition-driven, and empty on shutdown"

# H22 — dashboard binds the requested ephemeral address, authenticates every
# API call, returns the security headers, and leaves KHALA_HOME byte-for-byte
# unchanged as a file tree.
H22_HOME=$RIG/h22-home
init_home "$H22_HOME"
stage_letter "$H22_HOME" local 22 sender@alpha "h22-secret-subject"
mkdir -p "$H22_HOME/minds/alpha/local"
cat > "$H22_HOME/minds/alpha/local/1700000000.1" <<'EOF'
Generation: 1700000000.1
Session: local
Node: alpha
State: active
Model: opus
Effort: high
Role: builder
Charge: test
Focus: h22-secret-focus
Stance: h22-secret-stance
Declared-State: 1700000000
Declared-Model: 1700000000
Declared-Effort: 1700000000
Declared-Role: 1700000000
Declared-Charge: 1700000000
Declared-Focus: 1700000000
Declared-Stance: 1700000000

EOF
# Paths and kinds (ls -F marks directories, links, sockets); find -printf is GNU-only.
ls -AFR "$H22_HOME" > "$RIG/h22.tree.before"
KHALA_HOME=$H22_HOME KHALA_RUNTIME_DIR=$H22_HOME/runtime-must-not-exist \
    "$BIN" dashboard --port 0 --no-text \
    >"$RIG/h22.dashboard.out" 2>"$RIG/h22.dashboard.err" &
H22_DASHBOARD_PID=$!
PIDS="$PIDS $H22_DASHBOARD_PID"
h22_wait=0
while [ "$(line_count "$RIG/h22.dashboard.out")" -lt 1 ] && [ "$h22_wait" -lt 100 ]; do
    sleep 0.05
    h22_wait=$((h22_wait + 1))
done
[ "$h22_wait" -lt 100 ] || fail H22 "dashboard did not report address and token"
[ "$(line_count "$RIG/h22.dashboard.out")" -eq 1 ] || fail H22 "dashboard printed more than one stdout line"
H22_ADDRESS=$(sed -n 's|^dashboard: http://\([^/]*\)/#.*$|\1|p' "$RIG/h22.dashboard.out")
H22_TOKEN=$(sed -n 's|^dashboard: http://[^/]*/#\(.*\)$|\1|p' "$RIG/h22.dashboard.out")
[ -n "$H22_ADDRESS" ] && [ -n "$H22_TOKEN" ] || fail H22 "dashboard stdout contract is malformed"
uv run --no-project python - "$H22_ADDRESS" "$H22_TOKEN" <<'PY' || fail H22 "HTTP contract failed"
import json, sys, urllib.error, urllib.request
address, token = sys.argv[1:]
base = "http://" + address

def call(path, auth=None, method="GET"):
    request = urllib.request.Request(base + path, method=method)
    if auth is not None:
        request.add_header("Authorization", "Bearer " + auth)
    try:
        response = urllib.request.urlopen(request, timeout=2)
    except urllib.error.HTTPError as error:
        response = error
    headers = response.headers
    assert headers["Cache-Control"] == "no-store", headers
    assert headers["X-Content-Type-Options"] == "nosniff", headers
    assert headers["Referrer-Policy"] == "no-referrer", headers
    assert headers["Content-Security-Policy"] == "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'", headers
    assert headers["X-Frame-Options"] == "DENY", headers
    assert "Access-Control-Allow-Origin" not in headers, headers
    return response.status, response.read()

assert call("/api/v1/fleet")[0] == 401
assert call("/api/v1/fleet?token=" + token)[0] == 401
assert call("/api/v1/fleet", "wrong")[0] == 401
status, body = call("/api/v1/fleet", token)
assert status == 200, (status, body)
payload = json.loads(body)
assert payload["apiVersion"] == 1
lower = body.lower()
for forbidden in (b'"subject"', b'"body"', b'"focus"', b'"stance"', b'h22-secret'):
    assert forbidden not in lower, forbidden
assert call("/api/v1/letter?identity=local&id=bad", token)[0] == 404
assert call("/api/v1/fleet", token, "POST")[0] == 405
assert call("/")[0] == 200
PY
kill "$H22_DASHBOARD_PID" 2>/dev/null || fail H22 "dashboard was not running at shutdown"
wait "$H22_DASHBOARD_PID"
H22_STATUS=$?
[ "$H22_STATUS" -eq 0 ] || fail H22 "SIGTERM exited $H22_STATUS, want 0"
ls -AFR "$H22_HOME" > "$RIG/h22.tree.after"
cmp -s "$RIG/h22.tree.before" "$RIG/h22.tree.after" || fail H22 "dashboard changed KHALA_HOME tree"
[ ! -e "$H22_HOME/runtime-must-not-exist" ] || fail H22 "dashboard created or chmodded runtime"
if KHALA_HOME=$H22_HOME "$BIN" dashboard --listen 0.0.0.0:0 \
    >"$RIG/h22.nonloop.out" 2>"$RIG/h22.nonloop.err"; then
    fail H22 "removed --listen option succeeded"
else
    H22_STATUS=$?
fi
[ "$H22_STATUS" -eq 2 ] || fail H22 "removed --listen exited $H22_STATUS, want 2"
"$RIG/venv/bin/python" - "$RIG/h22.port" <<'PY' &
import socket, sys, time
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
sock.listen()
open(sys.argv[1], "w", encoding="utf-8").write(f"127.0.0.1:{sock.getsockname()[1]}\n")
time.sleep(10)
PY
H22_PORT_PID=$!
PIDS="$PIDS $H22_PORT_PID"
wait_file "$RIG/h22.port" 100 || fail H22 "port holder did not bind"
H22_BUSY=$(sed -n '1p' "$RIG/h22.port")
H22_BUSY_PORT=${H22_BUSY##*:}
if KHALA_HOME=$H22_HOME "$BIN" dashboard --port "$H22_BUSY_PORT" \
    >"$RIG/h22.busy.out" 2>"$RIG/h22.busy.err"; then
    fail H22 "busy port silently hopped"
else
    H22_STATUS=$?
fi
[ "$H22_STATUS" -eq 1 ] || fail H22 "busy port exited $H22_STATUS, want 1"
stop_pid "$H22_PORT_PID"
pass H22 "dashboard auth, headers, guards, ephemeral bind, and read-only tree passed"

printf 'RESULT: PASS\n'
printf 'Conduit delivery, channel routing, lease, hook, restart, watch, runtime, ears, and dashboard properties passed\n'
