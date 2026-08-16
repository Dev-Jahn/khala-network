#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO_BINARY-"$HOME/go-toolchain/bin/go"}
GO_TMP=$HOME/.cache/khala-go-tmp
GO_CACHE=$HOME/.cache/khala-go-cache
RIG=$ROOT/.link-streams-test.$$
BIN=$RIG/khala-link
PIDS=
LAST_PID=

cleanup() {
    for cleanup_pid in $PIDS; do
        kill -TERM "$cleanup_pid" 2>/dev/null || :
    done
    for cleanup_pid in $PIDS; do
        wait "$cleanup_pid" 2>/dev/null || :
    done
    if [ "${KHALA_LINK_TEST_KEEP_RIG-}" = 1 ]; then
        printf 'preserved test rig: %s\n' "$RIG" >&2
    else
        rm -rf -- "$RIG"
    fi
}

fail() {
    step=$1
    shift
    printf 'FAIL %s — %s\n' "$step" "$*" >&2
    find "$RIG" -maxdepth 6 -type f -print 2>/dev/null | sort >&2
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

init_home() {
    init_home_path=$1
    init_node=$2
    KHALA_HOME="$init_home_path" "$KHALA" init "$init_node" \
        >"$RIG/init-$init_node.out" 2>"$RIG/init-$init_node.err" ||
        fail 0 "init $init_node failed"
}

write_config() {
    config_home=$1
    config_self=$2
    config_hub=$3
    {
        printf 'self %s\n' "$config_self"
        printf 'peer b200 %s\n' "$config_hub"
        printf 'mailbox b200\n'
        printf 'ttl 120\n'
        printf 'retain 30\n'
    } > "$config_home/config"
}

start_link() {
    start_home=$1
    start_node=$2
    start_hub=$3
    shift 3
    env KHALA_HOME="$start_home" \
        KHALA_BRAIN="$KHALA" \
        KHALA_LINK_TEST_SERVE_HOME="$start_hub" \
        KHALA_LINK_TEST_SERVE_NODE=b200 \
        KHALA_LINK_TEST_SCAN_INTERVAL=1s \
        "$@" "$BIN" >"$start_home/link.stdout" 2>"$start_home/link.stderr" &
    LAST_PID=$!
    PIDS="$PIDS $LAST_PID"
}

start_local_link() {
    start_home=$1
    env KHALA_HOME="$start_home" KHALA_BRAIN="$KHALA" \
        KHALA_LINK_TEST_SCAN_INTERVAL=1s \
        "$BIN" >"$start_home/local-link.stdout" 2>"$start_home/local-link.stderr" &
    LAST_PID=$!
    PIDS="$PIDS $LAST_PID"
}

stop_link() {
    stop_pid=$1
    kill -TERM "$stop_pid" 2>/dev/null || :
    wait "$stop_pid" 2>/dev/null || :
}

wait_file() {
    wait_path=$1
    wait_seconds=$2
    wait_deadline=$(( $(date +%s) + wait_seconds ))
    while [ ! -f "$wait_path" ] && [ "$(date +%s)" -lt "$wait_deadline" ]; do
        sleep 0.05
    done
    [ -f "$wait_path" ]
}

wait_absent() {
    wait_path=$1
    wait_seconds=$2
    wait_deadline=$(( $(date +%s) + wait_seconds ))
    while [ -e "$wait_path" ] && [ "$(date +%s)" -lt "$wait_deadline" ]; do
        sleep 0.05
    done
    [ ! -e "$wait_path" ]
}

wait_either_file() {
    wait_first=$1
    wait_second=$2
    wait_seconds=$3
    wait_deadline=$(( $(date +%s) + wait_seconds ))
    while [ ! -f "$wait_first" ] && [ ! -f "$wait_second" ] && \
        [ "$(date +%s)" -lt "$wait_deadline" ]; do
        sleep 0.05
    done
    [ -f "$wait_first" ] || [ -f "$wait_second" ]
}

carrier_child() {
    carrier_parent=$1
    for carrier_pid in $(pgrep -P "$carrier_parent" 2>/dev/null); do
        carrier_command=$(ps -p "$carrier_pid" -o command= 2>/dev/null) || continue
        case "$carrier_command" in
            *"khala-link --serve"*) printf '%s\n' "$carrier_pid"; return 0 ;;
        esac
    done
    return 1
}

wait_new_child() {
    wait_parent=$1
    wait_old_child=$2
    wait_seconds=$3
    wait_deadline=$(( $(date +%s) + wait_seconds ))
    wait_child=
    while [ "$(date +%s)" -lt "$wait_deadline" ]; do
        wait_child=$(carrier_child "$wait_parent") || wait_child=
        if [ -n "$wait_child" ] && [ "$wait_child" != "$wait_old_child" ]; then
            printf '%s\n' "$wait_child"
            return 0
        fi
        sleep 0.05
    done
    return 1
}

write_entry() {
    entry_home=$1
    entry_stream=$2
    entry_node=$3
    entry_session=$4
    entry_epoch=$5
    entry_body=$6
    entry_id=$entry_epoch.1.1.$entry_session@$entry_node
    entry_dir=$entry_home/streams/$entry_stream/$entry_node
    mkdir -p "$entry_dir" || return 1
    {
        printf 'Khala: 0.1\n'
        printf 'Id: %s\n' "$entry_id"
        printf 'From: %s@%s\n' "$entry_session" "$entry_node"
        printf 'Stream: %s\n' "$entry_stream"
        printf 'Date: 2000-01-01T00:00:00Z\n'
        printf 'Type: entry\n'
        printf '\n%s\n' "$entry_body"
    } > "$entry_dir/$entry_id" || return 1
    printf '%s\n' "$entry_id"
}

mkdir -p -- "$RIG" "$GO_TMP" "$GO_CACHE"
trap cleanup EXIT HUP INT TERM

[ -x "$GO" ] || fail 0 "Go toolchain missing at $GO"
if ! (cd "$ROOT/link" && GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" CGO_ENABLED=0 \
    "$GO" test ./... && GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" CGO_ENABLED=0 \
    "$GO" build -trimpath -ldflags '-X main.implVersion=0.4.0-test' -o "$BIN" .) \
    >"$RIG/go.out" 2>"$RIG/go.err"; then
    fail 0 "Go tests/build failed: $(tr '\n' ' ' < "$RIG/go.err")"
fi

A=$RIG/alpha
B=$RIG/beta
HUB=$RIG/b200
OLD_A=$RIG/old-alpha
OLD_HUB=$RIG/old-b200
HARD_A=$RIG/hard-alpha
HARD_HUB=$RIG/hard-b200
init_home "$A" alpha
init_home "$B" beta
init_home "$HUB" b200
init_home "$OLD_A" oldalpha
init_home "$OLD_HUB" b200
init_home "$HARD_A" hardalpha
init_home "$HARD_HUB" b200
write_config "$A" alpha "$HUB"
write_config "$B" beta "$HUB"
write_config "$OLD_A" oldalpha "$OLD_HUB"
write_config "$HARD_A" hardalpha "$HARD_HUB"
start_local_link "$HUB"
HUB_LOCAL_PID=$LAST_PID
start_local_link "$OLD_HUB"
OLD_HUB_LOCAL_PID=$LAST_PID
start_local_link "$HARD_HUB"
HARD_HUB_LOCAL_PID=$LAST_PID

HARD_OLD_EPOCH=$(( $(date +%s) - 32 * 86400 ))
HARD_OLD_ID=$(write_entry "$HARD_A" bounded hardalpha ancient "$HARD_OLD_EPOCH" 'must never be offered') ||
    fail H1 "expired fixture failed"
HARD_FRESH_ID=$(write_entry "$HARD_A" bounded hardalpha living "$(date +%s)" 'must be offered') ||
    fail H1 "fresh fixture failed"
start_link "$HARD_A" hardalpha "$HARD_HUB"
HARD_PID=$LAST_PID
wait_file "$HARD_HUB/streams/bounded/hardalpha/$HARD_FRESH_ID" 5 ||
    fail H1 "fresh entry was not offered after startup reconcile"
wait_absent "$HARD_A/streams/bounded/hardalpha/$HARD_OLD_ID" 5 ||
    fail H1 "startup reconcile did not prune expired owner entry"
[ ! -e "$HARD_HUB/streams/bounded/hardalpha/$HARD_OLD_ID" ] ||
    fail H1 "expired owner entry reached the hub live tree"
if grep -Fq "$HARD_OLD_ID" "$HARD_HUB/log/link.log" 2>/dev/null; then
    fail H1 "hub wire endpoint observed an expired OFFER"
fi
pass H1 "link-first startup reconciled before offering; expired OFFER count was zero"

HARD_CHILD=$(carrier_child "$HARD_PID")
[ -n "$HARD_CHILD" ] || fail H2 "initial carrier child missing"
hard_round=1
while [ "$hard_round" -le 3 ]; do
    kill -KILL "$HARD_CHILD" 2>/dev/null || fail H2 "could not kill carrier round $hard_round"
    HARD_REPLAY_ID=$(write_entry "$HARD_A" bounded hardalpha ancient "$HARD_OLD_EPOCH" 'must never be reoffered') ||
        fail H2 "expired reinjection failed in round $hard_round"
    [ "$HARD_REPLAY_ID" = "$HARD_OLD_ID" ] || fail H2 "reinjection changed fixture Id"
    # Full jitter at the third short-lived reconnect has an 8s cap.
    HARD_CHILD=$(wait_new_child "$HARD_PID" "$HARD_CHILD" 10) ||
        fail H2 "carrier did not redial in round $hard_round"
    wait_absent "$HARD_A/streams/bounded/hardalpha/$HARD_OLD_ID" 5 ||
        fail H2 "expired entry survived redial reconcile in round $hard_round"
    [ ! -e "$HARD_HUB/streams/bounded/hardalpha/$HARD_OLD_ID" ] ||
        fail H2 "expired entry reached hub in round $hard_round"
    hard_round=$((hard_round + 1))
done
HARD_LOG_COUNT=$(grep -Fh "$HARD_OLD_ID" "$HARD_A/log/link.log" "$HARD_HUB/log/link.log" 2>/dev/null | wc -l | tr -d ' ')
[ "$HARD_LOG_COUNT" -le 1 ] || fail H2 "expired item logged $HARD_LOG_COUNT times across three redials"
stop_link "$HARD_PID"
pass H2 "three carrier redials produced zero expired OFFERs and at most one skip log"

start_link "$A" alpha "$HUB"
A_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 8a "alpha link did not handshake"
A_CHILD_BEFORE=$(carrier_child "$A_PID")
[ -n "$A_CHILD_BEFORE" ] || fail 8a "alpha carrier child missing"
start_ns=$(date +%s%N)
PIPE_ID=$(KHALA_HOME="$A" KHALA_SESSION=speaker "$KHALA" say pipe -m 'pipe stream') ||
    fail 8a "say failed"
wait_file "$HUB/streams/pipe/alpha/$PIPE_ID" 3 || fail 8a "pipe stream did not reach receiver"
end_ns=$(date +%s%N)
PIPE_MS=$(( (end_ns - start_ns) / 1000000 ))
[ "$PIPE_MS" -le 2000 ] || fail 8a "pipe latency ${PIPE_MS}ms"
A_CHILD_AFTER=$(carrier_child "$A_PID")
[ "$A_CHILD_BEFORE" = "$A_CHILD_AFTER" ] || fail 8a "carrier reconnected during delivery"
pass 8a "A say reached the pipe receiver in ${PIPE_MS}ms without reconnect"

start_link "$B" beta "$HUB"
B_PID=$LAST_PID
wait_file "$B/run/link.fresh" 5 || fail 8b "beta link did not handshake"
start_ns=$(date +%s%N)
THREE_ID=$(KHALA_HOME="$A" KHALA_SESSION=speaker "$KHALA" say threehop -m 'through hub') ||
    fail 8b "three-hop say failed"
wait_file "$B/streams/threehop/alpha/$THREE_ID" 4 || fail 8b "A shard did not fan out to beta"
end_ns=$(date +%s%N)
THREE_MS=$(( (end_ns - start_ns) / 1000000 ))
[ "$THREE_MS" -le 3000 ] || fail 8b "three-hop latency ${THREE_MS}ms"
[ -f "$HUB/streams/threehop/alpha/$THREE_ID" ] || fail 8b "hub deleted a stream after beta STORED it"
HUB_ID=$(KHALA_HOME="$HUB" KHALA_SESSION=hubvoice "$KHALA" say threehop -m 'hub shard') ||
    fail 8b "hub say failed"
wait_file "$B/streams/threehop/b200/$HUB_ID" 4 || fail 8b "hub shard did not fan out"
grep -q '^peer b200 ' "$B/config" || fail 8b "beta does not point only at the hub"
grep -q '^peer alpha ' "$B/config" && fail 8b "beta was configured to dial alpha"
pass 8b "hub retained and fanned out alpha and b200 shards to beta in ${THREE_MS}ms"

stop_link "$A_PID"
rm -f -- "$HUB/streams/threehop/alpha/$THREE_ID"
sleep 3
[ ! -e "$HUB/streams/threehop/alpha/$THREE_ID" ] || fail L1 "beta reflected alpha's shard upstream"
[ -f "$B/streams/threehop/alpha/$THREE_ID" ] || fail L1 "beta lost its installed projection"
grep -q 'return node == t.self' "$ROOT/link/watch.go" ||
    fail L1 "dial self-shard eligibility guard missing"
pass L1 "dial offered only its own shard; installed alpha projection did not echo"

start_link "$A" alpha "$HUB"
A_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail L2 "alpha link did not restart"
KHALA_HOME="$B" KHALA_SESSION=future-reader "$KHALA" inbox --drain >/dev/null ||
    fail L2 "reader heartbeat failed"
KHALA_HOME="$B" KHALA_SESSION=future-reader "$KHALA" join future --from-start >/dev/null ||
    fail L2 "future stream join failed"
KHALA_HOME="$B" "$KHALA" watch --session future-reader --interval 1 --max-wait 2 \
    >"$B/future-watch.out" 2>"$B/future-watch.err" &
FUTURE_WATCH_PID=$!
PIDS="$PIDS $FUTURE_WATCH_PID"
sleep 0.5
FUTURE_EPOCH=$(( $(date +%s) + 90000 ))
FUTURE_ID=$(write_entry "$A" future alpha timewarp "$FUTURE_EPOCH" 'must quarantine') ||
    fail L2 "future fixture failed"
FUTURE_DEAD_LOCAL=$A/spool/dead/stream.future.alpha.$FUTURE_ID
FUTURE_DEAD_HUB=$HUB/spool/dead/stream.future.alpha.$FUTURE_ID
wait_either_file "$FUTURE_DEAD_LOCAL" "$FUTURE_DEAD_HUB" 4 ||
    fail L2 "future link entry did not use brain quarantine encoding"
if wait "$FUTURE_WATCH_PID"; then
    fail L2 "future link entry woke a joined reader"
else
    FUTURE_WATCH_STATUS=$?
fi
[ "$FUTURE_WATCH_STATUS" -eq 3 ] || fail L2 "future watch exited $FUTURE_WATCH_STATUS"
[ ! -e "$HUB/streams/future/alpha/$FUTURE_ID" ] || fail L2 "future entry polluted hub live tree"
[ ! -e "$B/streams/future/alpha/$FUTURE_ID" ] || fail L2 "future entry fanned out to beta"
if [ -f "$FUTURE_DEAD_LOCAL" ]; then
    grep -Fq "$FUTURE_ID" "$A/log/link.log" || fail L2 "source quarantine was not logged loudly"
else
    grep -Fq "$FUTURE_ID" "$HUB/log/link.log" || fail L2 "install quarantine was not logged loudly"
fi
pass L2 "future epoch was quarantined before live-tree install and caused no wake"
rm -f -- "$A/streams/future/alpha/$FUTURE_ID"

KHALA_HOME="$B" KHALA_SESSION=race-reader "$KHALA" inbox --drain >/dev/null ||
    fail 10 "race reader heartbeat failed"
KHALA_HOME="$B" KHALA_SESSION=race-reader "$KHALA" join race --from-start >/dev/null ||
    fail 10 "race reader join failed"
RACE_ID=$(KHALA_HOME="$A" KHALA_SESSION=racer "$KHALA" say race -m 'link and rsync race') ||
    fail 10 "race say failed"
KHALA_HOME="$A" "$KHALA" sync >"$A/race-sync.out" 2>"$A/race-sync.err" &
RACE_A_PID=$!
KHALA_HOME="$B" "$KHALA" sync >"$B/race-sync.out" 2>"$B/race-sync.err" &
RACE_B_PID=$!
wait "$RACE_A_PID" || :
wait "$RACE_B_PID" || :
wait_file "$B/streams/race/alpha/$RACE_ID" 5 || fail 10 "racing stream delivery missing"
[ "$(find "$B/streams/race/alpha" -maxdepth 1 -type f -name "$RACE_ID" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail 10 "race produced more than one final file"
cmp -s "$A/streams/race/alpha/$RACE_ID" "$B/streams/race/alpha/$RACE_ID" ||
    fail 10 "race changed stream bytes"
KHALA_HOME="$B" KHALA_SESSION=race-reader "$KHALA" inbox --drain \
    >"$B/race-first.out" 2>"$B/race-first.err" || fail 10 "first race drain failed"
[ "$(grep -Fxc -- "--- stream race $RACE_ID ---" "$B/race-first.out")" -eq 1 ] ||
    fail 10 "first drain count was not one"
KHALA_HOME="$B" KHALA_SESSION=race-reader "$KHALA" inbox --drain \
    >"$B/race-second.out" 2>"$B/race-second.err" || fail 10 "second race drain failed"
[ ! -s "$B/race-second.out" ] || fail 10 "race entry redelivered after cursor advance"
pass 10 "link+rsync race left one byte-identical file and one cursor drain"

start_link "$OLD_A" oldalpha "$OLD_HUB" KHALA_LINK_TEST_SERVE_MINOR=0
OLD_A_PID=$LAST_PID
wait_file "$OLD_A/run/link.fresh" 5 || fail 8c "minor-0 link did not handshake"
MAIL_ID=$(KHALA_HOME="$OLD_A" KHALA_SESSION=legacy "$KHALA" send legacy@b200 -m 'legacy mail') ||
    fail 8c "mail send failed"
wait_file "$OLD_HUB/inbox/legacy/new/$MAIL_ID" 4 || fail 8c "mail did not propagate over minor 0"
SLOW_ID=$(KHALA_HOME="$OLD_A" KHALA_SESSION=oldspeaker "$KHALA" say slow -m 'sync later') ||
    fail 8c "minor-0 say failed"
wait_file "$OLD_HUB/presence/oldspeaker@oldalpha" 4 || fail 8c "presence did not propagate over minor 0"
sleep 2
[ ! -e "$OLD_HUB/streams/slow/oldalpha/$SLOW_ID" ] || fail 8c "stream OFFER crossed minor 0"
grep -q 'negotiated protocol 1.0; stream offers disabled' "$OLD_A/log/link.log" ||
    fail 8c "minor negotiation did not log stream suppression"
if grep -Eq 'fatal protocol error|BAD_OFFER|INVALID_OFFER|UNKNOWN_FRAME' \
    "$OLD_A/log/link.log" "$OLD_HUB/log/link.log"; then
    fail 8c "minor-0 session logged a protocol error"
fi
KHALA_HOME="$OLD_A" "$KHALA" sync >"$OLD_A/minor-sync.out" 2>"$OLD_A/minor-sync.err" ||
    fail 8c "sync degradation path failed"
wait_file "$OLD_HUB/streams/slow/oldalpha/$SLOW_ID" 3 || fail 8c "sync did not carry suppressed stream"
cmp -s "$OLD_A/streams/slow/oldalpha/$SLOW_ID" "$OLD_HUB/streams/slow/oldalpha/$SLOW_ID" ||
    fail 8c "sync changed suppressed stream bytes"
pass 8c "minor 0 suppressed stream OFFERs while mail/presence stayed live; sync converged"

printf 'RESULT: PASS\n'
printf 'stream link propagation, negotiation, ownership, quarantine, and race properties passed\n'
