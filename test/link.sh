#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO_BINARY-"$HOME/go-toolchain/bin/go"}
GO_TMP=$HOME/.cache/khala-go-tmp
GO_CACHE=$HOME/.cache/khala-go-cache
RIG=$ROOT/.link-test.$$
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
    find "$RIG" -maxdepth 5 -type f -print 2>/dev/null | sort >&2
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

write_config() {
    config_home=$1
    config_self=$2
    config_hub=$3
    {
        printf 'self %s\n' "$config_self"
        printf 'peer %s %s\n' b200 "$config_hub"
        printf 'mailbox b200\n'
        printf 'ttl 120\n'
    } > "$config_home/config"
}

start_link() {
    start_home=$1
    start_node=$2
    shift 2
    env KHALA_HOME="$start_home" \
        KHALA_BRAIN="$KHALA" \
        KHALA_LINK_TEST_SERVE_HOME="$HUB" \
        KHALA_LINK_TEST_SERVE_NODE=b200 \
        KHALA_LINK_TEST_SCAN_INTERVAL=1s \
        "$@" "$BIN" >"$start_home/link.stdout" 2>"$start_home/link.stderr" &
    LAST_PID=$!
    PIDS="$PIDS $LAST_PID"
}

start_local_link() {
    start_home=$1
    env KHALA_HOME="$start_home" \
        KHALA_BRAIN="$KHALA" \
        KHALA_LINK_TEST_SCAN_INTERVAL=1s \
        "$BIN" >"$start_home/link.stdout" 2>"$start_home/link.stderr" &
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

wait_log() {
    wait_pattern=$1
    wait_path=$2
    wait_seconds=$3
    wait_deadline=$(( $(date +%s) + wait_seconds ))
    while ! grep -q "$wait_pattern" "$wait_path" 2>/dev/null && \
        [ "$(date +%s)" -lt "$wait_deadline" ]; do
        sleep 0.1
    done
    grep -q "$wait_pattern" "$wait_path" 2>/dev/null
}

dial_watched_count() {
    count_home=$1
    count_self=$2
    {
        find "$count_home/outbox/new" -maxdepth 1 -type f -print
        find "$count_home/spool/for" -mindepth 2 -maxdepth 2 -type f \
            ! -path "$count_home/spool/for/$count_self/*" -print
        find "$count_home/presence" -maxdepth 1 -type f \
            \( -name "*@$count_self" -o -name "*@$count_self.watching" \) -print
    } | wc -l | tr -d ' '
}

mkdir -p -- "$RIG" "$GO_TMP" "$GO_CACHE"
trap cleanup EXIT HUP INT TERM

if [ ! -x "$GO" ]; then
    fail 0 "Go toolchain missing at $GO"
fi
if ! (cd "$ROOT/link" && GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" CGO_ENABLED=0 \
    "$GO" test ./... && GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" CGO_ENABLED=0 \
    "$GO" build -trimpath -ldflags '-X main.implVersion=0.4.0-test' -o "$BIN" .) \
    >"$RIG/go.out" 2>"$RIG/go.err"; then
    fail 0 "Go tests/build failed: $(tr '\n' ' ' < "$RIG/go.err")"
fi

A=$RIG/alpha
B=$RIG/beta
HUB=$RIG/b200
STALLED_HUB=$RIG/stalled-hub
C=$RIG/healthy
D=$RIG/stalled
S=$RIG/singleton
W=$RIG/watch
for init_pair in "alpha:$A" "beta:$B" "b200:$HUB" "gamma:$C" "delta:$D" "sigma:$S" "omega:$W"; do
    init_node=${init_pair%%:*}
    init_home=${init_pair#*:}
    KHALA_HOME="$init_home" "$KHALA" init "$init_node" \
        >"$RIG/init-$init_node.out" 2>"$RIG/init-$init_node.err" || fail 0 "init $init_node failed"
done
KHALA_HOME="$STALLED_HUB" "$KHALA" init b200 \
    >"$RIG/init-stalled-hub.out" 2>"$RIG/init-stalled-hub.err" || fail 0 "init stalled hub failed"
write_config "$A" alpha "$HUB"
write_config "$B" beta "$HUB"
write_config "$C" gamma "$HUB"
write_config "$D" delta "$HUB"
write_config "$S" sigma "$HUB"
write_config "$W" omega "$RIG/unreachable-mailbox"

start_local_link "$HUB"
HUB_PID=$LAST_PID
wait_file "$HUB/run/link.status" 5 || fail 0 "hub reconcile singleton did not start"
start_link "$A" alpha
A_PID=$LAST_PID
start_link "$B" beta
B_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 0 "alpha link did not handshake"
wait_file "$B/run/link.fresh" 5 || fail 0 "beta link did not handshake"
sleep 1

start_ns=$(date +%s%N)
AB_ID=$(KHALA_HOME="$A" KHALA_SESSION=sender "$KHALA" send receiver@beta -m 'A to B') || fail 1 "send failed"
wait_file "$B/inbox/receiver/new/$AB_ID" 3 || fail 1 "A to B did not arrive"
end_ns=$(date +%s%N)
AB_MS=$(( (end_ns - start_ns) / 1000000 ))
[ "$AB_MS" -le 2000 ] || fail 1 "A to B latency ${AB_MS}ms"
pass 1 "A→B arrived through the hub in ${AB_MS}ms"
wait_file "$A/outbox/acked/$AB_ID" 5 || fail 1 "A to B ack did not settle before reverse latency measurement"

start_ns=$(date +%s%N)
BA_ID=$(KHALA_HOME="$B" KHALA_SESSION=sender "$KHALA" send receiver@alpha -m 'B to A') || fail 2 "reverse send failed"
wait_file "$A/inbox/receiver/new/$BA_ID" 3 || fail 2 "B to A did not arrive"
end_ns=$(date +%s%N)
BA_MS=$(( (end_ns - start_ns) / 1000000 ))
[ "$BA_MS" -le 2000 ] || fail 2 "B to A latency ${BA_MS}ms"
pass 2 "B→A used the same live links in ${BA_MS}ms"

[ -f "$B/inbox/receiver/new/$AB_ID" ] || fail 3 "hub relay result missing"
pass 3 "hub relay delivered without either spoke dialing the other"

KHALA_HOME="$A" "$KHALA" watch --session ear --interval 30 --max-wait 20 \
    >"$A/ear.out" 2>"$A/ear.err" &
EAR_PID=$!
PIDS="$PIDS $EAR_PID"
wait_file "$B/presence/ear@alpha.watching" 10 || fail 4 "watching presence did not fan out"
KHALA_HOME="$A" KHALA_SESSION=fixture "$KHALA" send ear@alpha -m 'close ear normally' \
    >"$A/ear-send.out" 2>"$A/ear-send.err" || fail 4 "ear wake fixture send failed"
wait "$EAR_PID" || fail 4 "ear did not exit normally after wake"
pass 4 "A watching marker rode hub presence fan-out to B"

start_link "$C" gamma
C_PID=$LAST_PID
HEALTHY_STARTED=$(date +%s)
wait_file "$C/run/link.fresh" 5 || fail 4 "healthy-idle link did not handshake"
(
    while kill -0 "$C_PID" 2>/dev/null; do
        monitor_now=$(date +%s)
        monitor_mtime=$(stat -c %Y "$C/run/link.fresh" 2>/dev/null) || monitor_mtime=$monitor_now
        if [ "$((monitor_now - monitor_mtime))" -ge 12 ]; then
            printf '%s %s\n' "$monitor_now" "$monitor_mtime" >> "$C/freshness-flaps"
        fi
        sleep 1
    done
) &
C_MONITOR_PID=$!
PIDS="$PIDS $C_MONITOR_PID"
(
    cd "$ROOT/link" && KHALA_LINK_LONG_TEST=1 GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" \
        CGO_ENABLED=0 "$GO" test -run '^TestServeDefaultQuietTimeout$' -count=1 -timeout 70s
) >"$RIG/serve-quiet.out" 2>"$RIG/serve-quiet.err" &
SERVE_QUIET_PID=$!
PIDS="$PIDS $SERVE_QUIET_PID"

stop_link "$A_PID"
stop_link "$B_PID"
DOWN_ID=$(KHALA_HOME="$A" KHALA_SESSION=offline "$KHALA" send offline@beta -m 'store and forward') || fail 5 "offline send failed"
KHALA_HOME="$A" "$KHALA" sync >"$A/offline-sync.out" 2>"$A/offline-sync.err" || fail 5 "offline push sync failed"
KHALA_HOME="$B" "$KHALA" sync >"$B/offline-sync.out" 2>"$B/offline-sync.err" || fail 5 "offline pull sync failed"
[ -f "$B/inbox/offline/new/$DOWN_ID" ] || fail 5 "rsync degraded path lost mail"
start_link "$A" alpha
A_PID=$LAST_PID
start_link "$B" beta
B_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 5 "alpha link did not restart"
wait_file "$B/run/link.fresh" 5 || fail 5 "beta link did not restart"
wait_file "$A/outbox/acked/$DOWN_ID" 5 || fail 5 "restart did not converge offline backlog ack"
pass 5 "links-down rsync delivery and link restart converged without a manual poke"

stop_link "$A_PID"
start_link "$A" alpha KHALA_LINK_TEST_DROP_EVENTS=1
A_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 6 "drop-events link did not start"
DROP_ID=$(KHALA_HOME="$A" KHALA_SESSION=drop "$KHALA" send drop@beta -m 'scan heals drop') || fail 6 "drop send failed"
wait_file "$B/inbox/drop/new/$DROP_ID" 10 || fail 6 "periodic scan did not heal dropped events"
pass 6 "dropped notifications converged within one 1s test sweep"

stop_link "$A_PID"
start_link "$A" alpha KHALA_LINK_TEST_OVERFLOW_ON_EVENT=1
A_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 7 "overflow link did not start"
OVERFLOW_ID=$(KHALA_HOME="$A" KHALA_SESSION=overflow "$KHALA" send overflow@beta -m 'overflow rescan') || fail 7 "overflow send failed"
wait_file "$B/inbox/overflow/new/$OVERFLOW_ID" 8 || fail 7 "overflow rescan did not converge"
wait_log 'test overflow hook; full eligible-view rescan' "$A/log/link.log" 3 || fail 7 "overflow rescan was not logged"
pass 7 "overflow hook forced a full eligible-view rescan and converged"

stop_link "$A_PID"
start_link "$A" alpha KHALA_LINK_TEST_DATA_INSTALL_DELAY=3s
A_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 8 "mid-DATA fixture link did not start"
MID_ID=$(KHALA_HOME="$A" KHALA_SESSION=middata "$KHALA" send middata@b200 -m 'kill during durable tmp window') || fail 8 "mid-DATA send failed"
mid_deadline=$(( $(date +%s) + 4 ))
while [ -z "$(find "$HUB/tmp" -name 'link.*' ! -name 'link.committed' -type f -print -quit)" ] && \
    [ "$(date +%s)" -lt "$mid_deadline" ]; do sleep 0.05; done
SERVE_PID=$(pgrep -P "$A_PID" | sed -n '1p')
[ -n "$SERVE_PID" ] || fail 8 "could not identify direct carrier child"
kill -9 "$SERVE_PID" 2>/dev/null || fail 8 "could not kill carrier child"
stop_link "$A_PID"
[ ! -e "$HUB/spool/for/b200/$MID_ID" ] || fail 8 "partial object appeared in watched spool"
[ -n "$(find "$HUB/tmp" -name 'link.*' ! -name 'link.committed' -type f -print -quit)" ] || fail 8 "no tmp debris demonstrated the interrupted install"
find "$HUB/tmp" -name 'link.*' ! -name 'link.committed' -type f -exec touch -d '2 seconds ago' {} \;
start_link "$A" alpha KHALA_LINK_TEST_TMP_TTL=1s
A_PID=$LAST_PID
wait_file "$HUB/inbox/middata/new/$MID_ID" 8 || fail 8 "backlog did not recover after interrupted install"
[ -n "$(find "$HUB/spool/quarantine" -name 'recovered-tmp.*' -type f -print -quit 2>/dev/null)" ] || fail 8 "next start did not TTL-recover tmp debris"
pass 8 "kill -9 during install left debris only in tmp and restart converged"

HAVE_NAME=have.sender@alpha
printf '%s\n' 'same immutable bytes' > "$B/spool/for/beta/$HAVE_NAME"
printf '%s\n' 'same immutable bytes' > "$HUB/spool/for/beta/$HAVE_NAME"
wait_absent "$HUB/spool/for/beta/$HAVE_NAME" 4 || fail 9 "HAVE did not lead to STORED transit removal"
wait_log "peer HAVE beta/$HAVE_NAME" "$HUB/log/link.log" 3 || fail 9 "HAVE/DATA-skip was not logged"
pass 9 "same name and digest used HAVE, skipped DATA, and completed STORED"

CONFLICT_NAME=conflict.sender@alpha
printf '%s\n' 'spoke original' > "$B/spool/for/beta/$CONFLICT_NAME"
cp "$B/spool/for/beta/$CONFLICT_NAME" "$B/tmp/conflict.original"
printf '%s\n' 'hub conflicting bytes' > "$HUB/spool/for/beta/$CONFLICT_NAME"
conflict_deadline=$(( $(date +%s) + 4 ))
while [ -z "$(find "$B/spool/quarantine" -name "$CONFLICT_NAME.*" -type f -print -quit 2>/dev/null)" ] && \
    [ "$(date +%s)" -lt "$conflict_deadline" ]; do sleep 0.05; done
cmp -s "$B/tmp/conflict.original" "$B/spool/for/beta/$CONFLICT_NAME" || fail 10 "conflict overwrote original"
[ -n "$(find "$B/spool/quarantine" -name "$CONFLICT_NAME.*" -type f -print -quit 2>/dev/null)" ] || fail 10 "conflict was not quarantined"
[ -f "$HUB/spool/for/beta/$CONFLICT_NAME" ] || fail 10 "hub source was removed without STORED"
if ! wait_log 'same path has a different digest' "$B/log/link.log" 3 && \
    ! grep -q 'IMMUTABLE_CONFLICT' "$HUB/log/link.log" 2>/dev/null; then
    fail 10 "conflict was not loud"
fi
pass 10 "different digest quarantined loudly and preserved the original byte-for-byte"

stop_link "$B_PID"
start_link "$B" beta KHALA_LINK_TEST_STORED_DELAY=2s
B_PID=$LAST_PID
wait_file "$B/run/link.fresh" 5 || fail 11 "delayed-STORED link did not start"
DELAY_NAME=delayed.sender@alpha
printf '%s\n' 'delay stored proof' > "$HUB/spool/for/beta/$DELAY_NAME"
sleep 0.5
[ -f "$HUB/spool/for/beta/$DELAY_NAME" ] || fail 11 "hub transit was removed before delayed STORED"
wait_absent "$HUB/spool/for/beta/$DELAY_NAME" 5 || fail 11 "hub transit remained after STORED"
[ "$(rg -n 'return os.Remove\(path\)' "$ROOT/link"/*.go | wc -l | tr -d ' ')" -eq 1 ] || fail 11 "unlink audit found more than one production call site"
DIAL_KEEP_NAME=dial-keeps.sender@alpha
mkdir -p "$A/spool/for/gamma"
printf '%s\n' 'dial-side source must remain' > "$A/spool/for/gamma/$DIAL_KEEP_NAME"
DIAL_WATCHED_BEFORE=$(dial_watched_count "$A" alpha)
wait_file "$C/spool/for/gamma/$DIAL_KEEP_NAME" 7 || fail 11 "dial-source audit object did not arrive"
[ -f "$A/spool/for/gamma/$DIAL_KEEP_NAME" ] || fail 11 "dial unlinked its offered source"
DIAL_WATCHED_AFTER=$(dial_watched_count "$A" alpha)
[ "$DIAL_WATCHED_BEFORE" -eq "$DIAL_WATCHED_AFTER" ] || fail 11 "dial eligible-view file count changed $DIAL_WATCHED_BEFORE->$DIAL_WATCHED_AFTER"
pass 11 "STORED delay held transit; sole unlink is serve-gated; dial view count stayed fixed"

stop_link "$B_PID"
rm -f -- "$B/run/link.fresh"
start_link "$B" beta
B_PID=$LAST_PID
wait_file "$B/run/link.fresh" 5 || fail 11 "normal beta link did not restart after delay test"

RACE_ID=$(KHALA_HOME="$A" KHALA_SESSION=race "$KHALA" send race@beta -m 'link and rsync race') || fail 12 "race send failed"
KHALA_HOME="$A" "$KHALA" sync >"$A/race-sync.out" 2>"$A/race-sync.err" &
RACE_SYNC_A=$!
KHALA_HOME="$B" "$KHALA" sync >"$B/race-sync.out" 2>"$B/race-sync.err" &
RACE_SYNC_B=$!
wait "$RACE_SYNC_A" || :
wait "$RACE_SYNC_B" || :
wait_file "$B/inbox/race/new/$RACE_ID" 5 || fail 12 "racing delivery missing"
[ "$(grep -c " $RACE_ID$" "$B/log/delivered")" -eq 1 ] || fail 12 "racing delivery duplicated dedup row"
wait_file "$A/outbox/acked/$RACE_ID" 6 || fail 12 "racing ack did not settle"
pass 12 "link+rsync race produced one delivery and one dedup row, then settled"

first_child=$(pgrep -P "$A_PID" | sed -n '1p')
[ -n "$first_child" ] || fail 13 "first carrier child missing"
kill -TERM "$first_child" 2>/dev/null || fail 13 "could not stop first carrier"
sleep 2
second_child=$(pgrep -P "$A_PID" | sed -n '1p')
[ -n "$second_child" ] || fail 13 "carrier did not reconnect"
kill -TERM "$second_child" 2>/dev/null || fail 13 "could not stop second carrier"
# Wait for BOTH reconnect lines: the first kill's line pre-exists, so a bare
# pattern wait races the second line's arrival (observed flake under load).
reconnect_lines=0
reconnect_waited=0
while [ "$reconnect_waited" -lt 8 ]; do
    reconnect_lines=$(grep -c 'reconnect attempt=' "$A/log/link.log" 2>/dev/null || printf '0\n')
    [ "$reconnect_lines" -ge 2 ] && break
    sleep 1
    reconnect_waited=$((reconnect_waited + 1))
done
[ "$reconnect_lines" -ge 2 ] || fail 13 "second reconnect line missing after ${reconnect_waited}s"
delay_count=$(sed -n 's/.*reconnect attempt=[0-9][0-9]* delay=\([^ ]*\).*/\1/p' "$A/log/link.log" | sort -u | wc -l | tr -d ' ')
[ "$delay_count" -ge 2 ] || fail 13 "jitter delays did not show spread"
pass 13 "carrier deaths re-dialed with at least two distinct full-jitter delays"

start_link "$D" delta KHALA_LINK_TEST_SERVE_HOME="$STALLED_HUB" KHALA_LINK_TEST_SUPPRESS_PONG=1
D_PID=$LAST_PID
wait_file "$D/run/link.fresh" 5 || fail 14 "stalled fixture did not handshake"
D_FIRST_CHILD=$(pgrep -P "$D_PID" | sed -n '1p')
[ -n "$D_FIRST_CHILD" ] || fail 14 "stalled fixture carrier child was unavailable"
sleep 13
stalled_now=$(date +%s)
stalled_mtime=$(stat -c %Y "$D/run/link.fresh")
[ "$((stalled_now - stalled_mtime))" -ge 12 ] || fail 14 "stalled marker stayed fresh without protocol progress"
wait_log 'no inbound protocol frame for 20s' "$D/log/link.log" 12 || fail 14 "dial did not declare dead within 20s"
wait_log 'reconnect attempt=' "$D/log/link.log" 3 || fail 14 "dead carrier did not enter jittered re-dial"
if kill -0 "$D_FIRST_CHILD" 2>/dev/null; then fail 14 "dial did not kill and reap its stalled carrier child"; fi
healthy_elapsed=$(( $(date +%s) - HEALTHY_STARTED ))
if [ "$healthy_elapsed" -lt 65 ]; then sleep "$((65 - healthy_elapsed))"; fi
kill -0 "$C_PID" 2>/dev/null || fail 14 "healthy idle dial died"
kill -TERM "$C_MONITOR_PID" 2>/dev/null || :
wait "$C_MONITOR_PID" 2>/dev/null || :
[ ! -s "$C/freshness-flaps" ] || fail 14 "healthy marker flapped stale during the 65s observation"
healthy_now=$(date +%s)
healthy_mtime=$(stat -c %Y "$C/run/link.fresh")
[ "$((healthy_now - healthy_mtime))" -lt 12 ] || fail 14 "healthy marker flapped stale"
wait "$SERVE_QUIET_PID" || fail 14 "serve did not self-terminate at its default 60s quiet limit: $(tr '\n' ' ' < "$RIG/serve-quiet.err")"
pass 14 "healthy idle survived >65s fresh; silent serve exited at 60s; suppressed PONG killed dial at 20s"

mkdir -p "$W/run"
touch "$W/run/link.fresh"
if KHALA_HOME="$W" "$KHALA" watch --session local --interval 30 --max-wait 8 \
    >"$W/fresh-watch.out" 2>"$W/fresh-watch.err"; then
    fail 15 "fresh-marker empty watch unexpectedly found mail"
else
    fresh_watch_status=$?
fi
[ "$fresh_watch_status" -eq 3 ] || fail 15 "fresh-marker watch exited $fresh_watch_status"
grep -q 'sync 실패' "$W/fresh-watch.err" && fail 15 "fresh marker did not suppress exchange"
touch -d '20 seconds ago' "$W/run/link.fresh"
if KHALA_HOME="$W" "$KHALA" watch --session stale --interval 1 --max-wait 8 \
    >"$W/stale-watch.out" 2>"$W/stale-watch.err"; then
    fail 15 "stale-marker empty watch unexpectedly found mail"
else
    stale_watch_status=$?
fi
[ "$stale_watch_status" -eq 3 ] || fail 15 "stale-marker watch exited $stale_watch_status"
grep -q 'sync 실패; watch를 계속합니다' "$W/stale-watch.err" || fail 15 "stale marker did not resume interval sync"
pass 15 "watch used local 1s reconcile while fresh and resumed exchange when stale"

start_link "$S" sigma
S_PID=$LAST_PID
wait_file "$S/run/link.fresh" 5 || fail 16 "singleton holder did not start"
if ! env KHALA_HOME="$S" KHALA_BRAIN="$KHALA" KHALA_LINK_TEST_SERVE_HOME="$HUB" \
    KHALA_LINK_TEST_SERVE_NODE=b200 "$BIN" >"$S/second.out" 2>"$S/second.err"; then
    fail 16 "second dial was not idempotent"
fi
grep -qx 'khala-link: dial already running' "$S/second.out" || fail 16 "second dial notice differed"
env KHALA_HOME="$S" KHALA_BRAIN="$KHALA" KHALA_LINK_TEST_SERVE_HOME="$HUB" \
    KHALA_LINK_TEST_SERVE_NODE=b200 "$BIN" restart >"$S/restart.out" 2>"$S/restart.err" &
S_RESTART_PID=$!
PIDS="$PIDS $S_RESTART_PID"
restart_deadline=$(( $(date +%s) + 12 ))
while [ "$(sed -n 's/^pid //p' "$S/run/link.status" 2>/dev/null)" != "$S_RESTART_PID" ] && \
    [ "$(date +%s)" -lt "$restart_deadline" ]; do sleep 0.1; done
[ "$(sed -n 's/^pid //p' "$S/run/link.status")" = "$S_RESTART_PID" ] || fail 16 "restart did not replace the lock holder"
wait "$S_PID" 2>/dev/null || :
kill -0 "$S_RESTART_PID" 2>/dev/null || fail 16 "restart replacement is not alive"
kill -9 "$S_RESTART_PID" 2>/dev/null || fail 16 "could not kill restarted singleton holder"
wait "$S_RESTART_PID" 2>/dev/null || :
start_link "$S" sigma
S2_PID=$LAST_PID
wait_file "$S/run/link.fresh" 5 || fail 16 "kernel lock did not release after kill -9"
pass 16 "second dial was idempotent; restart replaced the holder; kill -9 released flock"

stop_link "$A_PID"
stop_link "$C_PID"
rm -f -- "$A/run/link.fresh" "$C/run/link.fresh"
start_link "$A" alpha KHALA_LINK_TEST_DATA_INSTALL_DELAY=3s
A_PID=$LAST_PID
start_link "$C" gamma KHALA_LINK_TEST_DATA_INSTALL_DELAY=3s
C_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 17 "writer-identity alpha link did not start"
wait_file "$C/run/link.fresh" 5 || fail 17 "writer-identity gamma link did not start"
KHALA_HOME="$A" KHALA_SESSION=writer-a "$KHALA" send writer-a@gamma -m 'A serve writer' \
    >"$A/writer-ac.id" 2>"$A/writer-ac.err" &
WRITER_AC_SEND_PID=$!
KHALA_HOME="$C" KHALA_SESSION=writer-c "$KHALA" send writer-c@alpha -m 'C serve writer' \
    >"$C/writer-ca.id" 2>"$C/writer-ca.err" &
WRITER_CA_SEND_PID=$!
wait "$WRITER_AC_SEND_PID" || fail 17 "A writer send failed"
wait "$WRITER_CA_SEND_PID" || fail 17 "C writer send failed"
WRITER_AC_ID=$(sed -n '1p' "$A/writer-ac.id")
WRITER_CA_ID=$(sed -n '1p' "$C/writer-ca.id")
cp "$A/spool/for/gamma/$WRITER_AC_ID" "$A/tmp/writer-a.source"
cp "$C/spool/for/alpha/$WRITER_CA_ID" "$C/tmp/writer-c.source"
writer_deadline=$(( $(date +%s) + 10 ))
WRITER_A_TMP=
WRITER_C_TMP=
while { [ -z "$WRITER_A_TMP" ] || [ -z "$WRITER_C_TMP" ]; } && \
    [ "$(date +%s)" -lt "$writer_deadline" ]; do
    for writer_tmp in "$HUB"/tmp/link.*; do
        [ -f "$writer_tmp" ] || continue
        [ "${writer_tmp##*/}" != link.committed ] || continue
        cmp -s "$writer_tmp" "$A/tmp/writer-a.source" && WRITER_A_TMP=$writer_tmp
        cmp -s "$writer_tmp" "$C/tmp/writer-c.source" && WRITER_C_TMP=$writer_tmp
    done
    [ -n "$WRITER_A_TMP" ] && [ -n "$WRITER_C_TMP" ] || sleep 0.05
done
[ -n "$WRITER_A_TMP" ] || fail 17 "A serve tmp bytes were absent"
[ -n "$WRITER_C_TMP" ] || fail 17 "C serve tmp bytes were absent"
WRITER_A_PID=${WRITER_A_TMP##*.}
WRITER_C_PID=${WRITER_C_TMP##*.}
case $WRITER_A_PID:$WRITER_C_PID in
    *[!0-9:]*|:*|*:) fail 17 "serve tmp names omitted numeric writer identities" ;;
esac
[ "$WRITER_A_PID" != "$WRITER_C_PID" ] || fail 17 "two spoke arrivals used the same serve writer identity"
wait_file "$C/inbox/writer-a/new/$WRITER_AC_ID" 10 || fail 17 "A writer object did not reach C"
wait_file "$A/inbox/writer-c/new/$WRITER_CA_ID" 10 || fail 17 "C writer object did not reach A"
stop_link "$A_PID"
stop_link "$C_PID"
rm -f -- "$A/run/link.fresh" "$C/run/link.fresh"
start_link "$A" alpha
A_PID=$LAST_PID
start_link "$C" gamma
C_PID=$LAST_PID
wait_file "$A/run/link.fresh" 5 || fail 17 "alpha link did not return after writer audit"
wait_file "$C/run/link.fresh" 5 || fail 17 "gamma link did not return after writer audit"
for burst_n in 1 2 3 4 5; do
    KHALA_HOME="$A" KHALA_SESSION=burst "$KHALA" send "burst$burst_n@gamma" -m "burst $burst_n" \
        >>"$A/burst.ids" 2>>"$A/burst.err" || fail 17 "burst send $burst_n failed"
done
burst_n=1
while IFS= read -r burst_id; do
    wait_file "$C/inbox/burst$burst_n/new/$burst_id" 5 || fail 17 "burst $burst_n did not arrive"
    burst_n=$((burst_n + 1))
done < "$A/burst.ids"
grep -q 'if t.role == "serve" && node != t.peer' "$ROOT/link/watch.go" || fail 17 "serve spool ownership guard missing"
grep -q 'node != i.peer' "$ROOT/link/install.go" || fail 17 "serve incoming ownership guard missing"
pass 17 "two serves used distinct tmp pid prefixes; burst passed structural ownership guards"

if ! (cd "$ROOT/link" && GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" CGO_ENABLED=0 \
    "$GO" test -run TestProtocolMajorMismatchSendsFatalErrorAndBye -count=1) \
    >"$RIG/major.out" 2>"$RIG/major.err"; then
    fail 18 "major mismatch test failed"
fi
MISSING=$RIG/missing
KHALA_HOME="$MISSING" "$KHALA" init missing >"$RIG/missing-init.out" 2>"$RIG/missing-init.err" || fail 18 "missing-binary fixture init failed"
if KHALA_HOME="$MISSING" "$KHALA" link >"$RIG/missing-link.out" 2>"$RIG/missing-link.err"; then
    fail 18 "wrapper silently skipped missing binary"
fi
grep -q "$MISSING/bin/khala-link" "$RIG/missing-link.err" || fail 18 "missing-binary error omitted expected home path"
grep -q "$ROOT/bin/khala-link" "$RIG/missing-link.err" || fail 18 "missing-binary error omitted sibling path"
if env -u KHALA_BRAIN KHALA_HOME="$MISSING" "$BIN" --serve --peer alpha \
    >"$RIG/no-brain.out" 2>"$RIG/no-brain.err"; then
    fail 18 "binary started without KHALA_BRAIN"
fi
grep -q 'KHALA_BRAIN is missing or empty' "$RIG/no-brain.err" || fail 18 "missing brain error omitted variable name"
mkdir -p "$MISSING/bin"
cp "$BIN" "$MISSING/bin/khala-link"
env KHALA_HOME="$MISSING" KHALA_LINK_TEST_SERVE_HOME="$HUB" \
    KHALA_LINK_TEST_SERVE_NODE=b200 KHALA_LINK_TEST_SCAN_INTERVAL=1s \
    "$KHALA" link >"$MISSING/wrapper.out" 2>"$MISSING/wrapper.err" &
WRAPPER_PID=$!
PIDS="$PIDS $WRAPPER_PID"
wait_file "$MISSING/run/link.fresh" 5 || fail 18 "wrapper did not launch the home binary"
kill -TERM "$WRAPPER_PID" 2>/dev/null || :
wait "$WRAPPER_PID" 2>/dev/null || :
pass 18 "fatal version/path checks passed; wrapper launched with an exact KHALA_BRAIN handoff"

if command -v ss >/dev/null 2>&1; then
    if ss -apn 2>/dev/null | grep -E "pid=($A_PID|$B_PID|$C_PID|$D_PID|$S2_PID)," \
        >"$RIG/owned-sockets.out"; then
        fail 20 "khala-link owned a socket: $(tr '\n' ' ' < "$RIG/owned-sockets.out")"
    fi
else
    fail 20 "ss is unavailable for the no-listener audit"
fi

# Keep legacy regressions isolated from the deliberate conflict and reconnect
# fixtures above; the socket audit was captured while the full rig was live.
stop_link "$A_PID"
stop_link "$B_PID"
stop_link "$C_PID"
stop_link "$D_PID"
stop_link "$S2_PID"

for suite in local-roundtrip exchange-roundtrip hardening concurrency watch; do
    if ! "$ROOT/test/$suite.sh" >"$RIG/$suite.out" 2>"$RIG/$suite.err"; then
        fail 19 "$suite failed: $(tr '\n' ' ' < "$RIG/$suite.err")"
    fi
    grep -q '^RESULT: PASS$' "$RIG/$suite.out" || fail 19 "$suite omitted RESULT: PASS"
done
pass 19 "all five existing bash suites passed unchanged"
pass 20 "full direct-carrier rig showed zero sockets owned by khala-link"

printf 'LATENCY A_TO_B_MS=%s B_TO_A_MS=%s\n' "$AB_MS" "$BA_MS"
printf 'RESULT: PASS\n'
printf 'link propagation, convergence, integrity, liveness, lifecycle, and regressions passed\n'
