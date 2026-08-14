#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
STOP=$ROOT/plugin/hooks/stop.sh
RIG=$HOME/.khala-minds-test-$$
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
    init_node=$2
    KHALA_HOME=$init_target "$KHALA" init "$init_node" >/dev/null \
        2>"$RIG/init-$init_node.err" ||
        die "init $init_node failed: $(tr '\n' ' ' < "$RIG/init-$init_node.err")"
}

write_spoke_config() {
    config_home=$1
    config_self=$2
    config_hub=$3
    config_tmp=$config_home/tmp/config.minds.$$
    {
        printf 'self %s\n' "$config_self"
        printf 'peer %s %s\n' "$config_self" "$config_home"
        printf 'peer b200 %s\n' "$config_hub"
        printf 'mailbox b200\n'
        printf 'ttl 120\n'
        printf 'retain 30\n'
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

archive_month() {
    month_epoch=$1
    month_value=$(date -u -r "$month_epoch" '+%Y/%m' 2>/dev/null) || month_value=
    if [ -n "$month_value" ]; then
        printf '%s\n' "$month_value"
        return 0
    fi
    date -u -d "@$month_epoch" '+%Y/%m'
}

archive_path() {
    archive_home=$1
    archive_stream=$2
    archive_node=$3
    archive_id=$4
    archive_epoch=${archive_id%%.*}
    archive_ym=$(archive_month "$archive_epoch") || return 1
    printf '%s/archive/streams/%s/%s/%s/%s\n' \
        "$archive_home" "$archive_stream" "$archive_node" "$archive_ym" "$archive_id"
}

add_preserve() {
    preserve_home=$1
    shift
    printf 'preserve' >> "$preserve_home/config" || return 1
    for preserve_stream in "$@"; do
        printf ' %s' "$preserve_stream" >> "$preserve_home/config" || return 1
    done
    printf '\n' >> "$preserve_home/config"
}

prepare_hook() {
    HOOK_HOME=$RIG/hook-home
    HOOK_SHIM=$RIG/hook-shim
    mkdir -p "$HOOK_HOME" "$HOOK_SHIM" || return 1
    if [ ! -e "$HOOK_SHIM/khala" ]; then
        ln -s "$KHALA" "$HOOK_SHIM/khala" || return 1
    fi
}

run_start() {
    start_home=$1
    start_project=$2
    start_output=$3
    start_input=$4
    printf '%s\n' "$start_input" | \
        HOME=$HOOK_HOME KHALA_HOME=$start_home CLAUDE_PROJECT_DIR=$start_project \
        PATH=$HOOK_SHIM:/usr/bin:/bin "$START" > "$start_output" 2> "$start_output.err"
}

latest_generation() {
    generation_dir=$1
    generation_list=$RIG/generations.$$
    : > "$generation_list"
    for generation_path in "$generation_dir"/*; do
        [ -f "$generation_path" ] || continue
        basename "$generation_path" >> "$generation_list"
    done
    sort -t. -k1,1n -k2,2n "$generation_list" | tail -n 1
    rm -f "$generation_list"
}

property_m1() {
    home_a=$RIG/m1-alpha
    home_h=$RIG/m1-b200
    init_home "$home_a" alpha
    init_home "$home_h" b200
    write_spoke_config "$home_a" alpha "$home_h" || die "could not write spoke config"
    initial_gen=$(KHALA_HOME=$home_a KHALA_SESSION=worker "$KHALA" mind -m 'V1') || die "V1 failed"
    rollback_epoch=$(( ${initial_gen%%.*} + 10 ))
    gen1=$rollback_epoch.0
    sed "s/^Generation: $initial_gen$/Generation: $gen1/" \
        "$home_a/minds/alpha/worker/$initial_gen" > "$home_a/tmp/m1-rollback" ||
        die "could not forge future last generation"
    mv "$home_a/tmp/m1-rollback" "$home_a/minds/alpha/worker/$gen1" || die "could not install future generation"
    unlink "$home_a/minds/alpha/worker/$initial_gen" || die "could not remove initial generation"
    cp "$home_a/minds/alpha/worker/$gen1" "$RIG/m1-v1" || die "could not save V1"
    gen2=$(KHALA_HOME=$home_a KHALA_SESSION=worker "$KHALA" mind -m 'V2') || die "V2 failed"
    [ "$gen2" = "$rollback_epoch.1" ] || die "clock rollback did not increment the logical counter"
    [ "$(printf '%s\n%s\n' "$gen1" "$gen2" | sort -t. -k1,1n -k2,2n | tail -n 1)" = "$gen2" ] ||
        die "generation did not increase monotonically"
    mkdir -p "$home_h/minds/alpha/worker" || die "could not make delayed shard"
    cp "$RIG/m1-v1" "$home_h/minds/alpha/worker/$gen1" || die "could not stage delayed V1"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/m1-sync.err" || die "mind sync failed"
    KHALA_HOME=$home_a "$KHALA" minds >"$RIG/m1.out" || die "minds failed"
    grep -Fq 'V2' "$RIG/m1.out" || die "delayed V1 displaced V2"
    grep -Fq 'V1' "$RIG/m1.out" && die "minds displayed delayed V1"
    [ "$(latest_generation "$home_a/minds/alpha/worker")" = "$gen2" ] || die "local GC did not retain max generation"
}

property_m2() {
    home=$RIG/m2-home
    init_home "$home" alpha
    old=$(KHALA_HOME=$home KHALA_SESSION=worker "$KHALA" mind -m 'withdraw me') || die "mind failed"
    cp "$home/minds/alpha/worker/$old" "$RIG/m2-old" || die "could not save old mind"
    clear=$(KHALA_HOME=$home KHALA_SESSION=worker "$KHALA" mind --clear) || die "clear failed"
    cp "$RIG/m2-old" "$home/minds/alpha/worker/$old" || die "could not reintroduce old mind"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/m2.out" || die "minds failed"
    grep -Fq 'withdraw me' "$RIG/m2.out" && die "clear was revived by an old generation"
    grep -qx 'State: cleared' "$home/minds/alpha/worker/$clear" || die "clear generation is not cleared"
}

property_m3() {
    home=$RIG/m3-home
    project=$RIG/m3-project
    init_home "$home" alpha
    prepare_hook || die "could not prepare hook rig"
    mkdir -p "$project" || die "could not create project"
    printf 'same-name\n' > "$project/.khala-session"
    KHALA_HOME=$home KHALA_SESSION=same-name "$KHALA" profile --effort high >/dev/null || die "effort declaration failed"
    run_start "$home" "$project" "$RIG/m3-start-a.out" \
        '{"hook_event_name":"SessionStart","source":"startup","model":"claude-a"}' || die "Start A failed"
    KHALA_HOME=$home KHALA_SESSION=same-name "$KHALA" mind -m 'B owns this' --stance focused >/dev/null ||
        die "B mind failed"
    run_start "$home" "$project" "$RIG/m3-start-b.out" \
        '{"hook_event_name":"SessionStart","source":"resume","model":"claude-b"}' || die "Start B failed"
    before_model_less=$(latest_generation "$home/minds/alpha/same-name")
    run_start "$home" "$project" "$RIG/m3-start-no-model.out" \
        '{"hook_event_name":"SessionStart","source":"resume"}' || die "model-less Start failed"
    after_model_less=$(latest_generation "$home/minds/alpha/same-name")
    [ "$before_model_less" = "$after_model_less" ] || die "model-less Start invented a profile generation"
    count_after_model_less=$(count_files "$home/minds/alpha/same-name")
    printf '{"stop_hook_active":false}\n' | \
        HOME=$HOOK_HOME KHALA_HOME=$home CLAUDE_PROJECT_DIR=$project \
        PATH=$HOOK_SHIM:/usr/bin:/bin "$STOP" >/dev/null 2>"$RIG/m3-stop.err" || die "late Stop failed"
    after=$(count_files "$home/minds/alpha/same-name")
    [ "$count_after_model_less" -eq "$after" ] || die "Stop created a generation"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/m3.out" || die "minds failed"
    grep -Fq 'B owns this' "$RIG/m3.out" || die "Start/Stop changed the mind family"
    grep -Fq 'claude-b' "$RIG/m3.out" || die "latest Start model was not declared"
    grep -Fq 'high' "$RIG/m3.out" || die "Start model update changed effort"
}

property_m4() {
    home=$RIG/m4-home
    project=$RIG/m4-project
    init_home "$home" alpha
    KHALA_HOME=$home KHALA_SESSION=retired-one "$KHALA" mind -m 'old focus' >/dev/null || die "mind failed"
    KHALA_HOME=$home "$KHALA" retire retired-one >/dev/null || die "retire failed"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/m4-retired.out" || die "retired minds failed"
    grep -q '^retired-one@alpha' "$RIG/m4-retired.out" && die "retired identity stayed visible"
    prepare_hook || die "could not prepare hook rig"
    mkdir -p "$project"
    printf 'retired-one\n' > "$project/.khala-session"
    run_start "$home" "$project" "$RIG/m4-start.out" \
        '{"hook_event_name":"SessionStart","source":"resume","model":"claude-new"}' || die "restart hook failed"
    KHALA_HOME=$home KHALA_SESSION=retired-one "$KHALA" say -m 'presence only' >/dev/null || die "revival say failed"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/m4-revived.out" || die "revived minds failed"
    grep -q '^retired-one@alpha' "$RIG/m4-revived.out" || die "revived presence missing"
    grep -Fq 'old focus' "$RIG/m4-revived.out" && die "restart or utterance revived cleared mind"
    return 0
}

property_m5() {
    home=$RIG/m5-home
    init_home "$home" alpha
    old=$(( $(date +%s) - 7200 ))
    generation=$old.0
    mkdir -p "$home/minds/alpha/aged"
    {
        printf 'Generation: %s\nSession: aged\nNode: alpha\nState: active\n' "$generation"
        printf 'Model: claude-aged\nEffort: high\nRole: reviewer\nCharge: D14\n'
        printf 'Focus: old focus\nStance: focused\n'
        printf 'Declared-State: %s\nDeclared-Model: %s\nDeclared-Effort: %s\n' "$old" "$old" "$old"
        printf 'Declared-Role: %s\nDeclared-Charge: %s\nDeclared-Focus: %s\nDeclared-Stance: %s\n\n' \
            "$old" "$old" "$old" "$old"
    } > "$home/minds/alpha/aged/$generation"
    printf '%s\n' "$(date +%s)" > "$home/presence/aged@alpha"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/m5.out" || die "minds failed"
    grep -q '^ADDRESS.*MODEL_AGE.*FOCUS_AGE' "$RIG/m5.out" || die "per-field age columns missing"
    grep -q '^aged@alpha.*claude-aged.*old focus.*stale' "$RIG/m5.out" || die "stale mind was shown as fresh"
}

property_m6() {
    home_a=$RIG/m6-alpha
    home_h=$RIG/m6-b200
    init_home "$home_a" alpha
    init_home "$home_h" b200
    write_spoke_config "$home_a" alpha "$home_h" || die "could not write spoke config"
    generation=$(KHALA_HOME=$home_a KHALA_SESSION=worker "$KHALA" mind -m 'original') || die "mind failed"
    original=$home_a/minds/alpha/worker/$generation
    mkdir -p "$home_h/minds/alpha/worker"
    sed 's/^Focus: original$/Focus: conflict/' "$original" > "$home_h/minds/alpha/worker/$generation"
    if KHALA_HOME=$home_a "$KHALA" sync >"$RIG/m6.out" 2>"$RIG/m6.err"; then
        die "same-generation conflict was not a large error"
    fi
    grep -qx 'Focus: original' "$original" || die "conflict overwrote the original"
    grep -q 'digest.*불일치\|불일치.*digest' "$RIG/m6.err" || die "conflict warning was unclear"
    conflict_count=$(count_files "$home_a/spool/dead")
    [ "$conflict_count" -ge 1 ] || die "conflicting generation was not quarantined"
}

property_m7() {
    home=$RIG/m7-home
    init_home "$home" alpha
    add_preserve "$home" all || die "could not enable preserver"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" join khala --from-start >/dev/null
    cursor_before=$(cksum "$home/join/reader/khala")
    KHALA_HOME=$home KHALA_SESSION=worker "$KHALA" mind -m 'private ambient state' >/dev/null || die "mind failed"
    if KHALA_HOME=$home "$KHALA" watch --session reader --interval 1 --max-wait 2 \
        >"$RIG/m7-watch.out" 2>"$RIG/m7-watch.err"; then
        die "mind generation woke watch"
    else
        watch_status=$?
    fi
    [ "$watch_status" -eq 3 ] || die "watch exited $watch_status"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/m7-drain.out" || die "drain failed"
    grep -Fq 'private ambient state' "$RIG/m7-drain.out" && die "mind appeared in drain"
    [ "$(cksum "$home/join/reader/khala")" = "$cursor_before" ] || die "mind changed stream state"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/m7-rec.err" || die "reconcile failed"
    if [ -d "$home/archive" ] && find "$home/archive" -type f -print | grep -q .; then
        die "preserver captured a mind generation"
    fi
}

property_m8() {
    if ! PATH="$HOME/go-toolchain/bin:$PATH" bash "$ROOT/test/link-minds.sh" \
        >"$RIG/m8.out" 2>"$RIG/m8.err"; then
        die "link mind suite failed: $(tail -n 8 "$RIG/m8.err" | tr '\n' ' ')"
    fi
    grep -q '^RESULT: PASS$' "$RIG/m8.out" || die "link mind suite omitted RESULT: PASS"
}

property_m9() {
    home=$RIG/m9-home
    init_home "$home" alpha
    KHALA_HOME=$home KHALA_SESSION=joined "$KHALA" inbox >/dev/null || die "heartbeat failed"
    KHALA_HOME=$home KHALA_SESSION=joined "$KHALA" profile \
        --model claude-x --effort medium --role builder --charge D14 >/dev/null || die "profile failed"
    KHALA_HOME=$home KHALA_SESSION=joined "$KHALA" mind -m 'implement register' --stance focused >/dev/null || die "mind failed"
    printf '%s\n30\n' "$(date +%s)" > "$home/presence/orphan@alpha.watching"
    current=$(latest_generation "$home/minds/alpha/joined")
    current_file=$home/minds/alpha/joined/$current
    KHALA_HOME=$home "$KHALA" minds >"$RIG/m9.out" || die "minds failed"
    grep -q '^joined@alpha.*alive-here.*claude-x.*medium.*builder.*D14.*implement register.*focused' \
        "$RIG/m9.out" || die "joined row disagrees with physical fields"
    grep -q '^orphan@alpha.*unknown.*yes' "$RIG/m9.out" || die "watching-only presence row is missing"
    [ "$(sed -n 's/^Generation: //p' "$current_file")" = "$current" ] || die "Generation header differs from filename"
    [ "$(sed -n 's/^Session: //p' "$current_file")" = joined ] || die "Session header differs"
    [ "$(sed -n 's/^Node: //p' "$current_file")" = alpha ] || die "Node header differs"
    [ "$(KHALA_HOME=$home "$KHALA" version)" = 'khala 0.4.0' ] || die "brain version is not 0.4.0"
    grep -q '"version": "0.4.0"' "$ROOT/plugin/.claude-plugin/plugin.json" ||
        die "plugin version is not 0.4.0"
    grep -q '"hooks"' "$ROOT/plugin/.claude-plugin/plugin.json" && die "plugin manifest contains forbidden hooks key"
    return 0
}

property_p1() {
    home_before=$RIG/p1-before
    home_after=$RIG/p1-after
    home_synced=$RIG/p1-synced
    home_pruned=$RIG/p1-pruned
    shim=$RIG/p1-shim
    real_ln=$(command -v ln)
    real_rm=$(command -v rm)
    mkdir -p "$shim"
    cat > "$shim/ln" <<EOF
#!/usr/bin/env bash
if [ "\${KHALA_TEST_LN_KILL-}" = before ]; then
    kill -KILL "\$PPID"
    exit 137
fi
"$real_ln" "\$@"
status=\$?
if [ "\${KHALA_TEST_LN_KILL-}" = after ]; then
    kill -KILL "\$PPID"
fi
exit "\$status"
EOF
    cat > "$shim/rm" <<EOF
#!/usr/bin/env bash
for target in "\$@"; do
    case "\$target" in
        */streams/*/*/*)
            if [ "\${KHALA_TEST_RM_KILL-}" = before ]; then
                kill -KILL "\$PPID"
                exit 137
            fi
            ;;
    esac
done
"$real_rm" "\$@"
EOF
    chmod 755 "$shim/ln"
    chmod 755 "$shim/rm"

    init_home "$home_before" alpha
    add_preserve "$home_before" khala
    before_id=$(write_entry "$home_before" khala alpha speaker "$(date +%s)" before)
    PATH=$shim:/usr/bin:/bin KHALA_TEST_LN_KILL=before KHALA_HOME=$home_before \
        "$KHALA" reconcile >/dev/null 2>"$RIG/p1-before.err" &
    before_pid=$!
    wait "$before_pid" 2>/dev/null || :
    [ -f "$home_before/streams/khala/alpha/$before_id" ] || die "kill-before lost live"
    [ ! -e "$(archive_path "$home_before" khala alpha "$before_id")" ] || die "kill-before created archive"

    init_home "$home_after" alpha
    add_preserve "$home_after" khala
    after_id=$(write_entry "$home_after" khala alpha speaker "$(date +%s)" after)
    PATH=$shim:/usr/bin:/bin KHALA_TEST_LN_KILL=after KHALA_HOME=$home_after \
        "$KHALA" reconcile >/dev/null 2>"$RIG/p1-after.err" &
    after_pid=$!
    wait "$after_pid" 2>/dev/null || :
    [ -f "$home_after/streams/khala/alpha/$after_id" ] || die "kill-after lost live"
    after_archive=$(archive_path "$home_after" khala alpha "$after_id")
    [ -f "$after_archive" ] || die "kill-after lost archive"
    [ "$home_after/streams/khala/alpha/$after_id" -ef "$after_archive" ] ||
        die "capture did not create a hardlink"

    init_home "$home_synced" alpha
    add_preserve "$home_synced" khala
    synced_old=$(( $(date +%s) - 2592001 ))
    synced_id=$(write_entry "$home_synced" khala alpha speaker "$synced_old" synced)
    PATH=$shim:/usr/bin:/bin KHALA_TEST_RM_KILL=before KHALA_HOME=$home_synced \
        "$KHALA" reconcile >/dev/null 2>"$RIG/p1-synced.err" &
    synced_pid=$!
    wait "$synced_pid" 2>/dev/null || :
    [ -f "$home_synced/streams/khala/alpha/$synced_id" ] || die "kill-after-sync lost live"
    [ -f "$(archive_path "$home_synced" khala alpha "$synced_id")" ] || die "kill-after-sync lost archive"

    init_home "$home_pruned" alpha
    add_preserve "$home_pruned" khala
    old=$(( $(date +%s) - 2592001 ))
    pruned_id=$(write_entry "$home_pruned" khala alpha speaker "$old" pruned)
    KHALA_HOME=$home_pruned "$KHALA" reconcile >/dev/null 2>"$RIG/p1-pruned.err" || die "capture/prune failed"
    [ ! -e "$home_pruned/streams/khala/alpha/$pruned_id" ] || die "expired live was not pruned"
    [ -f "$(archive_path "$home_pruned" khala alpha "$pruned_id")" ] || die "prune lost archive"
}

property_p2() {
    home=$RIG/p2-home
    init_home "$home" alpha
    add_preserve "$home" khala
    id=$(write_entry "$home" khala alpha speaker "$(date +%s)" idempotent)
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "first capture failed"
    archived=$(archive_path "$home" khala alpha "$id")
    rm -f "$home/streams/khala/alpha/$id"
    cp "$archived" "$home/streams/khala/alpha/$id" || die "delayed rearrival failed"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "second capture failed"
    [ "$(find "$home/archive/streams/khala/alpha" -type f -name "$id" | wc -l | tr -d ' ')" -eq 1 ] ||
        die "delayed rearrival duplicated archive"
}

property_p3() {
    home=$RIG/p3-home
    init_home "$home" alpha
    add_preserve "$home" khala
    old=$(( $(date +%s) - 2592001 ))
    id=$(write_entry "$home" khala alpha speaker "$old" live-byte)
    archived=$(archive_path "$home" khala alpha "$id")
    mkdir -p "$(dirname "$archived")"
    printf 'conflicting archive byte\n' > "$archived"
    if KHALA_HOME=$home "$KHALA" stream cat khala >"$RIG/p3-cat.out" 2>"$RIG/p3-cat.err"; then
        die "cat selected one side of a digest conflict"
    fi
    [ ! -s "$RIG/p3-cat.out" ] || die "cat emitted an arbitrary conflicting byte"
    if KHALA_HOME=$home "$KHALA" reconcile >"$RIG/p3-rec.out" 2>"$RIG/p3-rec.err"; then
        die "conflicting capture was not degraded"
    fi
    [ -f "$home/streams/khala/alpha/$id" ] || die "prune deleted conflicted live"
    grep -q 'preserver degraded' "$RIG/p3-rec.err" || die "conflict was not loud"
}

property_p4() {
    home_a=$RIG/p4-alpha
    home_h=$RIG/p4-b200
    init_home "$home_a" alpha
    init_home "$home_h" b200
    write_spoke_config "$home_a" alpha "$home_h"
    add_preserve "$home_a" all
    id=$(write_entry "$home_a" khala alpha speaker "$(date +%s)" archived)
    KHALA_HOME=$home_a "$KHALA" reconcile >/dev/null || die "capture failed"
    [ -d "$home_a/archive/streams" ] || die "archive is not rooted directly under KHALA_HOME"
    [ ! -e "$home_a/streams/archive" ] || die "archive was nested under streams"
    mkdir -p "$home_a/archive/.pending" "$home_h/archive/streams/bait/node/2000/01"
    printf 'pending bait\n' > "$home_a/archive/.pending/bait"
    printf 'remote archive bait\n' > "$home_h/archive/streams/bait/node/2000/01/bait"
    KHALA_HOME=$home_a "$KHALA" sync >/dev/null 2>"$RIG/p4-sync.err" || die "sync failed"
    [ ! -e "$home_h/archive/.pending/bait" ] || die "sync pushed archive pending"
    [ ! -e "$home_a/archive/streams/bait/node/2000/01/bait" ] || die "sync pulled archive"
    [ -f "$(archive_path "$home_a" khala alpha "$id")" ] || die "local archive disappeared"
}

property_p5() {
    home=$RIG/p5-home
    shim=$RIG/p5-shim
    cross_home=$RIG/p5-cross-home
    cross_shim=$RIG/p5-cross-shim
    init_home "$home" alpha
    add_preserve "$home" khala
    old=$(( $(date +%s) - 2592001 ))
    id=$(write_entry "$home" khala alpha speaker "$old" endangered)
    mkdir -p "$shim"
    cat > "$shim/ln" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ln: No space left on device' >&2
exit 1
EOF
    chmod 755 "$shim/ln"
    if PATH=$shim:/usr/bin:/bin KHALA_HOME=$home "$KHALA" reconcile \
        >"$RIG/p5.out" 2>"$RIG/p5.err"; then
        die "archive failure was reported healthy"
    fi
    [ -f "$home/streams/khala/alpha/$id" ] || die "archive failure silently pruned live"
    grep -q 'preserver degraded' "$RIG/p5.err" || die "archive failure omitted degraded warning"

    init_home "$cross_home" alpha
    add_preserve "$cross_home" khala
    cross_id=$(write_entry "$cross_home" khala alpha speaker "$old" cross-filesystem)
    real_stat=$(command -v stat)
    mkdir -p "$cross_shim"
    cat > "$cross_shim/stat" <<EOF
#!/usr/bin/env bash
last=
for argument in "\$@"; do
    last=\$argument
done
case "\$last" in
    */archive/streams) printf '2\n' ;;
    */streams) printf '1\n' ;;
    *) "$real_stat" "\$@" ;;
esac
EOF
    chmod 755 "$cross_shim/stat"
    if PATH=$cross_shim:/usr/bin:/bin KHALA_HOME=$cross_home "$KHALA" reconcile \
        >"$RIG/p5-cross.out" 2>"$RIG/p5-cross.err"; then
        die "cross-filesystem preserver was accepted"
    fi
    [ -f "$cross_home/streams/khala/alpha/$cross_id" ] || die "cross-FS rejection pruned live"
    grep -q '다른 filesystem' "$RIG/p5-cross.err" || die "cross-FS error was unclear"
}

property_p6() {
    home=$RIG/p6-home
    init_home "$home" alpha
    add_preserve "$home" khala
    now=$(date +%s)
    first=$(write_entry "$home" khala alpha one "$((now - 2))" first)
    second=$(write_entry "$home" khala alpha two "$((now - 1))" second)
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "capture failed"
    rm -f "$home/streams/khala/alpha/$second"
    mkdir -p "$home/cursor/reader"
    printf '%s\n' "$first" > "$home/cursor/reader/khala"
    cursor_before=$(cksum "$home/cursor/reader/khala")
    KHALA_HOME=$home "$KHALA" stream cat khala -n 20 >"$RIG/p6.out" || die "merged cat failed"
    [ "$(grep -c '^--- stream khala ' "$RIG/p6.out")" -eq 2 ] || die "cat did not dedup live+archive"
    first_line=$(grep -n "$first" "$RIG/p6.out" | sed -n '1s/:.*//p')
    second_line=$(grep -n "$second" "$RIG/p6.out" | sed -n '1s/:.*//p')
    [ "$first_line" -lt "$second_line" ] || die "cat merge order differs"
    [ "$(cksum "$home/cursor/reader/khala")" = "$cursor_before" ] || die "cat changed cursor"
}

property_p7() {
    home=$RIG/p7-home
    init_home "$home" alpha
    id=$(write_entry "$home" future-stream alpha speaker "$(date +%s)" existing-live)
    [ ! -e "$(archive_path "$home" future-stream alpha "$id")" ] || die "archive pre-existed enable"
    add_preserve "$home" all
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "late enable backfill failed"
    [ -f "$(archive_path "$home" future-stream alpha "$id")" ] || die "all wildcard missed existing/future stream"
    later=$(write_entry "$home" later-stream alpha speaker "$(( $(date +%s) + 1 ))" later-live)
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "dynamic all capture failed"
    [ -f "$(archive_path "$home" later-stream alpha "$later")" ] || die "all wildcard was not dynamic"
}

property_p8() {
    home=$RIG/p8-home
    init_home "$home" alpha
    add_preserve "$home" khala
    first=$(write_entry "$home" khala alpha speaker "$(date +%s)" before-disable)
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "initial capture failed"
    first_archive=$(archive_path "$home" khala alpha "$first")
    config_tmp=$home/tmp/config.disable.$$
    sed '/^preserve /d' "$home/config" > "$config_tmp" && mv "$config_tmp" "$home/config"
    second=$(write_entry "$home" khala alpha speaker "$(( $(date +%s) + 1 ))" after-disable)
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "disabled reconcile failed"
    [ -f "$first_archive" ] || die "disable deleted existing archive"
    [ ! -e "$(archive_path "$home" khala alpha "$second")" ] || die "disable did not stop future capture"
}

property_t1() {
    if [ "${MINDS_SKIP_REGRESSION-}" = 1 ]; then
        printf 'SKIP T1 execution — focused M/P run\n'
        return 0
    fi
    for suite in local-roundtrip exchange-roundtrip hardening watch concurrency plugin streams; do
        if [ "$suite" = streams ]; then
            # T1 has already run every legacy suite that streams property 9
            # composes. Avoid recursively running that same set again under
            # plugin/link liveness load; all stream-specific properties still run.
            STREAMS_SKIP_LEGACY=1 bash "$ROOT/test/$suite.sh" \
                >"$RIG/t1-$suite.out" 2>"$RIG/t1-$suite.err"
            suite_status=$?
        elif [ "$suite" = plugin ]; then
            # Same recursion cut for plugin property 12: T1 itself just ran
            # the five legacy suites it would re-run. Plugin-specific
            # properties (1-11, 13) still run in full.
            PLUGIN_SKIP_REGRESSION=1 bash "$ROOT/test/$suite.sh" \
                >"$RIG/t1-$suite.out" 2>"$RIG/t1-$suite.err"
            suite_status=$?
        else
            bash "$ROOT/test/$suite.sh" >"$RIG/t1-$suite.out" 2>"$RIG/t1-$suite.err"
            suite_status=$?
        fi
        if [ "$suite_status" -ne 0 ]; then
            die "$suite regression failed: $(tail -n 4 "$RIG/t1-$suite.err" | tr '\n' ' ')"
        fi
        grep -q '^RESULT: PASS$' "$RIG/t1-$suite.out" || die "$suite omitted RESULT: PASS"
    done
    if [ -x "$HOME/go-toolchain/bin/go" ]; then
        PATH=$HOME/go-toolchain/bin:$PATH bash "$ROOT/test/link.sh" \
            >"$RIG/t1-link.out" 2>"$RIG/t1-link.err" ||
            die "link regression failed: $(tail -n 4 "$RIG/t1-link.err" | tr '\n' ' ')"
        grep -q '^RESULT: PASS$' "$RIG/t1-link.out" || die "link omitted RESULT: PASS"
    else
        printf 'SKIP T1 link — Go toolchain unavailable\n'
    fi
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

run_property M1 'V2 설치 후 지연 V1이 링크·rsync 양쪽으로 도착해도 현재값 V2' property_m1
run_property M2 'clear 후 지연 구세대 도착 — mind 재출현 0' property_m2
run_property M3 '같은 명의 세션 A→B 교체 후 A의 늦은 Stop 훅이 B의 상태를 못 바꾼다' property_m3
run_property M4 'retire 후 minds 표에서 즉시 소거; 재발화만으로 과거 mind 미재현' property_m4
run_property M5 'freshness 경과 시 stale 명시 표기와 필드별 Declared 나이' property_m5
run_property M6 '같은 세대·다른 바이트 = quarantine, 덮어쓰기 0' property_m6
run_property M7 'mind는 watch 비각성·drain 비출력·커서 무관·preserver 비대상' property_m7
run_property M8 'protocol 1.2 링크 전파·협상·순서역전·경주·나이 가드' property_m8
run_property M9 '3층 조인 표가 실파일과 일치' property_m9
run_property P1 'capture 각 단계 kill — live만/live+archive/archive만, 소실 없음' property_p1
run_property P2 '같은 Id 지연 재도착 — archive 중복 0' property_p2
run_property P3 'live·archive digest 상이 — cat·prune이 임의 선택하지 않고 큰 오류' property_p3
run_property P4 'archive·pending은 링크 스캔·rsync 왕복에 불출현' property_p4
run_property P5 'archive 실패·ENOSPC — live 조용한 삭제 0, degraded 소리' property_p5
run_property P6 'cat 병합 — dedup·정렬 유지·커서 불변' property_p6
run_property P7 '늦은 enable — 현재 live 창만 capture, completeness 미주장' property_p7
run_property P8 'disable — 기존 archive 잔존' property_p8
run_property T1 '기존 7+1 스위트(streams.sh 포함) 무변 통과' property_t1

if [ -n "$FAILURES" ]; then
    printf 'RESULT: FAIL properties%s\n' "$FAILURES"
    exit 1
fi
printf 'RESULT: PASS\n'
