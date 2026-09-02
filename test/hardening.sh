#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA="$ROOT/bin/khala"
export KHALA_HOME="$HOME/.khala-hardening-$$"
TEST_DIR="$HOME/.khala-hardening-test-$$"

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

mkdir -p -- "$TEST_DIR"
trap cleanup EXIT HUP INT TERM

if ! "$KHALA" init b200 >"$TEST_DIR/init.out" 2>"$TEST_DIR/init.err"; then
    fail 1 "init failed: $(tr '\n' ' ' < "$TEST_DIR/init.err")"
fi
printf 'retention-interval 0\n' >> "$KHALA_HOME/config" || fail 1 "config append failed"
if ! baseline_id=$(KHALA_SESSION=baseline "$KHALA" send baseline@b200 \
    -m "pruning baseline" 2>"$TEST_DIR/baseline-send.err"); then
    fail 1 "baseline send failed: $(tr '\n' ' ' < "$TEST_DIR/baseline-send.err")"
fi
if ! "$KHALA" sync >"$TEST_DIR/baseline-sync.out" 2>"$TEST_DIR/baseline-sync.err"; then
    fail 1 "baseline sync failed: $(tr '\n' ' ' < "$TEST_DIR/baseline-sync.err")"
fi
now=$(date +%s) || fail 1 "could not read current time"
old_epoch=$((now - 5184001))
fresh_epoch=$((now - 60))
grep -v ' fake-id-' "$KHALA_HOME/log/delivered" > "$TEST_DIR/real-delivered"
printf '%s fake-id-old\n%s fake-id-fresh\n' "$old_epoch" "$fresh_epoch" \
    >> "$KHALA_HOME/log/delivered"
if ! "$KHALA" sync >"$TEST_DIR/prune.out" 2>"$TEST_DIR/prune.err"; then
    fail 1 "pruning sync failed: $(tr '\n' ' ' < "$TEST_DIR/prune.err")"
fi
if grep -q ' fake-id-old$' "$KHALA_HOME/log/delivered"; then
    fail 1 "old forged delivered entry remains"
fi
grep -q "^$fresh_epoch fake-id-fresh$" "$KHALA_HOME/log/delivered" || \
    fail 1 "fresh forged delivered entry was removed"
while IFS= read -r real_line; do
    [ -n "$real_line" ] || continue
    grep -Fqx "$real_line" "$KHALA_HOME/log/delivered" || \
        fail 1 "real delivered entry was removed: $real_line"
done < "$TEST_DIR/real-delivered"
grep -q " $baseline_id$" "$KHALA_HOME/log/delivered" || \
    fail 1 "baseline delivery entry is missing"
pass 1 "delivered-log pruning removes only the forged old entry"

cp "$KHALA_HOME/log/delivered" "$TEST_DIR/delivered-before"
if ! "$KHALA" sync >"$TEST_DIR/prune-again.out" 2>"$TEST_DIR/prune-again.err"; then
    fail 2 "second pruning sync failed: $(tr '\n' ' ' < "$TEST_DIR/prune-again.err")"
fi
cmp -s "$TEST_DIR/delivered-before" "$KHALA_HOME/log/delivered" || \
    fail 2 "second sync changed the delivered log"
pass 2 "delivered-log pruning is byte-idempotent"

if ! intact_id=$(KHALA_SESSION=sender "$KHALA" send intact@b200 \
    -m "intact payload" 2>"$TEST_DIR/intact-send.err"); then
    fail 3 "intact send failed: $(tr '\n' ' ' < "$TEST_DIR/intact-send.err")"
fi
if ! corrupt_id=$(KHALA_SESSION=sender "$KHALA" send corrupt@b200 \
    -m "corrupt payload long enough to truncate" 2>"$TEST_DIR/corrupt-send.err"); then
    fail 3 "corrupt send failed: $(tr '\n' ' ' < "$TEST_DIR/corrupt-send.err")"
fi
cp "$KHALA_HOME/outbox/new/$intact_id" "$KHALA_HOME/spool/for/b200/$intact_id"
sed "s/^Id: $corrupt_id$/Id: forged-id/" "$KHALA_HOME/outbox/new/$corrupt_id" \
    > "$TEST_DIR/corrupt-full"
corrupt_bytes=$(wc -c < "$TEST_DIR/corrupt-full" | tr -d ' ')
head -c "$((corrupt_bytes / 2))" "$TEST_DIR/corrupt-full" \
    > "$KHALA_HOME/spool/for/b200/$corrupt_id"
if "$KHALA" sync >"$TEST_DIR/isolation.out" 2>"$TEST_DIR/isolation.err"; then
    fail 3 "sync with a corrupt spool file unexpectedly succeeded"
fi
[ -f "$KHALA_HOME/inbox/intact/new/$intact_id" ] || \
    fail 3 "intact message was not delivered"
[ -f "$KHALA_HOME/outbox/acked/$intact_id" ] || \
    fail 3 "intact message was not acknowledged"
[ -f "$KHALA_HOME/spool/for/b200/$corrupt_id" ] || \
    fail 3 "young corrupt spool file did not remain in place"
[ ! -e "$KHALA_HOME/spool/dead/$corrupt_id" ] || \
    fail 3 "young corrupt spool file moved to dead"
pass 3 "a young corrupt file fails alone while intact mail delivers and acks"

touch -t 200001010000.00 "$KHALA_HOME/spool/for/b200/$corrupt_id" || \
    fail 4 "could not backdate corrupt spool file"
if ! hygiene_ok_id=$(KHALA_SESSION=sender "$KHALA" send hygieneok@b200 \
    -m "deliver beside old garbage" 2>"$TEST_DIR/hygiene-ok-send.err"); then
    fail 4 "companion send failed: $(tr '\n' ' ' < "$TEST_DIR/hygiene-ok-send.err")"
fi
if "$KHALA" sync >"$TEST_DIR/hygiene.out" 2>"$TEST_DIR/hygiene.err"; then
    fail 4 "hygiene sync unexpectedly hid the validation failure"
fi
[ ! -e "$KHALA_HOME/spool/for/b200/$corrupt_id" ] || \
    fail 4 "old corrupt spool file remains in the live spool"
[ -f "$KHALA_HOME/spool/dead/$corrupt_id" ] || \
    fail 4 "old corrupt spool file was not moved to dead"
grep -Fq "$corrupt_id" "$TEST_DIR/hygiene.err" || \
    fail 4 "hygiene stderr does not name the corrupt file"
grep -q '30일 지난 파싱 불능' "$TEST_DIR/hygiene.err" || \
    fail 4 "hygiene stderr does not state the reason"
[ -f "$KHALA_HOME/inbox/hygieneok/new/$hygiene_ok_id" ] || \
    fail 4 "hygiene blocked companion delivery"
[ -f "$KHALA_HOME/outbox/acked/$hygiene_ok_id" ] || \
    fail 4 "hygiene blocked companion acknowledgement"
pass 4 "old garbage moves to spool/dead with a diagnostic"

if ! old_valid_id=$(KHALA_SESSION=sender "$KHALA" send oldvalid@b200 \
    -m "old but valid" 2>"$TEST_DIR/old-valid-send.err"); then
    fail 5 "old-valid send failed: $(tr '\n' ' ' < "$TEST_DIR/old-valid-send.err")"
fi
cp "$KHALA_HOME/outbox/new/$old_valid_id" "$KHALA_HOME/spool/for/b200/$old_valid_id"
touch -t 200001010000.00 "$KHALA_HOME/spool/for/b200/$old_valid_id" || \
    fail 5 "could not backdate valid spool file"
if ! "$KHALA" sync >"$TEST_DIR/old-valid.out" 2>"$TEST_DIR/old-valid.err"; then
    fail 5 "old-valid sync failed: $(tr '\n' ' ' < "$TEST_DIR/old-valid.err")"
fi
[ -f "$KHALA_HOME/inbox/oldvalid/new/$old_valid_id" ] || \
    fail 5 "old valid message was not delivered"
[ -f "$KHALA_HOME/outbox/acked/$old_valid_id" ] || \
    fail 5 "old valid message was not acknowledged"
[ ! -e "$KHALA_HOME/spool/dead/$old_valid_id" ] || \
    fail 5 "old valid message was moved to dead"
pass 5 "age alone never quarantines valid mail"

if ! "$ROOT/test/local-roundtrip.sh" \
    >"$TEST_DIR/local-roundtrip.out" 2>"$TEST_DIR/local-roundtrip.err"; then
    fail 6 "local regression failed: $(tr '\n' ' ' < "$TEST_DIR/local-roundtrip.err")"
fi
if ! "$ROOT/test/exchange-roundtrip.sh" \
    >"$TEST_DIR/exchange-roundtrip.out" 2>"$TEST_DIR/exchange-roundtrip.err"; then
    fail 6 "exchange regression failed: $(tr '\n' ' ' < "$TEST_DIR/exchange-roundtrip.err")"
fi
grep -q '^RESULT: PASS$' "$TEST_DIR/local-roundtrip.out" || \
    fail 6 "local regression did not report PASS"
grep -q '^RESULT: PASS$' "$TEST_DIR/exchange-roundtrip.out" || \
    fail 6 "exchange regression did not report PASS"
pass 6 "local and exchange roundtrip regressions pass unchanged"

printf 'RESULT: PASS\n'
printf 'pruning, isolation, spool hygiene, and regressions passed\n'
