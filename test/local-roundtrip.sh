#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA="$ROOT/bin/khala"
export KHALA_HOME="$HOME/.khala-test-$$"
TEST_DIR="$HOME/.khala-local-roundtrip-$$"

cleanup() {
    rm -rf -- "$KHALA_HOME" "$TEST_DIR"
}

dump_layout() {
    if [ -d "$KHALA_HOME" ]; then
        find "$KHALA_HOME" -print | sort >&2
    else
        printf '%s\n' "$KHALA_HOME (missing)" >&2
    fi
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
    count_dir=$1
    count=0
    if [ -d "$count_dir" ]; then
        for count_file in "$count_dir"/*; do
            [ -f "$count_file" ] || continue
            count=$((count + 1))
        done
    fi
    printf '%s\n' "$count"
}

first_file() {
    first_dir=$1
    for first_path in "$first_dir"/*; do
        [ -f "$first_path" ] || continue
        printf '%s\n' "$first_path"
        return 0
    done
    return 1
}

mkdir -p -- "$TEST_DIR"
trap cleanup EXIT HUP INT TERM

# 1. RED before init.
if KHALA_SESSION=bob "$KHALA" send alice@b200 -m "hello" \
    >"$TEST_DIR/pre-init.out" 2>"$TEST_DIR/pre-init.err"; then
    fail 1 "send before init must fail"
fi
if ! grep -q 'khala init 먼저' "$TEST_DIR/pre-init.err"; then
    fail 1 "missing init guidance on stderr"
fi
pass 1 "pre-init send fails with guidance"

# 2. Initialize and verify the complete local layout.
if ! "$KHALA" init b200 >"$TEST_DIR/init.out" 2>"$TEST_DIR/init.err"; then
    fail 2 "init failed: $(tr '\n' ' ' < "$TEST_DIR/init.err")"
fi
for required_dir in \
    "$KHALA_HOME/outbox/new" \
    "$KHALA_HOME/outbox/acked" \
    "$KHALA_HOME/outbox/dead" \
    "$KHALA_HOME/spool/for" \
    "$KHALA_HOME/spool/for/b200" \
    "$KHALA_HOME/inbox" \
    "$KHALA_HOME/presence" \
    "$KHALA_HOME/log" \
    "$KHALA_HOME/tmp"; do
    [ -d "$required_dir" ] || fail 2 "missing directory $required_dir"
done
[ -f "$KHALA_HOME/config" ] || fail 2 "missing config"
[ -f "$KHALA_HOME/log/delivered" ] || fail 2 "missing dedup log"
if [ "$(ls -ld "$KHALA_HOME" | cut -c2-10)" != "rwx------" ]; then
    fail 2 "KHALA_HOME is not mode 0700"
fi
grep -q '^self b200$' "$KHALA_HOME/config" || fail 2 "identity not recorded"
pass 2 "init creates the 0700 on-disk layout"

# 3. Durable local enqueue and exact message headers.
if ! KHALA_SESSION=bob "$KHALA" send alice@b200 -m "hello" \
    >"$TEST_DIR/send.out" 2>"$TEST_DIR/send.err"; then
    fail 3 "send failed: $(tr '\n' ' ' < "$TEST_DIR/send.err")"
fi
[ "$(count_files "$KHALA_HOME/outbox/new")" -eq 1 ] || fail 3 "outbox/new does not contain exactly one file"
message_file=$(first_file "$KHALA_HOME/outbox/new") || fail 3 "message file missing"
message_id=$(sed -n 's/^Id: //p' "$message_file")
[ -n "$message_id" ] || fail 3 "Id header missing"
[ "$(basename "$message_file")" = "$message_id" ] || fail 3 "filename differs from Id header"
grep -q '^From: bob@b200$' "$message_file" || fail 3 "wrong From header"
grep -q '^To: alice@b200$' "$message_file" || fail 3 "wrong To header"
grep -q '^Type: message$' "$message_file" || fail 3 "wrong Type header"
expires=$(sed -n 's/^Expires: //p' "$message_file")
case "$expires" in
    ''|*[!0-9]*) fail 3 "Expires is not an integer" ;;
esac
now=$(date +%s)
[ "$expires" -gt "$((now + 2500000))" ] || fail 3 "default expiry is not approximately 30 days"
[ "$expires" -lt "$((now + 2700000))" ] || fail 3 "default expiry is not approximately 30 days"
pass 3 "send durably enqueues a correctly named message"

# 4. Deliver locally and settle its end-to-end ack within two cycles.
if ! "$KHALA" sync >"$TEST_DIR/sync-1.out" 2>"$TEST_DIR/sync-1.err"; then
    fail 4 "first sync failed: $(tr '\n' ' ' < "$TEST_DIR/sync-1.err")"
fi
[ "$(count_files "$KHALA_HOME/inbox/alice/new")" -eq 1 ] || fail 4 "message was not delivered exactly once"
if [ "$(count_files "$KHALA_HOME/outbox/new")" -ne 0 ]; then
    if ! "$KHALA" sync >"$TEST_DIR/sync-2.out" 2>"$TEST_DIR/sync-2.err"; then
        fail 4 "second sync failed: $(tr '\n' ' ' < "$TEST_DIR/sync-2.err")"
    fi
fi
[ "$(count_files "$KHALA_HOME/outbox/new")" -eq 0 ] || fail 4 "outbox/new was not settled"
[ -f "$KHALA_HOME/outbox/acked/$message_id" ] || fail 4 "original did not reach outbox/acked"
[ "$(count_files "$KHALA_HOME/spool/for/b200")" -eq 0 ] || fail 4 "stray spool files remain"
delivered_file="$KHALA_HOME/inbox/alice/new/$message_id"
[ -f "$delivered_file" ] || fail 4 "delivered message filename changed"
pass 4 "sync delivers and consumes the ack"

# 5. A further cycle must not change the recursive path listing.
ls -laR "$KHALA_HOME" >"$TEST_DIR/tree-before"
if ! "$KHALA" sync >"$TEST_DIR/sync-3.out" 2>"$TEST_DIR/sync-3.err"; then
    fail 5 "third sync failed: $(tr '\n' ' ' < "$TEST_DIR/sync-3.err")"
fi
ls -laR "$KHALA_HOME" >"$TEST_DIR/tree-after"
cmp -s "$TEST_DIR/tree-before" "$TEST_DIR/tree-after" || fail 5 "third sync changed the recursive listing"
pass 5 "sync is idempotent"

# 6. Re-inject the delivered file and verify dedup plus spool consumption.
cp "$delivered_file" "$KHALA_HOME/spool/for/b200/$message_id"
if ! "$KHALA" sync >"$TEST_DIR/sync-dedup.out" 2>"$TEST_DIR/sync-dedup.err"; then
    fail 6 "dedup sync failed: $(tr '\n' ' ' < "$TEST_DIR/sync-dedup.err")"
fi
[ "$(count_files "$KHALA_HOME/inbox/alice/new")" -eq 1 ] || fail 6 "duplicate appeared in alice inbox"
[ "$(count_files "$KHALA_HOME/spool/for/b200")" -eq 0 ] || fail 6 "duplicate was not consumed from spool"
pass 6 "delivered ids are deduplicated"

# 7. Drain once, then prove that there is nothing new to drain again.
if ! KHALA_SESSION=alice "$KHALA" inbox --drain \
    >"$TEST_DIR/drain-1.out" 2>"$TEST_DIR/drain-1.err"; then
    fail 7 "first drain failed: $(tr '\n' ' ' < "$TEST_DIR/drain-1.err")"
fi
grep -q 'hello' "$TEST_DIR/drain-1.out" || fail 7 "drain did not print the message"
[ -f "$KHALA_HOME/inbox/alice/cur/$message_id" ] || fail 7 "message did not move to cur"
[ "$(count_files "$KHALA_HOME/inbox/alice/new")" -eq 0 ] || fail 7 "alice new inbox is not empty"
if ! KHALA_SESSION=alice "$KHALA" inbox --drain \
    >"$TEST_DIR/drain-2.out" 2>"$TEST_DIR/drain-2.err"; then
    fail 7 "second drain failed: $(tr '\n' ' ' < "$TEST_DIR/drain-2.err")"
fi
[ "$(grep -cv '^drained: letters 0, notices 0, streams 0$' "$TEST_DIR/drain-2.out")" -eq 0 ] ||
    fail 7 "second drain printed an old message"
pass 7 "inbox drain moves new to cur exactly once"

# 8. Expire an unread message and receive one bounce only.
if ! KHALA_SESSION=bob "$KHALA" send nobody@b200 -e 1 -m "expire me" \
    >"$TEST_DIR/send-expiring.out" 2>"$TEST_DIR/send-expiring.err"; then
    fail 8 "expiring send failed: $(tr '\n' ' ' < "$TEST_DIR/send-expiring.err")"
fi
sleep 2
if ! "$KHALA" sync >"$TEST_DIR/sync-expiry.out" 2>"$TEST_DIR/sync-expiry.err"; then
    fail 8 "expiry sync failed: $(tr '\n' ' ' < "$TEST_DIR/sync-expiry.err")"
fi
[ "$(count_files "$KHALA_HOME/outbox/dead")" -eq 1 ] || fail 8 "expired original did not reach dead-letter"
bounce_count=$(grep -l '^Type: bounce$' "$KHALA_HOME"/inbox/bob/new/* 2>/dev/null | wc -l | tr -d ' ')
[ "$bounce_count" -eq 1 ] || fail 8 "sender inbox does not contain exactly one bounce"
if ! "$KHALA" sync >"$TEST_DIR/sync-after-expiry.out" 2>"$TEST_DIR/sync-after-expiry.err"; then
    fail 8 "post-expiry sync failed: $(tr '\n' ' ' < "$TEST_DIR/sync-after-expiry.err")"
fi
bounce_count=$(grep -l '^Type: bounce$' "$KHALA_HOME"/inbox/bob/new/* 2>/dev/null | wc -l | tr -d ' ')
[ "$bounce_count" -eq 1 ] || fail 8 "a second bounce was created"
pass 8 "expiry creates one bounce and one dead-letter"

# 9. Presence reflects command heartbeats without claiming process liveness.
if ! "$KHALA" presence >"$TEST_DIR/presence.out" 2>"$TEST_DIR/presence.err"; then
    fail 9 "presence failed: $(tr '\n' ' ' < "$TEST_DIR/presence.err")"
fi
grep -q 'alice@b200.*alive-here' "$TEST_DIR/presence.out" || fail 9 "alice is not shown alive"
grep -q 'bob@b200.*alive-here' "$TEST_DIR/presence.out" || fail 9 "bob is not shown alive"
grep -q 'asleep = 칼라 활동 없음' "$TEST_DIR/presence.out" || fail 9 "honesty note is missing"
pass 9 "presence reports fresh heartbeats honestly"

printf 'RESULT: PASS\n'
printf 'local store-and-forward, dedup, drain, expiry, and presence passed\n'
