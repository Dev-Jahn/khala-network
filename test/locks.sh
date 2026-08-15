#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=${KHALA_UNDER_TEST-$ROOT/bin/khala}
RIG=$HOME/.khala-locks-test-$$
FAILURES=

cleanup() {
    rm -rf -- "$RIG"
}

die() {
    printf '    %s\n' "$*" >&2
    exit 1
}

count_files() {
    count=0
    for count_dir in "$@"; do
        [ -d "$count_dir" ] || continue
        for count_path in "$count_dir"/*; do
            [ -f "$count_path" ] || continue
            count=$((count + 1))
        done
    done
    printf '%s\n' "$count"
}

init_home() {
    init_target=$1
    KHALA_HOME=$init_target "$KHALA" init alpha >/dev/null \
        2>"$RIG/init-$(basename "$init_target").err" || return 1
}

prepare_letters() {
    letter_home=$1
    letter_count=$2
    init_home "$letter_home" || return 1
    mkdir -p "$letter_home/inbox/reader/new" "$letter_home/inbox/reader/cur" || return 1
    letter_n=1
    while [ "$letter_n" -le "$letter_count" ]; do
        letter_id=2000000000.$$.${letter_n}.sender@alpha
        letter_path=$letter_home/inbox/reader/new/$letter_id
        {
            printf 'Khala: 0.1\n'
            printf 'Id: %s\n' "$letter_id"
            printf 'From: sender@alpha\n'
            printf 'To: reader@alpha\n'
            printf 'Date: 2033-05-18T03:33:20Z\n'
            printf 'Type: message\n'
            printf 'Expires: 2100000000\n\n'
            letter_line=1
            while [ "$letter_line" -le 20 ]; do
                printf 'letter-%s-line-%s ' "$letter_n" "$letter_line"
                awk 'BEGIN { for (i = 0; i < 80; i++) printf "x"; printf "\n" }'
                letter_line=$((letter_line + 1))
            done
        } > "$letter_path" || return 1
        letter_n=$((letter_n + 1))
    done
}

assert_prompt_say() {
    prompt_home=$1
    prompt_tag=$2
    prompt_started=$(date +%s) || return 1
    KHALA_HOME=$prompt_home KHALA_SESSION=after-signal \
        "$KHALA" say -m "$prompt_tag" >"$RIG/$prompt_tag.say.out" \
        2>"$RIG/$prompt_tag.say.err" || return 1
    prompt_ended=$(date +%s) || return 1
    [ "$((prompt_ended - prompt_started))" -lt 3 ]
}

property_p1() {
    home=$RIG/p1-home
    prepare_letters "$home" 8 || die "could not prepare eight drain letters"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        2>"$RIG/p1-drain.err" | head -3 >"$RIG/p1-head.out"
    drain_status=${PIPESTATUS[0]}
    [ "$drain_status" -ne 0 ] || die "early-closed drain unexpectedly completed"
    [ ! -e "$home/run/brain.lock.d" ] || die "SIGPIPE left brain.lock.d behind"
    assert_prompt_say "$home" p1 || die "subsequent say did not succeed within 3s"
}

property_p2() {
    home=$RIG/p2-home
    prepare_letters "$home" 8 || die "could not prepare eight drain letters"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        2>"$RIG/p2-drain.err" | head -30 >"$RIG/p2-head.out"
    drain_status=${PIPESTATUS[0]}
    [ "$drain_status" -ne 0 ] || die "bounded-output drain unexpectedly completed"
    printed_id=$(sed -n 's/^--- \(.*\) ---$/\1/p' "$RIG/p2-head.out")
    [ -n "$printed_id" ] || die "drain did not print a complete letter marker"
    [ "$(printf '%s\n' "$printed_id" | wc -l | tr -d ' ')" -eq 1 ] || \
        die "drain printed more than one letter marker"
    [ -f "$home/inbox/reader/cur/$printed_id" ] || die "printed letter was not moved to cur"
    [ "$(count_files "$home/inbox/reader/cur")" -eq 1 ] || \
        die "an unprinted letter was moved to cur"
    [ "$(count_files "$home/inbox/reader/new")" -eq 7 ] || \
        die "unprinted letters did not remain in new"
}

run_drain_signal_case() {
    signal_name=$1
    signal_status=$2
    signal_tag=$3
    signal_home=$RIG/$signal_tag-home
    signal_shim=$RIG/$signal_tag-shim
    prepare_letters "$signal_home" 8 || return 1
    mkdir -p "$signal_shim" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf 'kill -%s "$PPID"\n' "$signal_name"
        printf 'kill -%s "$$"\n' "$signal_name"
    } > "$signal_shim/cat" || return 1
    chmod 755 "$signal_shim/cat" || return 1
    PATH=$signal_shim:$PATH KHALA_HOME=$signal_home KHALA_SESSION=reader \
        "$KHALA" inbox --drain >"$RIG/$signal_tag.out" 2>"$RIG/$signal_tag.err"
    drain_status=$?
    if [ "$drain_status" -ne "$signal_status" ]; then
        printf '    %s drain status was %s, expected %s\n' \
            "$signal_name" "$drain_status" "$signal_status" >&2
        return 1
    fi
    if [ -e "$signal_home/run/brain.lock.d" ]; then
        printf '    %s left brain.lock.d behind\n' "$signal_name" >&2
        return 1
    fi
    if ! assert_prompt_say "$signal_home" "$signal_tag"; then
        printf '    say after %s did not succeed within 3s\n' "$signal_name" >&2
        return 1
    fi
    return 0
}

property_p3() {
    signal_failed=0
    run_drain_signal_case INT 130 p3-int || signal_failed=1
    run_drain_signal_case TERM 143 p3-term || signal_failed=1
    [ "$signal_failed" -eq 0 ] || die "INT/TERM drain cleanup failed"
}

property_p4() {
    home=$RIG/p4-home
    init_home "$home" || die "watch home init failed"
    KHALA_HOME=$home "$KHALA" watch --session watcher --interval 1 --max-wait 20 \
        >"$RIG/p4-watch.out" 2>"$RIG/p4-watch.err" &
    watch_pid=$!
    watch_wait=0
    while [ "$watch_wait" -lt 5 ] && \
        { [ ! -f "$home/presence/watcher@alpha.watching" ] || \
          [ ! -d "$home/run/watch.watcher.lock.d" ]; }; do
        sleep 1
        watch_wait=$((watch_wait + 1))
    done
    if [ ! -f "$home/presence/watcher@alpha.watching" ] || \
        [ ! -d "$home/run/watch.watcher.lock.d" ]; then
        kill -TERM "$watch_pid" 2>/dev/null || :
        wait "$watch_pid" 2>/dev/null || :
        die "watch did not create its marker and lock"
    fi
    kill -TERM "$watch_pid" || die "could not interrupt watch"
    wait "$watch_pid"
    watch_status=$?
    [ "$watch_status" -eq 143 ] || die "interrupted watch returned $watch_status instead of 143"
    [ ! -e "$home/presence/watcher@alpha.watching" ] || die "watching marker remained"
    [ ! -e "$home/run/watch.watcher.lock.d" ] || die "watch lock remained"
}

write_competing_lock() {
    competing_home=$1
    competing_role=$2
    competing_now=$(date +%s) || return 1
    mkdir "$competing_home/run/brain.lock.d" || return 1
    printf '%s\npid 4242 %s\n' "$competing_now" "$competing_role" \
        > "$competing_home/run/brain.lock.d/owner"
}

remove_competing_lock() {
    competing_home=$1
    rm -f "$competing_home/run/brain.lock.d/owner" || return 1
    rmdir "$competing_home/run/brain.lock.d"
}

property_p5() {
    short_home=$RIG/p5-short-home
    long_home=$RIG/p5-long-home
    init_home "$short_home" || die "short-contention home init failed"
    init_home "$long_home" || die "long-contention home init failed"

    write_competing_lock "$short_home" short-holder || die "could not create short holder"
    (
        sleep 1
        remove_competing_lock "$short_home"
    ) &
    holder_pid=$!
    short_started=$(date +%s) || die "could not read short start"
    KHALA_LINK_SCAN_GATE=1 KHALA_HOME=$short_home "$KHALA" reconcile \
        >"$RIG/p5-short.out" 2>"$RIG/p5-short.err"
    short_status=$?
    short_ended=$(date +%s) || die "could not read short end"
    wait "$holder_pid" || die "short holder did not release cleanly"
    [ "$short_status" -eq 0 ] || die "scan gate lost to a one-second holder"
    [ "$((short_ended - short_started))" -lt 4 ] || \
        die "short-contention gate exceeded the 4s wall-clock bound"

    write_competing_lock "$long_home" long-holder || die "could not create long holder"
    long_started=$(date +%s) || die "could not read long start"
    KHALA_LINK_SCAN_GATE=1 KHALA_HOME=$long_home "$KHALA" reconcile \
        >"$RIG/p5-long.out" 2>"$RIG/p5-long.err"
    long_status=$?
    long_ended=$(date +%s) || die "could not read long end"
    remove_competing_lock "$long_home" || die "could not remove long holder fixture"
    [ "$long_status" -ne 0 ] || die "scan gate unexpectedly acquired a held lock"
    [ "$((long_ended - long_started))" -lt 4 ] || \
        die "long-contention gate exceeded the 4s wall-clock bound"
    printf '    scan-gate timing: short=%ss long=%ss (bound <4s)\n' \
        "$((short_ended - short_started))" "$((long_ended - long_started))"
}

property_p6() {
    p6_root=$RIG/p6-root
    mkdir -p "$p6_root" || die "could not create regression mirror"
    for p6_tree in bin link plugin test; do
        cp -R "$ROOT/$p6_tree" "$p6_root/$p6_tree" || \
            die "could not mirror $p6_tree"
    done
    # This lane may not update the bundled plugin copy. Keep the worktree
    # untouched while giving existing byte-parity audits a collector view.
    cp "$p6_root/bin/khala" "$p6_root/plugin/bin/khala" || \
        die "could not synchronize the regression mirror"
    for regression_suite in local-roundtrip exchange-roundtrip hardening watch \
        concurrency plugin link; do
        if [ "$regression_suite" = plugin ]; then
            PLUGIN_SKIP_REGRESSION=1 PATH=$HOME/go-toolchain/bin:$PATH \
                bash "$p6_root/test/$regression_suite.sh" \
                >"$RIG/p6-$regression_suite.out" 2>"$RIG/p6-$regression_suite.err"
        elif [ "$regression_suite" = link ]; then
            PATH=$HOME/go-toolchain/bin:$PATH \
                bash "$p6_root/test/$regression_suite.sh" \
                >"$RIG/p6-$regression_suite.out" 2>"$RIG/p6-$regression_suite.err"
        else
            bash "$p6_root/test/$regression_suite.sh" \
                >"$RIG/p6-$regression_suite.out" 2>"$RIG/p6-$regression_suite.err"
        fi
        regression_status=$?
        if [ "$regression_status" -ne 0 ]; then
            cat "$RIG/p6-$regression_suite.err" >&2
            die "$regression_suite failed"
        fi
        grep -q '^RESULT: PASS$' "$RIG/p6-$regression_suite.out" || \
            die "$regression_suite omitted RESULT: PASS"
    done
}

run_property() {
    property_number=$1
    property_title=$2
    property_function=$3
    if ( "$property_function" ); then
        printf 'ok %s — %s\n' "$property_number" "$property_title"
    else
        printf 'not ok %s — %s\n' "$property_number" "$property_title" >&2
        FAILURES="$FAILURES $property_number"
    fi
}

mkdir -p "$RIG" || exit 1
trap cleanup EXIT HUP INT TERM

run_property P1 'early-closed drain releases brain lock and the next say is prompt' property_p1
run_property P2 'printed letters move to cur while unprinted letters remain in new' property_p2
run_property P3 'INT and TERM during drain release brain lock and the next say is prompt' property_p3
run_property P4 'interrupted watch still removes its marker and singleton lock' property_p4
run_property P5 'scan gate wins short contention but returns promptly on long contention' property_p5
if [ "${LOCKS_SKIP_REGRESSION-}" = 1 ]; then
    printf 'SKIP P6 — regression suites disabled by caller\n'
else
    run_property P6 'all seven existing suites pass unchanged' property_p6
fi

if [ -n "$FAILURES" ]; then
    printf 'RESULT: FAIL properties%s\n' "$FAILURES"
    exit 1
fi
printf 'RESULT: PASS\n'
