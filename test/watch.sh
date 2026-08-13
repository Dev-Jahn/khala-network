#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA="$ROOT/bin/khala"
HOME_LOCAL="$HOME/.khala-watch-local-$$"
HOME_A="$HOME/.khala-watch-alpha-$$"
HOME_M="$HOME/.khala-watch-mailbox-$$"
HOME_BROKEN="$HOME/.khala-watch-broken-$$"
HOME_MISSING="$HOME/.khala-watch-missing-$$"
BOGUS="$HOME/.khala-watch-bogus-$$"
TEST_DIR="$HOME/.khala-watch-test-$$"
ACTIVE_PID=

cleanup() {
    if [ -n "$ACTIVE_PID" ]; then
        if wait "$ACTIVE_PID" 2>/dev/null; then
            :
        fi
    fi
    rm -rf -- "$HOME_LOCAL" "$HOME_A" "$HOME_M" "$HOME_BROKEN" \
        "$HOME_MISSING" "$BOGUS" "$TEST_DIR"
}

dump_layout() {
    for dump_home in "$HOME_LOCAL" "$HOME_A" "$HOME_M" "$HOME_BROKEN"; do
        if [ -d "$dump_home" ]; then
            find "$dump_home" -print | sort >&2
        else
            printf '%s\n' "$dump_home (missing)" >&2
        fi
    done
}

fail() {
    step=$1
    shift
    printf 'FAIL %s — %s\n' "$step" "$*" >&2
    dump_layout
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

write_alpha_config() {
    config_mode=$1
    config_tmp="$HOME_A/tmp/config.watch.$$"
    if [ "$config_mode" = working ]; then
        config_endpoint=$HOME_M
    else
        config_endpoint=$BOGUS
    fi
    if ! {
        printf 'self alpha\n'
        printf 'peer alpha %s\n' "$HOME_A"
        printf 'peer b200 %s\n' "$config_endpoint"
        printf 'mailbox b200\n'
        printf 'ttl 120\n'
    } > "$config_tmp"; then
        return 1
    fi
    mv "$config_tmp" "$HOME_A/config"
}

mkdir -p -- "$TEST_DIR"
trap cleanup EXIT HUP INT TERM

if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" init alpha \
    >"$TEST_DIR/init-local.out" 2>"$TEST_DIR/init-local.err"; then
    fail 1 "local init failed: $(tr '\n' ' ' < "$TEST_DIR/init-local.err")"
fi

# 1. Mail already in new/ wakes immediately and lists count, Id, and From.
if ! immediate_id=$(KHALA_HOME="$HOME_LOCAL" KHALA_SESSION=sender \
    "$KHALA" send w@alpha -m "already here" 2>"$TEST_DIR/immediate-send.err"); then
    fail 1 "immediate send failed: $(tr '\n' ' ' < "$TEST_DIR/immediate-send.err")"
fi
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" sync \
    >"$TEST_DIR/immediate-sync.out" 2>"$TEST_DIR/immediate-sync.err"; then
    fail 1 "immediate sync failed: $(tr '\n' ' ' < "$TEST_DIR/immediate-sync.err")"
fi
immediate_started=$(date +%s) || fail 1 "could not read start time"
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session w --interval 1 --max-wait 10 \
    >"$TEST_DIR/immediate-watch.out" 2>"$TEST_DIR/immediate-watch.err"; then
    fail 1 "immediate watch failed: $(tr '\n' ' ' < "$TEST_DIR/immediate-watch.err")"
fi
immediate_ended=$(date +%s) || fail 1 "could not read end time"
[ "$((immediate_ended - immediate_started))" -le 1 ] || fail 1 "pre-delivered mail did not wake immediately"
grep -qx '1' "$TEST_DIR/immediate-watch.out" || fail 1 "watch did not print the new-mail count"
immediate_line=$(printf '%s\t%s' "$immediate_id" 'sender@alpha')
grep -Fqx "$immediate_line" "$TEST_DIR/immediate-watch.out" || fail 1 "watch did not list Id and From"
pass 1 "pre-delivered mail wakes immediately with count, Id, and From"

# 2. A watch advertises its ear without creating a heartbeat, then cleans up.
arrival_started=$(date +%s) || fail 2 "could not read arrival start time"
KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session w2 --interval 1 --max-wait 8 \
    >"$TEST_DIR/arrival-watch.out" 2>"$TEST_DIR/arrival-watch.err" &
ACTIVE_PID=$!
sleep 2
[ ! -e "$HOME_LOCAL/presence/w2@alpha" ] || fail 2 "watch created a heartbeat"
arrival_marker="$HOME_LOCAL/presence/w2@alpha.watching"
[ -f "$arrival_marker" ] || fail 2 "watching marker was not created"
arrival_marker_epoch=$(sed -n '1p' "$arrival_marker")
case "$arrival_marker_epoch" in
    ''|*[!0-9]*) fail 2 "watching marker epoch is not an integer" ;;
esac
[ "$(sed -n '2p' "$arrival_marker")" = 1 ] || fail 2 "watching marker interval is wrong"
[ "$(wc -l < "$arrival_marker" | tr -d ' ')" -eq 2 ] || fail 2 "watching marker is not two lines"
if ! arrival_id=$(KHALA_HOME="$HOME_LOCAL" KHALA_SESSION=other \
    "$KHALA" send w2@alpha -m "arrived later" 2>"$TEST_DIR/arrival-send.err"); then
    fail 2 "arrival send failed: $(tr '\n' ' ' < "$TEST_DIR/arrival-send.err")"
fi
if wait "$ACTIVE_PID"; then
    arrival_status=0
else
    arrival_status=$?
fi
ACTIVE_PID=
[ "$arrival_status" -eq 0 ] || fail 2 "background watch exited $arrival_status"
arrival_ended=$(date +%s) || fail 2 "could not read arrival end time"
[ "$((arrival_ended - arrival_started))" -le 5 ] || fail 2 "arrival took more than about two intervals"
arrival_line=$(printf '%s\t%s' "$arrival_id" 'other@alpha')
grep -Fqx "$arrival_line" "$TEST_DIR/arrival-watch.out" || fail 2 "arrival output omitted Id or From"
[ ! -e "$HOME_LOCAL/presence/w2@alpha" ] || fail 2 "watch exit created a heartbeat"
[ ! -e "$arrival_marker" ] || fail 2 "watching marker remained after mail wake"
pass 2 "watch advertises only its ear and removes the marker after mail wake"

# 3. An empty inbox reaches the distinct timeout status with no stdout.
if KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session empty --interval 1 --max-wait 3 \
    >"$TEST_DIR/timeout.out" 2>"$TEST_DIR/timeout.err"; then
    timeout_status=0
else
    timeout_status=$?
fi
[ "$timeout_status" -eq 3 ] || fail 3 "timeout exited $timeout_status instead of 3"
[ ! -s "$TEST_DIR/timeout.out" ] || fail 3 "timeout wrote to stdout"
grep -q '기한 내 새 편지 없음' "$TEST_DIR/timeout.err" || fail 3 "timeout note is missing"
[ ! -e "$HOME_LOCAL/presence/empty@alpha.watching" ] || fail 3 "timeout left a watching marker"
pass 3 "empty watch exits 3 and removes its marker"

# 4. TERM stops a watch and removes its marker.
KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session terminated --interval 1 --max-wait 20 \
    >"$TEST_DIR/term.out" 2>"$TEST_DIR/term.err" &
ACTIVE_PID=$!
sleep 2
[ -f "$HOME_LOCAL/presence/terminated@alpha.watching" ] || fail 4 "TERM fixture marker was not created"
kill -TERM "$ACTIVE_PID" || fail 4 "could not send TERM to watch"
if wait "$ACTIVE_PID"; then
    term_status=0
else
    term_status=$?
fi
ACTIVE_PID=
[ "$term_status" -ne 0 ] || fail 4 "TERM watch exited successfully"
[ ! -e "$HOME_LOCAL/presence/terminated@alpha.watching" ] || fail 4 "TERM left a watching marker"
pass 4 "TERM removes the watching marker"

# 5. Freshness, malformed isolation, and watching-only rows are honest.
presence_now=$(date +%s) || fail 5 "could not read presence time"
printf '%s\n%s\n' "$((presence_now - 500))" 1 > "$HOME_LOCAL/presence/staleonly@alpha.watching"
printf '%s\n%s\n' "$presence_now" 1 > "$HOME_LOCAL/presence/freshonly@alpha.watching"
printf '%s\n' broken > "$HOME_LOCAL/presence/malformed@alpha.watching"
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" presence \
    >"$TEST_DIR/watching-presence.out" 2>"$TEST_DIR/watching-presence.err"; then
    fail 5 "presence rejected watching markers: $(tr '\n' ' ' < "$TEST_DIR/watching-presence.err")"
fi
stale_line=$(printf 'staleonly@alpha\tunknown\t-\t-')
fresh_line=$(printf 'freshonly@alpha\tunknown\t-\tyes')
malformed_line=$(printf 'malformed@alpha\tunknown\t-\t-')
grep -Fqx "$stale_line" "$TEST_DIR/watching-presence.out" || fail 5 "stale marker was not shown as unarmed"
grep -Fqx "$fresh_line" "$TEST_DIR/watching-presence.out" || fail 5 "fresh watching-only row is missing"
grep -Fqx "$malformed_line" "$TEST_DIR/watching-presence.out" || fail 5 "malformed marker row is missing"
[ "$(grep -c 'malformed@alpha.watching: 잘못된 watching marker' "$TEST_DIR/watching-presence.err")" -eq 1 ] || \
    fail 5 "malformed marker did not produce exactly one note"
grep -q 'watching = 귀 열림 (armed watch)' "$TEST_DIR/watching-presence.out" || fail 5 "watching honesty note is missing"
pass 5 "presence applies marker freshness and isolates malformed content"

# 6. Stale/malformed marker garbage never affects local routing.
if ! routed_id=$(KHALA_HOME="$HOME_LOCAL" KHALA_SESSION=route-sender \
    "$KHALA" send routed@alpha -m "marker-independent" 2>"$TEST_DIR/routed-send.err"); then
    fail 6 "routing fixture send failed: $(tr '\n' ' ' < "$TEST_DIR/routed-send.err")"
fi
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" sync \
    >"$TEST_DIR/routed-sync.out" 2>"$TEST_DIR/routed-sync.err"; then
    fail 6 "routing fixture sync failed: $(tr '\n' ' ' < "$TEST_DIR/routed-sync.err")"
fi
if ! KHALA_HOME="$HOME_LOCAL" KHALA_SESSION=routed "$KHALA" inbox \
    >"$TEST_DIR/routed-inbox.out" 2>"$TEST_DIR/routed-inbox.err"; then
    fail 6 "routing fixture inbox failed: $(tr '\n' ' ' < "$TEST_DIR/routed-inbox.err")"
fi
grep -Fq "$routed_id" "$TEST_DIR/routed-inbox.out" || fail 6 "marker garbage blocked delivery"
mv "$HOME_LOCAL/presence" "$TEST_DIR/presence.saved" || fail 6 "could not move presence aside"
: > "$HOME_LOCAL/presence" || fail 6 "could not break presence path"
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session routed --interval 1 --max-wait 2 \
    >"$TEST_DIR/broken-presence-watch.out" 2>"$TEST_DIR/broken-presence-watch.err"; then
    fail 6 "broken presence path killed the ear: $(tr '\n' ' ' < "$TEST_DIR/broken-presence-watch.err")"
fi
grep -Fq "$routed_id" "$TEST_DIR/broken-presence-watch.out" || fail 6 "broken presence path blocked wake"
grep -q 'watching marker를 갱신하지 못했습니다; watch를 계속합니다' \
    "$TEST_DIR/broken-presence-watch.err" || fail 6 "marker write failure was silent"
rm -f "$HOME_LOCAL/presence" || fail 6 "could not remove broken presence path"
mv "$TEST_DIR/presence.saved" "$HOME_LOCAL/presence" || fail 6 "could not restore presence"
pass 6 "marker garbage and marker-write failure have no routing effect"

# 7. A non-mailbox watcher pulls its own mail from an absolute-path mailbox.
if ! KHALA_HOME="$HOME_A" "$KHALA" init alpha \
    >"$TEST_DIR/init-alpha.out" 2>"$TEST_DIR/init-alpha.err"; then
    fail 7 "alpha init failed: $(tr '\n' ' ' < "$TEST_DIR/init-alpha.err")"
fi
if ! KHALA_HOME="$HOME_M" "$KHALA" init b200 \
    >"$TEST_DIR/init-mailbox.out" 2>"$TEST_DIR/init-mailbox.err"; then
    fail 7 "mailbox init failed: $(tr '\n' ' ' < "$TEST_DIR/init-mailbox.err")"
fi
write_alpha_config working || fail 7 "alpha config setup failed"
if ! cross_id=$(KHALA_HOME="$HOME_M" KHALA_SESSION=remote \
    "$KHALA" send crosswatch@alpha -m "from mailbox" 2>"$TEST_DIR/cross-send.err"); then
    fail 7 "cross send failed: $(tr '\n' ' ' < "$TEST_DIR/cross-send.err")"
fi
if ! KHALA_HOME="$HOME_M" "$KHALA" sync \
    >"$TEST_DIR/cross-mailbox-sync.out" 2>"$TEST_DIR/cross-mailbox-sync.err"; then
    fail 7 "mailbox sync failed: $(tr '\n' ' ' < "$TEST_DIR/cross-mailbox-sync.err")"
fi
[ -f "$HOME_M/spool/for/alpha/$cross_id" ] || fail 7 "mail did not reach the mailbox spool"
if ! KHALA_HOME="$HOME_A" "$KHALA" watch --session crosswatch --interval 1 --max-wait 5 \
    >"$TEST_DIR/cross-watch.out" 2>"$TEST_DIR/cross-watch.err"; then
    fail 7 "cross watch failed: $(tr '\n' ' ' < "$TEST_DIR/cross-watch.err")"
fi
cross_line=$(printf '%s\t%s' "$cross_id" 'remote@b200')
grep -Fqx "$cross_line" "$TEST_DIR/cross-watch.out" || fail 7 "pulled mail was not reported"
[ -f "$HOME_A/inbox/crosswatch/new/$cross_id" ] || fail 7 "watch did not pull and deliver mail"
pass 7 "non-mailbox watch pulls from the mailbox without manual local sync"

# 8. Watching markers ride the two-home presence exchange.
KHALA_HOME="$HOME_A" "$KHALA" watch --session exchange-ear --interval 1 --max-wait 20 \
    >"$TEST_DIR/exchange-watch.out" 2>"$TEST_DIR/exchange-watch.err" &
ACTIVE_PID=$!
sleep 2
[ -f "$HOME_A/presence/exchange-ear@alpha.watching" ] || fail 8 "exchange watch marker was not created"
if ! KHALA_HOME="$HOME_A" "$KHALA" sync \
    >"$TEST_DIR/exchange-sync.out" 2>"$TEST_DIR/exchange-sync.err"; then
    fail 8 "alpha presence sync failed: $(tr '\n' ' ' < "$TEST_DIR/exchange-sync.err")"
fi
if ! KHALA_HOME="$HOME_M" "$KHALA" presence \
    >"$TEST_DIR/exchange-presence.out" 2>"$TEST_DIR/exchange-presence.err"; then
    fail 8 "b200 presence failed: $(tr '\n' ' ' < "$TEST_DIR/exchange-presence.err")"
fi
exchange_line=$(printf 'exchange-ear@alpha\tunknown\t-\tyes')
grep -Fqx "$exchange_line" "$TEST_DIR/exchange-presence.out" || fail 8 "remote watching marker was not displayed"
kill -TERM "$ACTIVE_PID" || fail 8 "could not stop exchange watch"
if wait "$ACTIVE_PID"; then
    exchange_watch_status=0
else
    exchange_watch_status=$?
fi
ACTIVE_PID=
[ "$exchange_watch_status" -ne 0 ] || fail 8 "exchange watch ignored TERM"
[ ! -e "$HOME_A/presence/exchange-ear@alpha.watching" ] || fail 8 "exchange watch left its local marker"
pass 8 "watching markers ride the two-home presence exchange"

# 9. Repeated mailbox failures stay loud but do not abort the watcher.
write_alpha_config broken || fail 9 "broken mailbox config setup failed"
if KHALA_HOME="$HOME_A" "$KHALA" watch --session resilient --interval 1 --max-wait 4 \
    >"$TEST_DIR/resilient.out" 2>"$TEST_DIR/resilient.err"; then
    resilient_status=0
else
    resilient_status=$?
fi
[ "$resilient_status" -eq 3 ] || fail 9 "sync failure ended watch with $resilient_status"
[ ! -s "$TEST_DIR/resilient.out" ] || fail 9 "failed-sync timeout wrote to stdout"
failure_count=$(grep -c 'sync 실패; watch를 계속합니다' "$TEST_DIR/resilient.err")
[ "$failure_count" -ge 2 ] || fail 9 "sync failures were not reported per loop"
grep -q '기한 내 새 편지 없음' "$TEST_DIR/resilient.err" || fail 9 "resilient watch did not time out normally"
pass 9 "sync failures are reported while watch keeps looping"

# 10. Missing and structurally broken configs fail fast; bad intervals are usage errors.
if KHALA_HOME="$HOME_MISSING" "$KHALA" watch --session missing --interval 1 --max-wait 1 \
    >"$TEST_DIR/missing.out" 2>"$TEST_DIR/missing.err"; then
    fail 10 "watch without config unexpectedly succeeded"
fi
grep -q 'khala init 먼저' "$TEST_DIR/missing.err" || fail 10 "missing config guidance is absent"
if KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session invalid --interval 0 --max-wait 1 \
    >"$TEST_DIR/zero.out" 2>"$TEST_DIR/zero.err"; then
    fail 10 "zero interval unexpectedly succeeded"
fi
if KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session invalid --interval nope --max-wait 1 \
    >"$TEST_DIR/noninteger.out" 2>"$TEST_DIR/noninteger.err"; then
    fail 10 "non-integer interval unexpectedly succeeded"
fi
if ! KHALA_HOME="$HOME_BROKEN" "$KHALA" init broken \
    >"$TEST_DIR/init-broken.out" 2>"$TEST_DIR/init-broken.err"; then
    fail 10 "broken-config home init failed"
fi
printf '%s\n' 'self broken' > "$HOME_BROKEN/config"
if KHALA_HOME="$HOME_BROKEN" "$KHALA" watch --session invalid --interval 1 --max-wait 1 \
    >"$TEST_DIR/broken.out" 2>"$TEST_DIR/broken.err"; then
    fail 10 "structurally broken config unexpectedly succeeded"
fi
grep -q 'khala init 먼저' "$TEST_DIR/broken.err" || fail 10 "broken config guidance is absent"
pass 10 "configuration and interval errors exit 1 with guidance"

# 11. A second arm is idempotent and does not create another watcher.
KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session singleton --interval 1 --max-wait 10 \
    >"$TEST_DIR/singleton-first.out" 2>"$TEST_DIR/singleton-first.err" &
ACTIVE_PID=$!
sleep 2
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session singleton --interval 1 --max-wait 10 \
    >"$TEST_DIR/singleton-second.out" 2>"$TEST_DIR/singleton-second.err"; then
    fail 11 "second singleton arm did not exit 0"
fi
grep -Eq '^이미 감시 중: singleton \(pid [0-9]+\)$' "$TEST_DIR/singleton-second.out" || \
    fail 11 "second arm did not report the running watcher"
[ ! -s "$TEST_DIR/singleton-second.err" ] || fail 11 "second arm wrote unexpected stderr"
[ -d "$HOME_LOCAL/run/watch.singleton.lock.d" ] || fail 11 "singleton lock is missing"
if ! singleton_id=$(KHALA_HOME="$HOME_LOCAL" KHALA_SESSION=sender \
    "$KHALA" send singleton@alpha -m "wake the sole watcher" 2>"$TEST_DIR/singleton-send.err"); then
    fail 11 "singleton fixture send failed: $(tr '\n' ' ' < "$TEST_DIR/singleton-send.err")"
fi
if ! wait "$ACTIVE_PID"; then
    fail 11 "first singleton watcher did not exit successfully"
fi
ACTIVE_PID=
grep -Fq "$singleton_id" "$TEST_DIR/singleton-first.out" || fail 11 "sole watcher missed the mail"
[ ! -e "$HOME_LOCAL/presence/singleton@alpha.watching" ] || fail 11 "singleton marker remained"
[ ! -e "$HOME_LOCAL/run/watch.singleton.lock.d" ] || fail 11 "singleton lock remained"
pass 11 "a second arm exits idempotently and the sole watcher cleans up"

# 12. A stale singleton lock is reclaimed using its recorded interval.
if ! stale_watch_id=$(KHALA_HOME="$HOME_LOCAL" KHALA_SESSION=sender \
    "$KHALA" send stale-watch@alpha -m "mail behind stale lock" 2>"$TEST_DIR/stale-watch-send.err"); then
    fail 12 "stale watch fixture send failed"
fi
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" reconcile \
    >"$TEST_DIR/stale-watch-reconcile.out" 2>"$TEST_DIR/stale-watch-reconcile.err"; then
    fail 12 "stale watch fixture reconcile failed"
fi
stale_watch_now=$(date +%s) || fail 12 "could not read stale watch time"
mkdir "$HOME_LOCAL/run/watch.stale-watch.lock.d" || fail 12 "could not create stale watch lock"
printf '%s\npid 999 watch\n1\n' "$((stale_watch_now - 300))" \
    > "$HOME_LOCAL/run/watch.stale-watch.lock.d/owner"
if ! KHALA_HOME="$HOME_LOCAL" "$KHALA" watch --session stale-watch --interval 1 --max-wait 3 \
    >"$TEST_DIR/stale-watch.out" 2>"$TEST_DIR/stale-watch.err"; then
    fail 12 "watch did not proceed after stale singleton reclaim"
fi
grep -q 'reclaimed stale watch lock from pid 999' "$TEST_DIR/stale-watch.err" || \
    fail 12 "stale singleton reclaim was not loud"
grep -Fq "$stale_watch_id" "$TEST_DIR/stale-watch.out" || fail 12 "reclaimed watch missed staged mail"
[ ! -e "$HOME_LOCAL/run/watch.stale-watch.lock.d" ] || fail 12 "reclaimed watch lock remained"
pass 12 "a stale singleton lock is reclaimed loudly and watch proceeds"

# 13. All existing suites remain green without modification.
for regression_suite in local-roundtrip exchange-roundtrip hardening; do
    if ! bash "$ROOT/test/$regression_suite.sh" \
        >"$TEST_DIR/$regression_suite.out" 2>"$TEST_DIR/$regression_suite.err"; then
        fail 13 "$regression_suite regression failed: $(tr '\n' ' ' < "$TEST_DIR/$regression_suite.err")"
    fi
    grep -q '^RESULT: PASS$' "$TEST_DIR/$regression_suite.out" || \
        fail 13 "$regression_suite did not report PASS"
done
pass 13 "all three existing suites pass unchanged"

printf 'RESULT: PASS\n'
printf 'watch honesty, singleton lifecycle, exchange, routing isolation, and regressions passed\n'
