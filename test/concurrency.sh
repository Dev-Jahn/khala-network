#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA="$ROOT/bin/khala"
TEST_DIR="$HOME/.khala-concurrency-test-$$"
ECHO_HOME="$HOME/.khala-concurrency-echo-$$"
ECHO_HUB="$HOME/.khala-concurrency-hub-$$"
MAIN_HOME="$HOME/.khala-concurrency-main-$$"
REMOTE_HOME="$HOME/.khala-concurrency-remote-$$"
NETWORK_HOME="$HOME/.khala-concurrency-network-$$"
LOCK_HOME="$HOME/.khala-concurrency-lock-$$"
NETWORK_PID=

cleanup() {
    if [ -n "$NETWORK_PID" ]; then
        kill -TERM "$NETWORK_PID" 2>/dev/null || :
        wait "$NETWORK_PID" 2>/dev/null || :
    fi
    rm -rf -- "$TEST_DIR" "$ECHO_HOME" "$ECHO_HUB" "$MAIN_HOME" \
        "$REMOTE_HOME" "$NETWORK_HOME" "$LOCK_HOME"
}

dump_layout() {
    for dump_home in "$ECHO_HOME" "$ECHO_HUB" "$MAIN_HOME" \
        "$REMOTE_HOME" "$NETWORK_HOME" "$LOCK_HOME"; do
        if [ -d "$dump_home" ]; then
            find "$dump_home" -print | sort >&2
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

count_files() {
    count_total=0
    for count_path in "$@"; do
        [ -d "$count_path" ] || continue
        for count_file in "$count_path"/*; do
            [ -f "$count_file" ] || continue
            count_total=$((count_total + 1))
        done
    done
    printf '%s\n' "$count_total"
}

remote_message() {
    remote_target=$1
    remote_body=$2
    KHALA_HOME="$REMOTE_HOME" KHALA_SESSION=remote \
        "$KHALA" send "$remote_target@alpha" -m "$remote_body"
}

mkdir -p -- "$TEST_DIR"
trap cleanup EXIT HUP INT TERM

# 1. spool/for/self is delivered locally and never reflected to the mailbox.
KHALA_HOME="$ECHO_HOME" "$KHALA" init alpha >"$TEST_DIR/echo-init.out" 2>"$TEST_DIR/echo-init.err" || \
    fail 1 "alpha init failed"
KHALA_HOME="$ECHO_HUB" "$KHALA" init b200 >"$TEST_DIR/hub-init.out" 2>"$TEST_DIR/hub-init.err" || \
    fail 1 "hub init failed"
{
    printf 'self alpha\n'
    printf 'peer alpha %s\n' "$ECHO_HOME"
    printf 'peer b200 %s\n' "$ECHO_HUB"
    printf 'mailbox b200\n'
    printf 'ttl 120\n'
} > "$ECHO_HOME/tmp/config.concurrency.$$"
mv "$ECHO_HOME/tmp/config.concurrency.$$" "$ECHO_HOME/config"
echo_id=$(KHALA_HOME="$ECHO_HOME" KHALA_SESSION=sender \
    "$KHALA" send local@alpha -m "never echo upstream") || fail 1 "echo fixture send failed"
KHALA_HOME="$ECHO_HOME" "$KHALA" sync >"$TEST_DIR/echo-sync.out" 2>"$TEST_DIR/echo-sync.err" || \
    fail 1 "echo fixture sync failed: $(tr '\n' ' ' < "$TEST_DIR/echo-sync.err")"
[ -f "$ECHO_HOME/inbox/local/new/$echo_id" ] || fail 1 "self-spool mail was not delivered locally"
[ "$(count_files "$ECHO_HUB/spool/for/alpha")" -eq 0 ] || fail 1 "mailbox received self-spool mail"
pass 1 "self-spool mail is delivered locally without upstream echo"

KHALA_HOME="$MAIN_HOME" "$KHALA" init alpha >"$TEST_DIR/main-init.out" 2>"$TEST_DIR/main-init.err" || \
    fail 2 "main init failed"
KHALA_HOME="$REMOTE_HOME" "$KHALA" init b200 >"$TEST_DIR/remote-init.out" 2>"$TEST_DIR/remote-init.err" || \
    fail 2 "remote init failed"

# 2. Two syncs and a drain loop preserve ten distinct messages exactly once.
: > "$TEST_DIR/concurrent.ids"
concurrent_i=1
while [ "$concurrent_i" -le 10 ]; do
    concurrent_id=$(KHALA_HOME="$MAIN_HOME" KHALA_SESSION=source \
        "$KHALA" send target@alpha -m "concurrent $concurrent_i") || fail 2 "send $concurrent_i failed"
    printf '%s\n' "$concurrent_id" >> "$TEST_DIR/concurrent.ids"
    concurrent_i=$((concurrent_i + 1))
done
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/sync-a.out" 2>"$TEST_DIR/sync-a.err" &
sync_a_pid=$!
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/sync-b.out" 2>"$TEST_DIR/sync-b.err" &
sync_b_pid=$!
(
    drain_i=1
    while [ "$drain_i" -le 4 ]; do
        KHALA_HOME="$MAIN_HOME" KHALA_SESSION=target "$KHALA" inbox --drain \
            >"$TEST_DIR/drain-$drain_i.out" 2>"$TEST_DIR/drain-$drain_i.err" || exit 1
        sleep 1
        drain_i=$((drain_i + 1))
    done
) &
drain_pid=$!
wait "$sync_a_pid" || fail 2 "first concurrent sync failed"
wait "$sync_b_pid" || fail 2 "second concurrent sync failed"
wait "$drain_pid" || fail 2 "concurrent drain loop failed"
KHALA_HOME="$MAIN_HOME" "$KHALA" reconcile >"$TEST_DIR/quiesce.out" 2>"$TEST_DIR/quiesce.err" || \
    fail 2 "quiescing reconcile failed"
[ "$(count_files "$MAIN_HOME/inbox/target/new" "$MAIN_HOME/inbox/target/cur")" -eq 10 ] || \
    fail 2 "new+cur does not contain exactly ten messages"
for concurrent_dir in "$MAIN_HOME/inbox/target/new" "$MAIN_HOME/inbox/target/cur"; do
    for concurrent_file in "$concurrent_dir"/*; do
        [ -f "$concurrent_file" ] || continue
        basename "$concurrent_file"
    done
done | sort > "$TEST_DIR/inbox.ids"
uniq -d "$TEST_DIR/inbox.ids" > "$TEST_DIR/inbox.duplicates"
[ ! -s "$TEST_DIR/inbox.duplicates" ] || fail 2 "duplicate inbox ids were found"
while IFS= read -r concurrent_id; do
    [ "$(grep -c " $concurrent_id$" "$MAIN_HOME/log/delivered")" -eq 1 ] || \
        fail 2 "$concurrent_id is missing or duplicated in delivered log"
done < "$TEST_DIR/concurrent.ids"
[ "$(wc -l < "$MAIN_HOME/log/delivered" | tr -d ' ')" -eq 10 ] || fail 2 "delivered log has torn or extra rows"
pass 2 "concurrent syncs and drain preserve ten messages and log rows exactly once"

# 3. Inbox presence repairs the log and prevents redelivery for new and cur.
crash_new_id=$(remote_message crashnew "copy then crash in new") || fail 3 "new crash fixture send failed"
mkdir -p "$MAIN_HOME/inbox/crashnew/new" "$MAIN_HOME/inbox/crashnew/cur"
cp "$REMOTE_HOME/outbox/new/$crash_new_id" "$MAIN_HOME/spool/for/alpha/$crash_new_id"
cp "$REMOTE_HOME/outbox/new/$crash_new_id" "$MAIN_HOME/inbox/crashnew/new/$crash_new_id"
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/crash-new.out" 2>"$TEST_DIR/crash-new.err" || \
    fail 3 "new crash recovery failed"
[ "$(count_files "$MAIN_HOME/inbox/crashnew/new")" -eq 1 ] || fail 3 "new crash copy was duplicated"
grep -q " $crash_new_id$" "$MAIN_HOME/log/delivered" || fail 3 "new crash log was not repaired"
[ ! -e "$MAIN_HOME/spool/for/alpha/$crash_new_id" ] || fail 3 "new crash spool copy remained"
grep -l "^Refs: $crash_new_id$" "$MAIN_HOME"/spool/for/b200/* >/dev/null 2>&1 || \
    fail 3 "new crash ack was not regenerated"

crash_cur_id=$(remote_message crashcur "copy then crash after drain") || fail 3 "cur crash fixture send failed"
mkdir -p "$MAIN_HOME/inbox/crashcur/new" "$MAIN_HOME/inbox/crashcur/cur"
cp "$REMOTE_HOME/outbox/new/$crash_cur_id" "$MAIN_HOME/spool/for/alpha/$crash_cur_id"
cp "$REMOTE_HOME/outbox/new/$crash_cur_id" "$MAIN_HOME/inbox/crashcur/cur/$crash_cur_id"
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/crash-cur.out" 2>"$TEST_DIR/crash-cur.err" || \
    fail 3 "cur crash recovery failed"
[ -f "$MAIN_HOME/inbox/crashcur/cur/$crash_cur_id" ] || fail 3 "cur crash copy moved or vanished"
[ "$(count_files "$MAIN_HOME/inbox/crashcur/new")" -eq 0 ] || fail 3 "cur crash copy was redelivered to new"
grep -q " $crash_cur_id$" "$MAIN_HOME/log/delivered" || fail 3 "cur crash log was not repaired"
[ ! -e "$MAIN_HOME/spool/for/alpha/$crash_cur_id" ] || fail 3 "cur crash spool copy remained"
grep -l "^Refs: $crash_cur_id$" "$MAIN_HOME"/spool/for/b200/* >/dev/null 2>&1 || \
    fail 3 "cur crash ack was not regenerated"
pass 3 "new/cur crash windows repair dedup state without redelivery"

# 4. Regenerating an ack for the same Refs yields byte-identical content.
regen_id=$(remote_message regen "regenerate deterministic ack") || fail 4 "regen fixture send failed"
cp "$REMOTE_HOME/outbox/new/$regen_id" "$MAIN_HOME/spool/for/alpha/$regen_id"
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/regen-first.out" 2>"$TEST_DIR/regen-first.err" || \
    fail 4 "first regen sync failed"
regen_ack=$(grep -l "^Refs: $regen_id$" "$MAIN_HOME"/spool/for/b200/* | sed -n '1p')
[ -n "$regen_ack" ] || fail 4 "first ack is missing"
cp "$regen_ack" "$TEST_DIR/ack.saved"
rm -f "$regen_ack"
cp "$REMOTE_HOME/outbox/new/$regen_id" "$MAIN_HOME/spool/for/alpha/$regen_id"
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/regen-second.out" 2>"$TEST_DIR/regen-second.err" || \
    fail 4 "second regen sync failed"
regen_ack=$(grep -l "^Refs: $regen_id$" "$MAIN_HOME"/spool/for/b200/* | sed -n '1p')
cmp -s "$TEST_DIR/ack.saved" "$regen_ack" || fail 4 "regenerated ack bytes changed"
pass 4 "ack regeneration preserves Date, Expires, and every byte"

# 5. An existing inbox filename is a no-clobber success and repairs the log.
clobber_id=$(remote_message noclobber "must not replace sentinel") || fail 5 "no-clobber fixture send failed"
mkdir -p "$MAIN_HOME/inbox/noclobber/new" "$MAIN_HOME/inbox/noclobber/cur"
printf 'sentinel bytes\n' > "$MAIN_HOME/inbox/noclobber/new/$clobber_id"
cp "$MAIN_HOME/inbox/noclobber/new/$clobber_id" "$TEST_DIR/sentinel.saved"
cp "$REMOTE_HOME/outbox/new/$clobber_id" "$MAIN_HOME/spool/for/alpha/$clobber_id"
KHALA_HOME="$MAIN_HOME" "$KHALA" sync >"$TEST_DIR/no-clobber.out" 2>"$TEST_DIR/no-clobber.err" || \
    fail 5 "no-clobber delivery was not treated as success"
cmp -s "$TEST_DIR/sentinel.saved" "$MAIN_HOME/inbox/noclobber/new/$clobber_id" || \
    fail 5 "existing destination bytes were overwritten"
grep -q " $clobber_id$" "$MAIN_HOME/log/delivered" || fail 5 "no-clobber log was not repaired"
pass 5 "delivery never overwrites an existing Id path"

# 6. A blocked exchange does not hold the brain lock needed by inbox drain.
KHALA_HOME="$NETWORK_HOME" "$KHALA" init alpha >"$TEST_DIR/network-init.out" 2>"$TEST_DIR/network-init.err" || \
    fail 6 "network init failed"
network_id=$(KHALA_HOME="$NETWORK_HOME" KHALA_SESSION=sender \
    "$KHALA" send drainable@alpha -m "drain while exchange waits") || fail 6 "network fixture send failed"
KHALA_HOME="$NETWORK_HOME" "$KHALA" reconcile >"$TEST_DIR/network-stage.out" 2>"$TEST_DIR/network-stage.err" || \
    fail 6 "network fixture reconcile failed"
{
    printf 'self alpha\n'
    printf 'peer alpha %s\n' "$NETWORK_HOME"
    printf 'peer b200 240.0.0.1\n'
    printf 'mailbox b200\n'
    printf 'ttl 120\n'
} > "$NETWORK_HOME/tmp/config.concurrency.$$"
mv "$NETWORK_HOME/tmp/config.concurrency.$$" "$NETWORK_HOME/config"
(
    KHALA_HOME="$NETWORK_HOME" "$KHALA" sync >"$TEST_DIR/network-sync.out" 2>"$TEST_DIR/network-sync.err"
    printf '%s\n' "$?" > "$TEST_DIR/network-sync.status"
) &
NETWORK_PID=$!
sleep 2
drain_started=$(date +%s) || fail 6 "could not read drain start"
KHALA_HOME="$NETWORK_HOME" KHALA_SESSION=drainable "$KHALA" inbox --drain \
    >"$TEST_DIR/network-drain.out" 2>"$TEST_DIR/network-drain.err" || fail 6 "drain failed during exchange"
drain_ended=$(date +%s) || fail 6 "could not read drain end"
[ "$((drain_ended - drain_started))" -lt 10 ] || fail 6 "drain waited ten seconds for network"
[ ! -e "$TEST_DIR/network-sync.status" ] || fail 6 "network sync ended before the drain proved separation"
wait "$NETWORK_PID" || :
NETWORK_PID=
[ "$(sed -n '1p' "$TEST_DIR/network-sync.status")" -ne 0 ] || fail 6 "blackhole sync unexpectedly succeeded"
grep -Fq "$network_id" "$TEST_DIR/network-drain.out" || fail 6 "staged mail was not drained"
pass 6 "brain lock remains available while exchange is blocked on the network"

# 7. Stale locks are reclaimed loudly; fresh locks wait for their holder.
KHALA_HOME="$LOCK_HOME" "$KHALA" init alpha >"$TEST_DIR/lock-init.out" 2>"$TEST_DIR/lock-init.err" || \
    fail 7 "lock init failed"
lock_now=$(date +%s) || fail 7 "could not read lock time"
mkdir "$LOCK_HOME/run/brain.lock.d" || fail 7 "could not create stale brain lock"
printf '%s\npid 777 reconcile\n' "$((lock_now - 400))" > "$LOCK_HOME/run/brain.lock.d/owner"
KHALA_HOME="$LOCK_HOME" "$KHALA" sync >"$TEST_DIR/stale-lock.out" 2>"$TEST_DIR/stale-lock.err" || \
    fail 7 "sync did not proceed after stale brain lock"
grep -q 'reclaimed stale lock from pid 777' "$TEST_DIR/stale-lock.err" || \
    fail 7 "stale brain lock reclaim was not loud"

fresh_now=$(date +%s) || fail 7 "could not read fresh lock time"
mkdir "$LOCK_HOME/run/brain.lock.d" || fail 7 "could not create fresh brain lock"
printf '%s\npid 778 holder\n' "$fresh_now" > "$LOCK_HOME/run/brain.lock.d/owner"
(
    sleep 2
    rm -f "$LOCK_HOME/run/brain.lock.d/owner"
    rmdir "$LOCK_HOME/run/brain.lock.d"
    printf 'released\n' > "$TEST_DIR/holder.released"
) &
holder_pid=$!
wait_started=$(date +%s) || fail 7 "could not read wait start"
KHALA_HOME="$LOCK_HOME" "$KHALA" reconcile >"$TEST_DIR/fresh-lock.out" 2>"$TEST_DIR/fresh-lock.err" || \
    fail 7 "fresh lock waiter failed"
wait_ended=$(date +%s) || fail 7 "could not read wait end"
wait "$holder_pid" || fail 7 "fresh lock holder failed to release"
[ -f "$TEST_DIR/holder.released" ] || fail 7 "waiter finished before holder release"
[ "$((wait_ended - wait_started))" -ge 1 ] || fail 7 "fresh lock waiter did not wait"
if grep -q 'reclaimed stale lock' "$TEST_DIR/fresh-lock.err"; then
    fail 7 "fresh lock was reclaimed"
fi
pass 7 "stale brain locks are reclaimed and fresh locks are awaited"

# 8. Every pre-existing suite remains green.
for regression_suite in local-roundtrip exchange-roundtrip hardening watch; do
    if ! bash "$ROOT/test/$regression_suite.sh" \
        >"$TEST_DIR/$regression_suite.out" 2>"$TEST_DIR/$regression_suite.err"; then
        fail 8 "$regression_suite regression failed: $(tr '\n' ' ' < "$TEST_DIR/$regression_suite.err")"
    fi
    grep -q '^RESULT: PASS$' "$TEST_DIR/$regression_suite.out" || \
        fail 8 "$regression_suite did not report PASS"
done
pass 8 "all four existing suites pass"

printf 'RESULT: PASS\n'
printf 'self-spool, concurrency, crash recovery, locks, deterministic infra, and regressions passed\n'
