#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
RIG=$HOME/.khala-streams-test-$$
FAILURES=
GO=${GO_BINARY-"$HOME/go-toolchain/bin/go"}
GO_TMP=$HOME/.cache/khala-go-tmp
GO_CACHE=$HOME/.cache/khala-go-cache

cleanup() {
    for cleanup_status in "$RIG"/*/runtime-root/conduit.status.json; do
        [ -f "$cleanup_status" ] || continue
        cleanup_pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$cleanup_status")
        [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || :
    done
    for cleanup_status in "$RIG"/*/run/link.status; do
        [ -f "$cleanup_status" ] || continue
        cleanup_pid=$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$cleanup_status")
        [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || :
    done
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
    init_node=$2
    KHALA_HOME=$init_target "$KHALA" init "$init_node" >/dev/null 2>"$RIG/init-$init_node.err" ||
        die "init $init_node failed: $(tr '\n' ' ' < "$RIG/init-$init_node.err")"
}

write_spoke_config() {
    config_home=$1
    config_self=$2
    config_hub=$3
    config_tmp=$config_home/tmp/config.streams.$$
    {
        printf 'self %s\n' "$config_self"
        printf 'peer %s %s\n' "$config_self" "$config_home"
        printf 'peer b200 %s\n' "$config_hub"
        printf 'mailbox b200\n'
        printf 'ttl 120\n'
        printf 'retain 30\n'
        printf 'retention-interval 0\n'
    } > "$config_tmp" || return 1
    mv "$config_tmp" "$config_home/config"
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

prepare_hook() {
    HOOK_HOME=$RIG/hook-home
    HOOK_SHIM=$RIG/hook-shim
    mkdir -p "$HOOK_HOME/.local/bin" "$HOOK_SHIM" || return 1
    cp "$ROOT/plugin/bin/khala" "$HOOK_HOME/.local/bin/khala" || return 1
    chmod 755 "$HOOK_HOME/.local/bin/khala" || return 1
    printf 'khala-plugin\n' > "$HOOK_HOME/.local/bin/.khala.plugin-receipt" || return 1
    if [ ! -e "$HOOK_SHIM/khala" ]; then
        ln -s "$KHALA" "$HOOK_SHIM/khala" || return 1
    fi
    HOOK_LINK_BIN=$RIG/khala-link
    if [ ! -x "$HOOK_LINK_BIN" ]; then
        [ -x "$GO" ] || return 1
        mkdir -p "$GO_TMP" "$GO_CACHE" || return 1
        (cd "$ROOT/link" && GOTMPDIR="$GO_TMP" GOCACHE="$GO_CACHE" CGO_ENABLED=0 \
            "$GO" build -trimpath -o "$HOOK_LINK_BIN" .) || return 1
    fi
}

run_start() {
    start_home=$1
    start_project=$2
    start_output=$3
    mkdir -p "$start_home/bin" || return 1
    if [ ! -e "$start_home/bin/khala-link" ]; then
        cp "$HOOK_LINK_BIN" "$start_home/bin/khala-link" || return 1
    else
        cmp -s "$HOOK_LINK_BIN" "$start_home/bin/khala-link" || return 1
    fi
    # stdin closed: SessionStart reads its payload with `cat`, and an inherited
    # open stdin (terminal or background-shell pipe) hangs the hook forever.
    HOME=$HOOK_HOME KHALA_HOME=$start_home CLAUDE_PROJECT_DIR=$start_project \
        KHALA_RUNTIME_DIR=$start_home/runtime-root KHALA_TEST_BOOT_ID=streams-test-boot \
        KHALA_CLAUDE_SESSION_ID=$(basename "$start_output") KHALA_SESSION_PID=$$ \
        KHALA_SESSION_KIND=interactive \
        PATH=$HOOK_SHIM:/usr/bin:/bin "$START" < /dev/null \
        > "$start_output" 2> "$start_output.err"
}

property_1() {
    home_a=$RIG/p1-alpha
    home_b=$RIG/p1-b200
    init_home "$home_a" alpha
    init_home "$home_b" b200
    [ -d "$home_a/streams" ] && [ -d "$home_a/join" ] && [ -d "$home_a/cursor" ] ||
        die "init omitted streams/join/cursor"
    grep -qx 'retain 30' "$home_a/config" || die "init omitted retain 30"
    write_spoke_config "$home_a" alpha "$home_b" || die "could not write alpha config"
    entry_id=$(KHALA_HOME=$home_a KHALA_SESSION=speaker "$KHALA" say -m 'offline thought' \
        2>"$RIG/p1-say.err") || die "offline say failed"
    entry=$home_a/streams/khala/alpha/$entry_id
    [ -f "$entry" ] || die "say did not land in the owner shard"
    grep -qx 'Type: entry' "$entry" || die "entry Type header differs"
    grep -q '^Expires:' "$entry" && die "stream entry contains Expires"
    reply_id=$(printf 'stdin thought\n' | KHALA_HOME=$home_a KHALA_SESSION=speaker \
        "$KHALA" say replies -s 'a subject' -r "$entry_id" 2>"$RIG/p1-stdin.err") ||
        die "stdin/subject/ref say failed"
    reply=$home_a/streams/replies/alpha/$reply_id
    grep -qx 'Subject: a subject' "$reply" || die "say omitted Subject"
    grep -qx "Refs: $entry_id" "$reply" || die "say omitted Refs"
    grep -qx 'stdin thought' "$reply" || die "say did not read stdin"
    KHALA_HOME=$home_a "$KHALA" sync >"$RIG/p1-sync.out" 2>"$RIG/p1-sync.err" ||
        die "recovered sync failed"
    [ -f "$home_b/streams/khala/alpha/$entry_id" ] || die "sync did not propagate the entry"
    [ -f "$home_b/streams/replies/alpha/$reply_id" ] || die "sync did not propagate the reply stream"
}

property_2() {
    home_a=$RIG/p2-alpha
    home_b=$RIG/p2-b200
    init_home "$home_a" alpha
    init_home "$home_b" b200
    write_spoke_config "$home_a" alpha "$home_b" || die "could not write alpha config"
    KHALA_HOME=$home_b KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null ||
        die "could not establish reader heartbeat"
    KHALA_HOME=$home_b KHALA_SESSION=reader "$KHALA" join khala --from-start >/dev/null ||
        die "reader join failed"
    entry_id=$(KHALA_HOME=$home_a KHALA_SESSION=speaker "$KHALA" say -m 'once only') ||
        die "say failed"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p2-a.err" || die "alpha sync failed"
    KHALA_HOME=$home_b "$KHALA" sync >/dev/null 2>"$RIG/p2-b.err" || die "b200 sync failed"
    KHALA_HOME=$home_b KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/p2-first.out" 2>"$RIG/p2-first.err" || die "first drain failed"
    grep -Fq "$entry_id" "$RIG/p2-first.out" || die "first drain missed the entry"
    KHALA_HOME=$home_b KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/p2-second.out" 2>"$RIG/p2-second.err" || die "second drain failed"
    [ "$(grep -cv '^drained: letters 0, notices 0, streams 0$' "$RIG/p2-second.out")" -eq 0 ] ||
        die "second drain redelivered an entry"
    [ "$(sed -n '1p' "$home_b/cursor/reader/khala")" = "$entry_id" ] ||
        die "cursor did not record the drained Id"
}

property_3() {
    home_a=$RIG/p3-alpha
    home_c=$RIG/p3-gamma
    home_h=$RIG/p3-b200
    init_home "$home_a" alpha
    init_home "$home_c" gamma
    init_home "$home_h" b200
    write_spoke_config "$home_a" alpha "$home_h" || die "could not write alpha config"
    write_spoke_config "$home_c" gamma "$home_h" || die "could not write gamma config"
    id_a=$(KHALA_HOME=$home_a KHALA_SESSION=one "$KHALA" say khala -m 'from alpha') ||
        die "alpha say failed"
    sleep 1
    id_c=$(KHALA_HOME=$home_c KHALA_SESSION=two "$KHALA" say khala -m 'from gamma') ||
        die "gamma say failed"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p3-a1.err" || die "alpha push failed"
    KHALA_HOME=$home_c "$KHALA" sync >/dev/null 2>"$RIG/p3-c1.err" || die "gamma merge failed"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p3-a2.err" || die "alpha merge failed"
    KHALA_HOME=$home_a "$KHALA" stream cat khala > "$RIG/p3-a.out" || die "alpha cat failed"
    KHALA_HOME=$home_c "$KHALA" stream cat khala > "$RIG/p3-c.out" || die "gamma cat failed"
    sed -n 's/^Id: //p' "$RIG/p3-a.out" > "$RIG/p3-a.ids"
    sed -n 's/^Id: //p' "$RIG/p3-c.out" > "$RIG/p3-c.ids"
    cmp -s "$RIG/p3-a.ids" "$RIG/p3-c.ids" || die "nodes disagree on merged order"
    [ "$(wc -l < "$RIG/p3-a.ids" | tr -d ' ')" -eq 2 ] || die "merged view does not have two entries"
    [ "$(sed -n '1p' "$RIG/p3-a.ids")" = "$id_a" ] || die "epoch order did not put alpha first"
    [ "$(sed -n '2p' "$RIG/p3-a.ids")" = "$id_c" ] || die "epoch order did not put gamma second"
}

property_4() {
    home=$RIG/p4-home
    project=$RIG/p4-project
    init_home "$home" alpha
    prepare_hook || die "could not prepare hook rig"
    mkdir -p "$project" || die "could not make hook project"
    printf 'commons-reader\n' > "$project/.khala-session"
    run_start "$home" "$project" "$RIG/p4-start-1.out" || die "first SessionStart failed"
    grep -q '^joined ' "$home/join/commons-reader/khala" || die "commons was not auto-joined"
    KHALA_HOME=$home KHALA_SESSION=commons-reader "$KHALA" leave khala >/dev/null || die "leave failed"
    run_start "$home" "$project" "$RIG/p4-start-2.out" || die "second SessionStart failed"
    grep -q '^left ' "$home/join/commons-reader/khala" || die "SessionStart overwrote left"
    KHALA_HOME=$home KHALA_SESSION=commons-reader "$KHALA" join khala >/dev/null || die "rejoin failed"
    grep -q '^joined ' "$home/join/commons-reader/khala" || die "rejoin did not restore joined"
}

property_5() {
    home=$RIG/p5-home
    init_home "$home" alpha
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null || die "reader heartbeat failed"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" join khala --from-start >/dev/null || die "join failed"
    KHALA_HOME=$home KHALA_SESSION=mailer "$KHALA" send reader@alpha -m 'mail-first-1' >/dev/null ||
        die "first mail failed"
    KHALA_HOME=$home KHALA_SESSION=mailer "$KHALA" send reader@alpha -m 'mail-first-2' >/dev/null ||
        die "second mail failed"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "mail reconcile failed"
    item=1
    while [ "$item" -le 22 ]; do
        KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say khala -m "stream-body-$item" \
            >> "$RIG/p5-say.ids" || die "say $item failed"
        item=$((item + 1))
    done
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --max-n 20 --max-bytes 65536 \
        >"$RIG/p5-first.out" 2>"$RIG/p5-first.err" || die "bounded drain failed"
    [ "$(grep -c '^--- .* ---$' "$RIG/p5-first.out")" -eq 20 ] || die "shared count cap was not 20"
    first_stream_line=$(grep -n '^--- stream ' "$RIG/p5-first.out" | sed -n '1s/:.*//p')
    second_mail_line=$(grep -n '^--- .* ---$' "$RIG/p5-first.out" | sed -n '2s/:.*//p')
    [ -n "$first_stream_line" ] && [ "$second_mail_line" -lt "$first_stream_line" ] ||
        die "mail was not drained before streams"
    grep -qx 'stream khala: 4건 더' "$RIG/p5-first.out" || die "stream remainder summary differs"
    drained_cursor=$(sed -n '1p' "$home/cursor/reader/khala")
    grep -Fq -- "--- stream khala $drained_cursor ---" "$RIG/p5-first.out" ||
        die "cursor advanced beyond actual output"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/p5-second.out" 2>"$RIG/p5-second.err" || die "continuation drain failed"
    [ "$(grep -c '^--- stream ' "$RIG/p5-second.out")" -eq 4 ] || die "continuation did not drain four"
    ! grep -q 'mail-first' "$RIG/p5-second.out" || die "mail redelivered on continuation"
}

property_6() {
    home_a=$RIG/p6-alpha
    home_h=$RIG/p6-b200
    init_home "$home_a" alpha
    init_home "$home_h" b200
    write_spoke_config "$home_a" alpha "$home_h" || die "could not write alpha config"
    now=$(date +%s)
    old=$((now - 2592001))
    old_id=$(write_entry "$home_a" khala alpha ancient "$old" 'expired thought') || die "old entry fixture failed"
    mkdir -p "$home_h/streams/khala/alpha"
    cp "$home_a/streams/khala/alpha/$old_id" "$home_h/streams/khala/alpha/$old_id"
    KHALA_HOME=$home_a "$KHALA" reconcile >/dev/null 2>"$RIG/p6-a-rec.err" || die "alpha prune failed"
    KHALA_HOME=$home_h "$KHALA" reconcile >/dev/null 2>"$RIG/p6-h-rec.err" || die "hub prune failed"
    [ ! -e "$home_a/streams/khala/alpha/$old_id" ] || die "alpha retained expired entry"
    [ ! -e "$home_h/streams/khala/alpha/$old_id" ] || die "hub retained expired entry"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p6-sync.err" || die "post-prune sync failed"
    [ ! -e "$home_a/streams/khala/alpha/$old_id" ] || die "sync resurrected expired entry"
    KHALA_HOME=$home_a KHALA_SESSION=laggard "$KHALA" inbox --drain >/dev/null
    mkdir -p "$home_a/join/laggard" "$home_a/cursor/laggard"
    printf 'joined 0\n' > "$home_a/join/laggard/khala"
    printf '%s\n' "$old_id" > "$home_a/cursor/laggard/khala"
    KHALA_HOME=$home_a KHALA_SESSION=laggard "$KHALA" inbox --drain >"$RIG/p6-lost.out" ||
        die "laggard drain failed"
    grep -q '커서 이전 항목들이 retention을 지나 소멸했습니다' "$RIG/p6-lost.out" ||
        die "retention-loss notice was omitted"

    KHALA_HOME=$home_a KHALA_SESSION=flight-reader "$KHALA" inbox >/dev/null ||
        die "in-flight reader heartbeat failed"
    KHALA_HOME=$home_a KHALA_SESSION=flight-reader "$KHALA" join flight --from-start >/dev/null ||
        die "in-flight reader join failed"
    flight_epoch=$(( $(date +%s) - 2678400 ))
    flight_id=$(write_entry "$home_a" flight alpha stale "$flight_epoch" 'in-flight expired') ||
        die "in-flight expired fixture failed"
    flight_dir=$home_a/streams/flight/alpha
    flight_fixture=$home_a/tmp/$flight_id.fixture
    cp "$flight_dir/$flight_id" "$flight_fixture" || die "could not preserve in-flight fixture"
    rm -f "$flight_dir/$flight_id"
    flight_control=$home_a/tmp/inject-expired
    : > "$flight_control"
    (
        while [ -f "$flight_control" ]; do
            cp "$flight_fixture" "$flight_dir/.$flight_id.incoming" || exit 1
            mv "$flight_dir/.$flight_id.incoming" "$flight_dir/$flight_id" || exit 1
            sleep 0.02
        done
    ) &
    flight_inject_pid=$!
    if KHALA_HOME=$home_a "$KHALA" watch --session flight-reader --interval 1 --max-wait 3 \
        >"$RIG/p6-flight-watch.out" 2>"$RIG/p6-flight-watch.err"; then
        rm -f "$flight_control"
        wait "$flight_inject_pid" 2>/dev/null || :
        die "in-flight expired entry woke watch"
    else
        flight_watch_status=$?
    fi
    [ "$flight_watch_status" -eq 3 ] || die "in-flight watch exited $flight_watch_status"
    : > "$RIG/p6-flight-drain.out"
    flight_attempt=1
    while [ "$flight_attempt" -le 8 ]; do
        KHALA_HOME=$home_a KHALA_SESSION=flight-reader "$KHALA" inbox --drain \
            >>"$RIG/p6-flight-drain.out" 2>"$RIG/p6-flight-drain.err" ||
            die "in-flight drain attempt $flight_attempt failed"
        flight_attempt=$((flight_attempt + 1))
    done
    rm -f "$flight_control"
    wait "$flight_inject_pid" || die "in-flight injector failed"
    [ ! -s "$RIG/p6-flight-watch.out" ] || die "expired watch produced output"
    [ "$(grep -cv '^drained: letters 0, notices 0, streams 0$' "$RIG/p6-flight-drain.out")" -eq 0 ] ||
        die "expired entry appeared in drain"
    [ ! -e "$home_a/cursor/flight-reader/flight" ] || die "expired entry advanced the cursor"
}

property_7() {
    home=$RIG/p7-home
    init_home "$home" alpha
    KHALA_HOME=$home KHALA_SESSION=ear "$KHALA" inbox --drain >/dev/null
    KHALA_HOME=$home KHALA_SESSION=ear "$KHALA" join khala >/dev/null || die "loud join failed"
    KHALA_HOME=$home "$KHALA" watch --session ear --interval 1 --max-wait 5 \
        >"$RIG/p7-loud.out" 2>"$RIG/p7-loud.err" &
    loud_pid=$!
    sleep 1
    loud_id=$(KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say khala -m 'wake') || die "wake say failed"
    wait "$loud_pid" || die "joined-stream watch did not wake"
    grep -Fq "$loud_id" "$RIG/p7-loud.out" || die "watch output omitted stream Id"
    KHALA_HOME=$home KHALA_SESSION=other-ear "$KHALA" inbox --drain >/dev/null
    KHALA_HOME=$home KHALA_SESSION=other-ear "$KHALA" join khala >/dev/null || die "second join failed"
    KHALA_HOME=$home "$KHALA" watch --session other-ear --interval 1 --max-wait 2 \
        >"$RIG/p7-other.out" 2>"$RIG/p7-other.err" &
    other_pid=$!
    sleep 1
    KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say private -m 'do not wake' >/dev/null ||
        die "nonjoined say failed"
    if wait "$other_pid"; then
        die "nonjoined stream woke watch"
    else
        other_status=$?
    fi
    [ "$other_status" -eq 3 ] || die "nonjoined watch exited $other_status instead of timeout"
}

run_link_streams_suite() {
    link_streams_status=$RIG/link-streams.status
    if [ -f "$link_streams_status" ]; then
        grep -qx PASS "$link_streams_status"
        return
    fi
    if PATH=$HOME/go-toolchain/bin:$PATH bash "$ROOT/test/link-streams.sh" \
        >"$RIG/link-streams.out" 2>"$RIG/link-streams.err"; then
        printf 'PASS\n' > "$link_streams_status"
        return 0
    fi
    printf 'FAIL\n' > "$link_streams_status"
    return 1
}

property_8() {
    run_link_streams_suite || die "link stream suite failed: $(tail -n 4 "$RIG/link-streams.err" | tr '\n' ' ')"
    for property in 8a 8b 8c L1 L2 H1 H2; do
        grep -q "^ok $property —" "$RIG/link-streams.out" || die "link stream suite omitted $property"
    done
}

property_10() {
    run_link_streams_suite || die "link stream suite failed: $(tail -n 4 "$RIG/link-streams.err" | tr '\n' ' ')"
    grep -q '^ok 10 —' "$RIG/link-streams.out" || die "link stream suite omitted property 10"
}

property_9() {
    if [ "${STREAMS_SKIP_LEGACY-}" = 1 ]; then
        printf 'SKIP property 9 execution — RED-only run\n'
        return 0
    fi
    for suite in local-roundtrip exchange-roundtrip hardening watch concurrency plugin; do
        if ! bash "$ROOT/test/$suite.sh" >"$RIG/p9-$suite.out" 2>"$RIG/p9-$suite.err"; then
            die "$suite regression failed: $(tail -n 3 "$RIG/p9-$suite.err" | tr '\n' ' ')"
        fi
        grep -q '^RESULT: PASS$' "$RIG/p9-$suite.out" || die "$suite omitted RESULT: PASS"
    done
    if [ -x "$HOME/go-toolchain/bin/go" ]; then
        PATH=$HOME/go-toolchain/bin:$PATH bash "$ROOT/test/link.sh" \
            >"$RIG/p9-link.out" 2>"$RIG/p9-link.err" ||
            die "link regression failed: $(tail -n 3 "$RIG/p9-link.err" | tr '\n' ' ')"
        grep -q '^RESULT: PASS$' "$RIG/p9-link.out" || die "link omitted RESULT: PASS"
    else
        printf 'SKIP property 9 link — Go toolchain unavailable\n'
    fi
}

property_11() {
    for runtime in "$ROOT/bin/khala" "$ROOT/plugin/bin/khala" "$ROOT/plugin/hooks/lib.sh" \
        "$ROOT/plugin/hooks/session-start.sh" "$ROOT/plugin/hooks/stop.sh"; do
        bash -n "$runtime" || die "bash syntax failed: $runtime"
    done
    if grep -En 'declare[[:space:]]+-A|mapfile|readarray|\$\{[^}]*,,|\$\{![^}]*\[@\]' \
        "$ROOT/bin/khala" "$ROOT/plugin/bin/khala" "$ROOT"/plugin/hooks/*.sh >"$RIG/p11-bash4.out"; then
        die "bash-4-only runtime construct found"
    fi
    if grep -R -nE '(^|[[:space:]=])/tmp(/|[[:space:]]|$)' \
        "$ROOT/bin/khala" "$ROOT/plugin/hooks" "$ROOT/plugin/skills" \
        "$ROOT/plugin/.claude-plugin" >"$RIG/p11-tmp.out"; then
        die "runtime references the system temporary directory"
    fi
    if grep -R -n 'jq' "$ROOT/bin/khala" "$ROOT/plugin/hooks" "$ROOT/plugin/skills" \
        "$ROOT/plugin/.claude-plugin" >"$RIG/p11-jq.out"; then
        die "runtime references jq"
    fi
    if grep -En '^[[:space:]]*tmux([[:space:]]|$)|signal-send|kill[^#]*(CLAUDE|SESSION|PPID)' \
        "$ROOT"/plugin/hooks/*.sh >"$RIG/p11-r13.out"; then
        die "R13-forbidden hook action found"
    fi
    cmp -s "$ROOT/bin/khala" "$ROOT/plugin/bin/khala" || die "bundled CLI differs"
}

property_12() {
    home=$RIG/p12-home
    init_home "$home" alpha
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" join khala --from-start >/dev/null || die "join failed"
    first=$(KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say -m 'visible first') || die "first say failed"
    sleep 1
    second=$(KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say -m 'visible second') || die "second say failed"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" streams >"$RIG/p12-streams.out" || die "streams failed"
    grep -Eq "^khala[[:space:]]+joined[[:space:]]+2[[:space:]]+$second$" "$RIG/p12-streams.out" ||
        die "streams row disagrees with two physical files"
    KHALA_HOME=$home "$KHALA" stream cat khala -n 1 >"$RIG/p12-cat.out" || die "stream cat failed"
    grep -Fq "$second" "$RIG/p12-cat.out" || die "cat omitted latest physical file"
    grep -Fq 'visible second' "$RIG/p12-cat.out" || die "cat omitted latest body"
    if grep -Fq "$first" "$RIG/p12-cat.out"; then
        die "cat -n 1 displayed an older file"
    fi
    return 0
}

property_13() {
    home_a=$RIG/p13-alpha
    home_h=$RIG/p13-b200
    init_home "$home_a" alpha
    init_home "$home_h" b200
    write_spoke_config "$home_a" alpha "$home_h" || die "could not write alpha config"
    old=$(( $(date +%s) - 2592001 ))
    printf '%s\n' "$old" > "$home_a/presence/ghost@alpha"
    printf '%s\n' "$old" > "$home_h/presence/ghost@alpha"
    KHALA_HOME=$home_a "$KHALA" reconcile >/dev/null || die "alpha presence GC failed"
    KHALA_HOME=$home_h "$KHALA" reconcile >/dev/null || die "hub presence GC failed"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p13-gc-sync.err" || die "presence post-GC sync failed"
    [ ! -e "$home_a/presence/ghost@alpha" ] && [ ! -e "$home_h/presence/ghost@alpha" ] ||
        die "old heartbeat survived or revived"
    KHALA_HOME=$home_a KHALA_SESSION=restarter "$KHALA" say -m 'before retirement' >/dev/null ||
        die "pre-retire say failed"
    KHALA_HOME=$home_a "$KHALA" retire restarter >/dev/null || die "retire failed"
    grep -q '^retired ' "$home_a/presence/restarter@alpha" || die "retired state not written"
    KHALA_HOME=$home_a "$KHALA" presence >"$RIG/p13-retired.out" || die "presence failed"
    grep -q '^restarter@alpha' "$RIG/p13-retired.out" && die "retired identity remained visible"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p13-retire-sync.err" || die "retire sync failed"
    grep -q '^retired ' "$home_h/presence/restarter@alpha" || die "retirement did not project"
    KHALA_HOME=$home_h "$KHALA" presence >"$RIG/p13-hub-presence.out" || die "hub presence failed"
    grep -q '^restarter@alpha' "$RIG/p13-hub-presence.out" && die "projection shows retired identity"
    KHALA_HOME=$home_a KHALA_SESSION=restarter "$KHALA" say -m 'revived' >/dev/null || die "revival say failed"
    KHALA_HOME=$home_a "$KHALA" presence >"$RIG/p13-revived.out" || die "revived presence failed"
    grep -q '^restarter@alpha.*alive-here' "$RIG/p13-revived.out" || die "say did not revive identity"
    if KHALA_HOME=$home_a "$KHALA" retire restarter@b200 >"$RIG/p13-remote.out" 2>"$RIG/p13-remote.err"; then
        die "remote retirement unexpectedly succeeded"
    fi
    grep -q '타 노드' "$RIG/p13-remote.err" || die "remote retirement error was unclear"
}

property_14() {
    home=$RIG/p14-home
    init_home "$home" alpha
    future=$(( $(date +%s) + 90000 ))  # > now+86400 with slack: the check runs seconds later under load
    future_id=$(write_entry "$home" khala alpha timewarp "$future" 'future reconcile') || die "future fixture failed"
    if KHALA_HOME=$home "$KHALA" reconcile >"$RIG/p14-rec.out" 2>"$RIG/p14-rec.err"; then
        :
    fi
    [ ! -e "$home/streams/khala/alpha/$future_id" ] || die "future entry remained in live stream"
    grep -Fq "$future_id" "$RIG/p14-rec.err" || die "future quarantine warning omitted Id"
    grep -q '미래' "$RIG/p14-rec.err" || die "future quarantine reason was silent"
    [ "$(count_files "$home/spool/dead")" -ge 1 ] || die "future entry was not quarantined"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" join khala --from-start >/dev/null || die "join failed"
    future2=$((future + 1))
    future2_id=$(write_entry "$home" khala alpha timewarp "$future2" 'future drain') || die "second future fixture failed"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/p14-drain.out" 2>"$RIG/p14-drain.err" || die "future drain failed"
    grep -q 'future drain' "$RIG/p14-drain.out" && die "drain displayed a future entry"
    [ ! -e "$home/streams/khala/alpha/$future2_id" ] || die "drain left future entry live"
    grep -Fq "$future2_id" "$RIG/p14-drain.err" || die "drain quarantine warning omitted Id"
}

property_15() {
    home=$RIG/p15-home
    project=$RIG/p15-project
    init_home "$home" alpha
    KHALA_HOME=$home KHALA_SESSION=quiet-reader "$KHALA" inbox --drain >/dev/null
    KHALA_HOME=$home KHALA_SESSION=quiet-reader "$KHALA" join khala --from-start --quiet >/dev/null ||
        die "quiet join failed"
    first=$(KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say -m 'quiet still drains') || die "say failed"
    KHALA_HOME=$home KHALA_SESSION=quiet-reader "$KHALA" inbox --drain >"$RIG/p15-drain.out" ||
        die "quiet drain failed"
    grep -Fq "$first" "$RIG/p15-drain.out" || die "quiet stream was excluded from drain"
    KHALA_HOME=$home "$KHALA" watch --session quiet-reader --interval 1 --max-wait 2 \
        >"$RIG/p15-watch.out" 2>"$RIG/p15-watch.err" &
    quiet_pid=$!
    sleep 1
    KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say -m 'quiet must not wake' >/dev/null || die "second say failed"
    if wait "$quiet_pid"; then
        die "quiet stream woke watch"
    else
        quiet_status=$?
    fi
    [ "$quiet_status" -eq 3 ] || die "quiet watch exited $quiet_status"
    prepare_hook || die "could not prepare hook rig"
    mkdir -p "$project"
    printf 'quiet-reader\n' > "$project/.khala-session"
    run_start "$home" "$project" "$RIG/p15-start.out" || die "SessionStart failed"
    grep -q '^quiet ' "$home/join/quiet-reader/khala" || die "SessionStart overwrote quiet"
}

property_16() {
    home=$RIG/p16-home
    init_home "$home" alpha
    config_tmp=$home/tmp/config.retain.$$
    sed 's/^retain 30$/retain 60/' "$home/config" > "$config_tmp"
    mv "$config_tmp" "$home/config"
    old=$(( $(date +%s) - 2678400 ))
    old_id=$(write_entry "$home" khala alpha speaker "$old" 'already consumed') || die "old entry fixture failed"
    for session in living absent retired-one; do
        mkdir -p "$home/join/$session" "$home/cursor/$session"
        printf 'joined %s\n' "$old" > "$home/join/$session/khala"
        printf '%s\n' "$old_id" > "$home/cursor/$session/khala"
    done
    printf '%s\n' "$old" > "$home/presence/living@alpha"
    printf 'retired %s\n' "$(date +%s)" > "$home/presence/retired-one@alpha"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/p16-rec.err" || die "state GC reconcile failed"
    [ -f "$home/join/living/khala" ] && [ -f "$home/cursor/living/khala" ] ||
        die "living session state was collected"
    [ ! -e "$home/join/absent" ] && [ ! -e "$home/cursor/absent" ] ||
        die "absent session state remained"
    [ ! -e "$home/join/retired-one" ] && [ ! -e "$home/cursor/retired-one" ] ||
        die "retired session state remained"
    KHALA_HOME=$home KHALA_SESSION=living "$KHALA" inbox --drain >"$RIG/p16-drain.out" ||
        die "living drain failed"
    if grep -q 'already consumed' "$RIG/p16-drain.out"; then
        die "preserved cursor redelivered an entry"
    fi
    return 0
}

run_property() {
    number=$1
    title=$2
    function_name=$3
    if ( "$function_name" ); then
        printf 'ok %s — %s\n' "$number" "$title"
    else
        printf 'not ok %s — %s\n' "$number" "$title" >&2
        FAILURES="$FAILURES $number"
    fi
}

mkdir -p "$RIG" || exit 1
trap cleanup EXIT HUP INT TERM

run_property 1 'offline say lands durably and sync propagates it' property_1
run_property 2 'sync-only delivery advances a no-redelivery cursor' property_2
run_property 3 'publisher shards merge in identical epoch/Id order' property_3
run_property 4 'SessionStart commons auto-join respects leave and rejoin' property_4
run_property 5 'mail and streams share caps with mail priority and exact cursor advancement' property_5
run_property 6 'retention prunes independently, cannot revive, and reports cursor loss' property_6
run_property 7 'watch wakes only for joined loud streams' property_7
if [ -x "$HOME/go-toolchain/bin/go" ]; then
    run_property 8 'link streams propagate, negotiate minor 0, avoid echo, and quarantine future epochs' property_8
else
    printf 'SKIP 8 — Go toolchain unavailable\n'
fi
run_property 9 'all seven legacy suites remain green' property_9
if [ -x "$HOME/go-toolchain/bin/go" ]; then
    run_property 10 'link and rsync race converges to one file and one drain' property_10
else
    printf 'SKIP 10 — Go toolchain unavailable\n'
fi
run_property 11 'R13, bash 3.2, no-jq, no-system-temp audits remain green' property_11
run_property 12 'streams and stream cat agree with physical files' property_12
run_property 13 'presence ages, retires, projects, and revives correctly' property_13
run_property 14 'future-epoch entries are quarantined loudly' property_14
run_property 15 'quiet streams drain without waking and survive SessionStart' property_15
run_property 16 'only retired or absent session stream state is collected' property_16

if [ -n "$FAILURES" ]; then
    printf 'RESULT: FAIL properties%s\n' "$FAILURES"
    exit 1
fi
printf 'RESULT: PASS\n'
