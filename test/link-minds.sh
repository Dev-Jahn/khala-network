#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO_BINARY-"$HOME/go-toolchain/bin/go"}
GO_TMP=$HOME/.cache/khala-go-tmp
GO_CACHE=$HOME/.cache/khala-go-cache
RIG=$HOME/.khala-link-minds-test.$$
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
    printf 'FAIL %s — %s\n' "$1" "$2" >&2
    find "$RIG" -maxdepth 7 -type f -print 2>/dev/null | sort >&2
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

init_home() {
    KHALA_HOME=$1 "$KHALA" init "$2" >"$RIG/init-$2.out" 2>"$RIG/init-$2.err" ||
        fail 0 "init $2 failed"
}

write_config() {
    config_home=$1
    config_self=$2
    config_peer=$3
    config_endpoint=$4
    {
        printf 'self %s\n' "$config_self"
        printf 'peer %s %s\n' "$config_peer" "$config_endpoint"
        printf 'mailbox %s\n' "$config_peer"
        printf 'ttl 120\n'
        printf 'retain 30\n'
    } > "$config_home/config"
}

start_link() {
    start_home=$1
    start_peer=$2
    start_remote_home=$3
    start_brain=$4
    shift 4
    env KHALA_HOME="$start_home" KHALA_BRAIN="$start_brain" \
        KHALA_LINK_TEST_SERVE_HOME="$start_remote_home" \
        KHALA_LINK_TEST_SERVE_NODE="$start_peer" \
        KHALA_LINK_TEST_SCAN_INTERVAL=1s \
        "$@" "$BIN" >"$start_home/link.stdout" 2>"$start_home/link.stderr" &
    LAST_PID=$!
    PIDS="$PIDS $LAST_PID"
}

start_local_link() {
    start_home=$1
    start_brain=$2
    shift 2
    env KHALA_HOME="$start_home" KHALA_BRAIN="$start_brain" \
        KHALA_LINK_TEST_SCAN_INTERVAL=1s \
        "$@" "$BIN" >"$start_home/local-link.stdout" 2>"$start_home/local-link.stderr" &
    LAST_PID=$!
    PIDS="$PIDS $LAST_PID"
}

stop_link() {
    kill -TERM "$1" 2>/dev/null || :
    wait "$1" 2>/dev/null || :
}

wait_file() {
    wait_path=$1
    wait_deadline=$(( $(date +%s) + $2 ))
    while [ ! -f "$wait_path" ] && [ "$(date +%s)" -lt "$wait_deadline" ]; do
        sleep 0.05
    done
    [ -f "$wait_path" ]
}

wait_absent() {
    wait_path=$1
    wait_deadline=$(( $(date +%s) + $2 ))
    while [ -e "$wait_path" ] && [ "$(date +%s)" -lt "$wait_deadline" ]; do
        sleep 0.05
    done
    [ ! -e "$wait_path" ]
}

carrier_child() {
    for carrier_pid in $(pgrep -P "$1" 2>/dev/null); do
        carrier_command=$(ps -p "$carrier_pid" -o command= 2>/dev/null) || continue
        case "$carrier_command" in
            *"khala-link --serve"*) printf '%s\n' "$carrier_pid"; return 0 ;;
        esac
    done
    return 1
}

wait_new_child() {
    wait_deadline=$(( $(date +%s) + $3 ))
    while [ "$(date +%s)" -lt "$wait_deadline" ]; do
        wait_child=$(carrier_child "$1") || wait_child=
        if [ -n "$wait_child" ] && [ "$wait_child" != "$2" ]; then
            printf '%s\n' "$wait_child"
            return 0
        fi
        sleep 0.05
    done
    return 1
}

write_mind_file() {
    mind_home=$1
    mind_node=$2
    mind_session=$3
    mind_generation=$4
    mind_focus=$5
    mind_epoch=${mind_generation%%.*}
    mind_dir=$mind_home/minds/$mind_node/$mind_session
    mkdir -p "$mind_dir" || return 1
    {
        printf 'Generation: %s\n' "$mind_generation"
        printf 'Session: %s\n' "$mind_session"
        printf 'Node: %s\n' "$mind_node"
        printf 'State: active\nModel: \nEffort: \nRole: \nCharge: \n'
        printf 'Focus: %s\nStance: focused\n' "$mind_focus"
        printf 'Declared-State: %s\nDeclared-Model: %s\nDeclared-Effort: %s\n' \
            "$mind_epoch" "$mind_epoch" "$mind_epoch"
        printf 'Declared-Role: %s\nDeclared-Charge: %s\nDeclared-Focus: %s\nDeclared-Stance: %s\n\n' \
            "$mind_epoch" "$mind_epoch" "$mind_epoch" "$mind_epoch"
    } > "$mind_dir/$mind_generation"
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

# M8a: direct pipe, minds view, and watch non-wake.
A=$RIG/m8a-alpha
B=$RIG/m8a-beta
init_home "$A" alpha
init_home "$B" beta
write_config "$A" alpha beta "$B"
start_local_link "$B" "$KHALA"
B_LOCAL_PID=$LAST_PID
start_link "$A" beta "$B" "$KHALA" KHALA_LINK_TEST_PING_INTERVAL=1h
A_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail M8a "direct link did not handshake"
KHALA_HOME="$B" "$KHALA" watch --session listener --interval 1 --max-wait 3 \
    >"$B/watch.out" 2>"$B/watch.err" &
WATCH_PID=$!
PIDS="$PIDS $WATCH_PID"
sleep 0.3
start_ns=$(date +%s%N)
M8A_GEN=$(KHALA_HOME="$A" KHALA_SESSION=worker "$KHALA" mind -m 'direct neural mind') ||
    fail M8a "khala mind failed"
wait_file "$B/minds/alpha/worker/$M8A_GEN" 3 || fail M8a "mind did not reach direct receiver"
end_ns=$(date +%s%N)
M8A_MS=$(( (end_ns - start_ns) / 1000000 ))
[ "$M8A_MS" -le 2000 ] || fail M8a "direct mind latency ${M8A_MS}ms"
KHALA_HOME="$B" "$KHALA" minds >"$B/minds.out" || fail M8a "receiver minds failed"
grep -q '^worker@alpha.*direct neural mind' "$B/minds.out" || fail M8a "receiver table omitted mind"
if wait "$WATCH_PID"; then
    fail M8a "mind woke watch"
else
    WATCH_STATUS=$?
fi
[ "$WATCH_STATUS" -eq 3 ] || fail M8a "watch exited $WATCH_STATUS"
pass M8a "direct mind installed and appeared in ${M8A_MS}ms without waking watch"
stop_link "$A_PID"

# M8b: A -> hub -> B, including a generation owned by the hub itself.
HA=$RIG/m8b-alpha
HB=$RIG/m8b-beta
HUB=$RIG/m8b-b200
init_home "$HA" hopalpha
init_home "$HB" hopbeta
init_home "$HUB" b200
write_config "$HA" hopalpha b200 "$HUB"
write_config "$HB" hopbeta b200 "$HUB"
start_local_link "$HUB" "$KHALA"
HUB_LOCAL_PID=$LAST_PID
start_link "$HA" b200 "$HUB" "$KHALA"
HA_PID=$LAST_PID
start_link "$HB" b200 "$HUB" "$KHALA"
HB_PID=$LAST_PID
wait_file "$HA/run/link.fresh" 5 || fail M8b "alpha hub link did not handshake"
wait_file "$HB/run/link.fresh" 5 || fail M8b "beta hub link did not handshake"
start_ns=$(date +%s%N)
HOP_GEN=$(KHALA_HOME="$HA" KHALA_SESSION=worker "$KHALA" mind -m 'three hop mind') ||
    fail M8b "three-hop mind failed"
wait_file "$HB/minds/hopalpha/worker/$HOP_GEN" 4 || fail M8b "spoke shard did not fan out"
end_ns=$(date +%s%N)
HOP_MS=$(( (end_ns - start_ns) / 1000000 ))
[ "$HOP_MS" -le 3000 ] || fail M8b "three-hop latency ${HOP_MS}ms"
HUB_GEN=$(KHALA_HOME="$HUB" KHALA_SESSION=hubmind "$KHALA" mind -m 'hub owned mind') ||
    fail M8b "hub mind failed"
wait_file "$HB/minds/b200/hubmind/$HUB_GEN" 4 || fail M8b "hub shard did not fan out"
[ -f "$HUB/minds/hopalpha/worker/$HOP_GEN" ] || fail M8b "hub deleted projected generation"
pass M8b "hub retained and fanned out spoke and hub shards in ${HOP_MS}ms"
stop_link "$HA_PID"
stop_link "$HB_PID"

# M8c: minor 1 suppresses only mind; sync later carries the same generation.
OA=$RIG/m8c-oldalpha
OH=$RIG/m8c-b200
init_home "$OA" oldalpha
init_home "$OH" b200
write_config "$OA" oldalpha b200 "$OH"
start_local_link "$OH" "$KHALA"
OH_LOCAL_PID=$LAST_PID
start_link "$OA" b200 "$OH" "$KHALA" KHALA_LINK_TEST_SERVE_MINOR=1
OA_PID=$LAST_PID
wait_file "$OA/run/link.fresh" 5 || fail M8c "minor-1 link did not handshake"
OLD_GEN=$(KHALA_HOME="$OA" KHALA_SESSION=legacy "$KHALA" mind -m 'sync degradation mind') ||
    fail M8c "minor-1 mind failed"
MAIL_ID=$(KHALA_HOME="$OA" KHALA_SESSION=legacy "$KHALA" send legacy@b200 -m 'legacy mail') ||
    fail M8c "mail failed"
STREAM_ID=$(KHALA_HOME="$OA" KHALA_SESSION=legacy "$KHALA" say legacy -m 'legacy stream') ||
    fail M8c "stream failed"
wait_file "$OH/inbox/legacy/new/$MAIL_ID" 4 || fail M8c "mail did not cross minor 1"
wait_file "$OH/presence/legacy@oldalpha" 4 || fail M8c "presence did not cross minor 1"
wait_file "$OH/streams/legacy/oldalpha/$STREAM_ID" 4 || fail M8c "stream did not cross minor 1"
sleep 2
[ ! -e "$OH/minds/oldalpha/legacy/$OLD_GEN" ] || fail M8c "mind OFFER crossed minor 1"
grep -q 'negotiated protocol 1.1; mind offers disabled' "$OA/log/link.log" ||
    fail M8c "mind suppression was not logged"
if grep -Eq 'fatal protocol error|BAD_OFFER|INVALID_OFFER|UNKNOWN_FRAME' \
    "$OA/log/link.log" "$OH/log/link.log"; then
    fail M8c "minor-1 session logged a protocol error"
fi
KHALA_HOME="$OA" "$KHALA" sync >"$OA/sync.out" 2>"$OA/sync.err" ||
    fail M8c "sync degradation path failed"
wait_file "$OH/minds/oldalpha/legacy/$OLD_GEN" 3 || fail M8c "sync did not carry mind"
cmp -s "$OA/minds/oldalpha/legacy/$OLD_GEN" "$OH/minds/oldalpha/legacy/$OLD_GEN" ||
    fail M8c "sync changed suppressed generation bytes"
pass M8c "minor 1 kept mail/presence/stream live, suppressed mind, then sync converged"
stop_link "$OA_PID"

# M8d: a delayed lower generation installs, max remains V2, next real reconcile GCs V1.
DA=$RIG/m8d-alpha
DB=$RIG/m8d-beta
BRAIN_WRAPPER=$RIG/brain-wrapper
init_home "$DA" delayalpha
init_home "$DB" delaybeta
write_config "$DA" delayalpha delaybeta "$DB"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if [ "$1" = reconcile ] && [ "${KHALA_LINK_SCAN_GATE-}" != 1 ] && [ -f "$KHALA_HOME/block-reconcile" ]; then'
    printf '%s\n' '    : > "$KHALA_HOME/brain.triggered"'
    printf '%s\n' '    exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec "$KHALA_REAL_BRAIN" "$@"'
} > "$BRAIN_WRAPPER"
chmod 755 "$BRAIN_WRAPPER"
V1=$(KHALA_HOME="$DA" KHALA_SESSION=worker "$KHALA" mind -m 'delayed V1') || fail M8d "V1 failed"
cp "$DA/minds/delayalpha/worker/$V1" "$RIG/v1.fixture" || fail M8d "V1 fixture failed"
V2=$(KHALA_HOME="$DA" KHALA_SESSION=worker "$KHALA" mind -m 'current V2') || fail M8d "V2 failed"
start_local_link "$DB" "$BRAIN_WRAPPER" \
    KHALA_REAL_BRAIN="$KHALA" KHALA_LINK_TEST_SCAN_INTERVAL=1h
DB_LOCAL_PID=$LAST_PID
start_link "$DA" delaybeta "$DB" "$BRAIN_WRAPPER" \
    KHALA_REAL_BRAIN="$KHALA" KHALA_LINK_TEST_SCAN_INTERVAL=1h
DA_PID=$LAST_PID
wait_file "$DB/minds/delayalpha/worker/$V2" 5 || fail M8d "V2 did not install"
# The receiver-side singleton owns reconcile now. Wait for its first
# data-triggered pass before turning on the wrapper gate; otherwise the fixture
# can relabel the initially delivered V1 as the deliberately delayed copy.
wait_absent "$DB/minds/delayalpha/worker/$V1" 3 ||
    fail M8d "initial V1 was not collected before delayed injection"
: > "$DB/block-reconcile"
cp "$RIG/v1.fixture" "$DA/minds/delayalpha/worker/$V1" || fail M8d "late V1 injection failed"
wait_file "$DB/minds/delayalpha/worker/$V1" 3 || fail M8d "late V1 was not installed"
wait_file "$DB/brain.triggered" 3 || fail M8d "mind install did not trigger brain"
KHALA_HOME="$DB" "$KHALA" minds >"$DB/minds.out" || fail M8d "minds view failed"
grep -q '^worker@delayalpha.*current V2' "$DB/minds.out" || fail M8d "V1 displaced V2"
rm -f "$DB/block-reconcile"
KHALA_HOME="$DB" "$KHALA" reconcile >/dev/null 2>"$DB/reconcile.err" || fail M8d "reconcile failed"
[ ! -e "$DB/minds/delayalpha/worker/$V1" ] || fail M8d "next reconcile kept V1"
[ -f "$DB/minds/delayalpha/worker/$V2" ] || fail M8d "next reconcile removed V2"
pass M8d "late V1 installed without displacing V2 and the next reconcile collected it"
stop_link "$DA_PID"

# L5: link DATA and rsync race on one immutable generation.
RA=$RIG/l5-alpha
RB=$RIG/l5-beta
init_home "$RA" racealpha
init_home "$RB" racebeta
write_config "$RA" racealpha racebeta "$RB"
start_local_link "$RB" "$KHALA"
RB_LOCAL_PID=$LAST_PID
start_link "$RA" racebeta "$RB" "$KHALA" KHALA_LINK_TEST_DATA_INSTALL_DELAY=500ms
RA_PID=$LAST_PID
wait_file "$RA/run/link.fresh" 5 || fail L5 "race link did not handshake"
RACE_GEN=$(KHALA_HOME="$RA" KHALA_SESSION=worker "$KHALA" mind -m 'link rsync race') ||
    fail L5 "race mind failed"
KHALA_HOME="$RA" "$KHALA" sync >"$RA/sync.out" 2>"$RA/sync.err" &
SYNC_PID=$!
wait "$SYNC_PID" || fail L5 "racing sync failed"
wait_file "$RB/minds/racealpha/worker/$RACE_GEN" 4 || fail L5 "racing generation missing"
[ "$(find "$RB/minds/racealpha/worker" -maxdepth 1 -type f -name "$RACE_GEN" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail L5 "race produced more than one generation file"
cmp -s "$RA/minds/racealpha/worker/$RACE_GEN" "$RB/minds/racealpha/worker/$RACE_GEN" ||
    fail L5 "race changed generation bytes"
pass L5 "link+rsync race left one byte-identical generation"
stop_link "$RA_PID"

# L6: future quarantine, expired skip, no wake, and three redials with no old OFFER.
FA=$RIG/l6-alpha
FB=$RIG/l6-beta
init_home "$FA" guardalpha
init_home "$FB" guardbeta
write_config "$FA" guardalpha guardbeta "$FB"
start_local_link "$FB" "$KHALA"
FB_LOCAL_PID=$LAST_PID
KEEPER_GEN=$(date +%s).0
write_mind_file "$FA" guardalpha future "$KEEPER_GEN" 'future guard keeper' || fail L6 "future keeper failed"
write_mind_file "$FA" guardalpha ancient "$KEEPER_GEN" 'old guard keeper' || fail L6 "old keeper failed"
start_link "$FA" guardbeta "$FB" "$KHALA" \
    KHALA_LINK_TEST_SCAN_INTERVAL=1h KHALA_LINK_TEST_PING_INTERVAL=1h
FA_PID=$LAST_PID
wait_file "$FA/run/link.fresh" 5 || fail L6 "guard link did not handshake"
wait_file "$FB/minds/guardalpha/future/$KEEPER_GEN" 4 || fail L6 "future keeper did not install"
wait_file "$FB/minds/guardalpha/ancient/$KEEPER_GEN" 4 || fail L6 "old keeper did not install"
KHALA_HOME="$FB" "$KHALA" watch --session guardwatch --interval 1 --max-wait 3 \
    >"$FB/watch.out" 2>"$FB/watch.err" &
GUARD_WATCH_PID=$!
PIDS="$PIDS $GUARD_WATCH_PID"
FUTURE_GEN=$(( $(date +%s) + 86401 )).0
write_mind_file "$FA" guardalpha future "$FUTURE_GEN" 'future mind' || fail L6 "future fixture failed"
wait_file "$FA/spool/dead/mind.guardalpha.future.$FUTURE_GEN" 4 || fail L6 "future mind was not quarantined"
[ ! -e "$FA/minds/guardalpha/future/$FUTURE_GEN" ] || fail L6 "future mind stayed live"
[ ! -e "$FB/minds/guardalpha/future/$FUTURE_GEN" ] || fail L6 "future mind polluted receiver"
OLD_GEN=$(( $(date +%s) - 32 * 86400 )).0
write_mind_file "$RIG" guardalpha ancient "$OLD_GEN" 'expired mind' || fail L6 "old fixture failed"
mkdir -p "$FA/minds/guardalpha/ancient" || fail L6 "old source directory failed"
cp "$RIG/minds/guardalpha/ancient/$OLD_GEN" "$FA/minds/guardalpha/ancient/$OLD_GEN" || fail L6 "old injection failed"
old_log_deadline=$(( $(date +%s) + 3 ))
while ! grep -Fq "expired mind offer skipped: $OLD_GEN" "$FA/log/link.log" 2>/dev/null && \
    [ "$(date +%s)" -lt "$old_log_deadline" ]; do
    sleep 0.05
done
grep -Fq "expired mind offer skipped: $OLD_GEN" "$FA/log/link.log" || fail L6 "old offer guard did not run"
GUARD_CHILD=$(carrier_child "$FA_PID")
[ -n "$GUARD_CHILD" ] || fail L6 "guard carrier child missing"
guard_round=1
while [ "$guard_round" -le 3 ]; do
    kill -KILL "$GUARD_CHILD" 2>/dev/null || fail L6 "could not kill carrier round $guard_round"
    mkdir -p "$FA/minds/guardalpha/ancient" || fail L6 "old source directory failed in round $guard_round"
    cp "$RIG/minds/guardalpha/ancient/$OLD_GEN" "$FA/minds/guardalpha/ancient/$OLD_GEN" ||
        fail L6 "old reinjection failed in round $guard_round"
    # Full jitter at the third short-lived reconnect has an 8s cap.
    GUARD_CHILD=$(wait_new_child "$FA_PID" "$GUARD_CHILD" 10) || fail L6 "redial $guard_round did not start"
    wait_absent "$FA/minds/guardalpha/ancient/$OLD_GEN" 4 || fail L6 "scan gate kept old generation in round $guard_round"
    [ ! -e "$FB/minds/guardalpha/ancient/$OLD_GEN" ] || fail L6 "old generation reached receiver"
    guard_round=$((guard_round + 1))
done
if grep -Fq "$OLD_GEN" "$FB/log/link.log" 2>/dev/null; then
    fail L6 "receiver observed an expired mind OFFER"
fi
OLD_LOG_COUNT=$(grep -F "$OLD_GEN" "$FA/log/link.log" 2>/dev/null | wc -l | tr -d ' ')
[ "$OLD_LOG_COUNT" -le 1 ] || fail L6 "old generation logged $OLD_LOG_COUNT times across redials"
if wait "$GUARD_WATCH_PID"; then
    fail L6 "age-refused mind woke watch"
else
    GUARD_WATCH_STATUS=$?
fi
[ "$GUARD_WATCH_STATUS" -eq 3 ] || fail L6 "guard watch exited $GUARD_WATCH_STATUS"
pass L6 "future quarantined; old skipped with zero receiver OFFERs across three redials and no wake"

printf 'RESULT: PASS\n'
printf 'mind protocol, fan-out, negotiation, generation order, race, and age properties passed\n'
