#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA="$ROOT/bin/khala"
HOME_A="$HOME/.khala-exchange-alpha-$$"
HOME_M="$HOME/.khala-exchange-mailbox-$$"
BOGUS="$HOME/.khala-exchange-missing-$$"
TEST_DIR="$HOME/.khala-exchange-test-$$"

cleanup() {
    rm -rf -- "$HOME_A" "$HOME_M" "$BOGUS" "$TEST_DIR"
}

dump_layout() {
    for dump_home in "$HOME_A" "$HOME_M"; do
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

write_alpha_config() {
    config_mode=$1
    config_tmp="$HOME_A/tmp/config.exchange.$$"
    if [ "$config_mode" = working ]; then
        config_endpoints="$BOGUS $HOME_M"
    else
        config_endpoints=$BOGUS
    fi
    if ! {
        printf 'self alpha\n'
        printf 'peer alpha %s\n' "$HOME_A"
        printf 'peer b200 %s\n' "$config_endpoints"
        printf 'mailbox b200\n'
        printf 'ttl 120\n'
    } > "$config_tmp"; then
        return 1
    fi
    mv "$config_tmp" "$HOME_A/config"
}

mkdir -p -- "$TEST_DIR"
trap cleanup EXIT HUP INT TERM

if ! KHALA_HOME="$HOME_A" "$KHALA" init alpha \
    >"$TEST_DIR/init-alpha.out" 2>"$TEST_DIR/init-alpha.err"; then
    fail 1 "alpha init failed: $(tr '\n' ' ' < "$TEST_DIR/init-alpha.err")"
fi
if ! KHALA_HOME="$HOME_M" "$KHALA" init b200 \
    >"$TEST_DIR/init-mailbox.out" 2>"$TEST_DIR/init-mailbox.err"; then
    fail 1 "b200 init failed: $(tr '\n' ' ' < "$TEST_DIR/init-mailbox.err")"
fi
write_alpha_config working || fail 1 "alpha config setup failed"

# 1. Push through the second endpoint and retain the sender's original.
if ! message_id=$(KHALA_HOME="$HOME_A" KHALA_SESSION=alice \
    "$KHALA" send bob@b200 -m "over the wire" 2>"$TEST_DIR/send.err"); then
    fail 1 "send failed: $(tr '\n' ' ' < "$TEST_DIR/send.err")"
fi
if ! KHALA_HOME="$HOME_A" "$KHALA" sync \
    >"$TEST_DIR/alpha-sync-1.out" 2>"$TEST_DIR/alpha-sync-1.err"; then
    fail 1 "alpha sync failed: $(tr '\n' ' ' < "$TEST_DIR/alpha-sync-1.err")"
fi
[ -f "$HOME_M/spool/for/b200/$message_id" ] || fail 1 "message did not reach mailbox spool"
[ -f "$HOME_A/outbox/new/$message_id" ] || fail 1 "sender original was removed before ack"
grep -Fq "$BOGUS" "$TEST_DIR/alpha-sync-1.err" || fail 1 "bogus candidate skip was not reported"
pass 1 "candidate fallback pushes while retaining the original"

# 2. Deliver once at the mailbox and create the deterministic ack.
if ! KHALA_HOME="$HOME_M" "$KHALA" sync \
    >"$TEST_DIR/mailbox-sync-1.out" 2>"$TEST_DIR/mailbox-sync-1.err"; then
    fail 2 "b200 sync failed: $(tr '\n' ' ' < "$TEST_DIR/mailbox-sync-1.err")"
fi
[ "$(count_files "$HOME_M/inbox/bob/new")" -eq 1 ] || fail 2 "message was not delivered exactly once"
ack_file=$(grep -l "^Refs: $message_id$" "$HOME_M"/spool/for/alpha/* 2>/dev/null | sed -n '1p')
[ -n "$ack_file" ] || fail 2 "ack was not created for alpha"
grep -q " $message_id$" "$HOME_M/log/delivered" || fail 2 "delivery was not recorded in dedup log"
if ! KHALA_HOME="$HOME_M" KHALA_SESSION=bob "$KHALA" inbox \
    >"$TEST_DIR/bob-inbox.out" 2>"$TEST_DIR/bob-inbox.err"; then
    fail 2 "bob heartbeat failed: $(tr '\n' ' ' < "$TEST_DIR/bob-inbox.err")"
fi
pass 2 "mailbox delivers once, logs dedup, and creates an ack"

# 3. Pull and consume the ack at alpha.
if ! KHALA_HOME="$HOME_A" "$KHALA" sync \
    >"$TEST_DIR/alpha-sync-2.out" 2>"$TEST_DIR/alpha-sync-2.err"; then
    fail 3 "ack sync failed: $(tr '\n' ' ' < "$TEST_DIR/alpha-sync-2.err")"
fi
[ -f "$HOME_A/outbox/acked/$message_id" ] || fail 3 "original did not move to outbox/acked"
[ "$(count_files "$HOME_A/outbox/new")" -eq 0 ] || fail 3 "outbox/new still contains the original"
[ "$(count_files "$HOME_M/spool/for/alpha")" -eq 0 ] || fail 3 "mailbox ack source was not removed"
[ "$(count_files "$HOME_A/spool/for/alpha")" -eq 0 ] || fail 3 "alpha local spool was not consumed"
[ "$(count_files "$HOME_A/spool/for/b200")" -eq 0 ] || fail 3 "alpha outgoing spool was not settled"
pass 3 "ack pull settles the sender and empties both ack spools"

# 4. Another pair of cycles must not alter semantic state. run/ (lock
# scratch) and tmp/ (staging scratch) are volatile by design and every sync
# touches their directory mtimes, so an ls -laR comparison flakes whenever
# the two snapshots straddle a minute boundary under load; compare the file
# set and contents of the semantic paths instead.
semantic_snapshot() {
    (cd "$1" && find . -path ./run -prune -o -path ./tmp -prune -o -type f -print | sort | \
        while IFS= read -r snapshot_file; do
            printf '%s %s\n' "$snapshot_file" "$(cksum < "$snapshot_file")"
        done)
}
semantic_snapshot "$HOME_A" >"$TEST_DIR/alpha-tree-before"
semantic_snapshot "$HOME_M" >"$TEST_DIR/mailbox-tree-before"
if ! KHALA_HOME="$HOME_A" "$KHALA" sync \
    >"$TEST_DIR/alpha-sync-idempotent.out" 2>"$TEST_DIR/alpha-sync-idempotent.err"; then
    fail 4 "idempotent alpha sync failed: $(tr '\n' ' ' < "$TEST_DIR/alpha-sync-idempotent.err")"
fi
if ! KHALA_HOME="$HOME_M" "$KHALA" sync \
    >"$TEST_DIR/mailbox-sync-idempotent.out" 2>"$TEST_DIR/mailbox-sync-idempotent.err"; then
    fail 4 "idempotent b200 sync failed: $(tr '\n' ' ' < "$TEST_DIR/mailbox-sync-idempotent.err")"
fi
semantic_snapshot "$HOME_A" >"$TEST_DIR/alpha-tree-after"
semantic_snapshot "$HOME_M" >"$TEST_DIR/mailbox-tree-after"
cmp -s "$TEST_DIR/alpha-tree-before" "$TEST_DIR/alpha-tree-after" || fail 4 "alpha listing changed"
cmp -s "$TEST_DIR/mailbox-tree-before" "$TEST_DIR/mailbox-tree-after" || fail 4 "mailbox listing changed"
pass 4 "the settled pair is idempotent"

# 5. A duplicate wire copy is deduplicated and regenerates a harmless ack.
delivered_file="$HOME_M/inbox/bob/new/$message_id"
cp "$delivered_file" "$HOME_M/spool/for/b200/$message_id"
if ! KHALA_HOME="$HOME_M" "$KHALA" sync \
    >"$TEST_DIR/mailbox-sync-dedup.out" 2>"$TEST_DIR/mailbox-sync-dedup.err"; then
    fail 5 "dedup b200 sync failed: $(tr '\n' ' ' < "$TEST_DIR/mailbox-sync-dedup.err")"
fi
[ "$(count_files "$HOME_M/inbox/bob/new")" -eq 1 ] || fail 5 "duplicate reached bob inbox"
grep -l "^Refs: $message_id$" "$HOME_M"/spool/for/alpha/* >/dev/null 2>&1 || fail 5 "dedup did not regenerate ack"
if ! KHALA_HOME="$HOME_A" "$KHALA" sync \
    >"$TEST_DIR/alpha-sync-dedup.out" 2>"$TEST_DIR/alpha-sync-dedup.err"; then
    fail 5 "dedup ack sync failed: $(tr '\n' ' ' < "$TEST_DIR/alpha-sync-dedup.err")"
fi
[ -f "$HOME_A/outbox/acked/$message_id" ] || fail 5 "acked original was disturbed"
[ "$(count_files "$HOME_M/spool/for/alpha")" -eq 0 ] || fail 5 "regenerated ack was not pulled"
pass 5 "wire duplicate is deduplicated and its ack is harmless"

# 6. Presence is merged and remains observer-relative.
if ! KHALA_HOME="$HOME_A" "$KHALA" presence \
    >"$TEST_DIR/alpha-presence.out" 2>"$TEST_DIR/alpha-presence.err"; then
    fail 6 "alpha presence failed: $(tr '\n' ' ' < "$TEST_DIR/alpha-presence.err")"
fi
if ! KHALA_HOME="$HOME_M" "$KHALA" presence \
    >"$TEST_DIR/mailbox-presence.out" 2>"$TEST_DIR/mailbox-presence.err"; then
    fail 6 "b200 presence failed: $(tr '\n' ' ' < "$TEST_DIR/mailbox-presence.err")"
fi
grep -q 'bob@b200.*alive-elsewhere' "$TEST_DIR/alpha-presence.out" || fail 6 "alpha cannot see bob elsewhere"
grep -q 'alice@alpha.*alive-here' "$TEST_DIR/alpha-presence.out" || fail 6 "alpha cannot see its own session here"
grep -q 'alice@alpha.*alive-elsewhere' "$TEST_DIR/mailbox-presence.out" || fail 6 "b200 cannot see alpha elsewhere"
grep -q 'asleep = 칼라 활동 없음' "$TEST_DIR/alpha-presence.out" || fail 6 "alpha honesty note is missing"
grep -q 'asleep = 칼라 활동 없음' "$TEST_DIR/mailbox-presence.out" || fail 6 "b200 honesty note is missing"
pass 6 "presence merges with here/elsewhere states and honesty notes"

# 7. Total mailbox failure is loud but does not block local delivery.
write_alpha_config broken || fail 7 "broken alpha config setup failed"
if ! local_id=$(KHALA_HOME="$HOME_A" KHALA_SESSION=self-session \
    "$KHALA" send self-session@alpha -m "still local" 2>"$TEST_DIR/local-send.err"); then
    fail 7 "local send failed: $(tr '\n' ' ' < "$TEST_DIR/local-send.err")"
fi
if KHALA_HOME="$HOME_A" "$KHALA" sync \
    >"$TEST_DIR/alpha-sync-failed.out" 2>"$TEST_DIR/alpha-sync-failed.err"; then
    fail 7 "sync with no reachable mailbox unexpectedly succeeded"
fi
[ -f "$HOME_A/inbox/self-session/new/$local_id" ] || fail 7 "local message was blocked by mailbox failure"
grep -q '사용 가능한 mailbox 후보가 없습니다' "$TEST_DIR/alpha-sync-failed.err" || fail 7 "total failure was not reported"
pass 7 "mailbox failure is non-zero but local delivery continues"

# 8. The unchanged single-machine suite remains green.
if ! bash "$ROOT/test/local-roundtrip.sh" \
    >"$TEST_DIR/local-roundtrip.out" 2>"$TEST_DIR/local-roundtrip.err"; then
    fail 8 "local regression failed: $(tr '\n' ' ' < "$TEST_DIR/local-roundtrip.err")"
fi
grep -q '^ok 9 —' "$TEST_DIR/local-roundtrip.out" || fail 8 "local suite did not reach step 9"
grep -q '^RESULT: PASS$' "$TEST_DIR/local-roundtrip.out" || fail 8 "local suite did not pass"
pass 8 "local roundtrip regression remains 9/9"

printf 'RESULT: PASS\n'
printf 'mailbox exchange, ack settlement, dedup, presence, isolation, and regression passed\n'
