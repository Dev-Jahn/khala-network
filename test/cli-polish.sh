#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
RIG=$HOME/.khala-cli-polish-$$
FAILURES=

cleanup() {
    rm -rf -- "$RIG"
}

die() {
    printf '    %s\n' "$*" >&2
    exit 1
}

count_files() {
    count_dir=$1
    count=0
    for count_path in "$count_dir"/*; do
        [ -f "$count_path" ] || continue
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

init_home() {
    init_target=$1
    KHALA_HOME=$init_target "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" ||
        die "init failed: $(tr '\n' ' ' < "$RIG/init.err")"
}

letter_path() {
    letter_home=$1
    letter_id=$2
    for letter_candidate in \
        "$letter_home/outbox/new/$letter_id" \
        "$letter_home/outbox/acked/$letter_id" \
        "$letter_home/inbox"/*/new/"$letter_id" \
        "$letter_home/inbox"/*/cur/"$letter_id"; do
        [ -f "$letter_candidate" ] || continue
        printf '%s\n' "$letter_candidate"
        return 0
    done
    return 1
}

write_letter() {
    letter_file=$1
    letter_id=$2
    letter_from=$3
    letter_subject=$4
    letter_date=$5
    mkdir -p "$(dirname "$letter_file")" || return 1
    {
        printf 'Khala: 0.1\n'
        printf 'Id: %s\n' "$letter_id"
        printf 'From: %s\n' "$letter_from"
        printf 'To: reader@alpha\n'
        printf 'Date: %s\n' "$letter_date"
        printf 'Type: message\n'
        printf 'Subject: %s\n' "$letter_subject"
        printf 'Expires: 4102444800\n'
        printf '\nbody %s\n' "$letter_id"
    } > "$letter_file"
}

property_1() {
    p1_dir=$RIG/p1
    mkdir -p "$p1_dir" || die "could not create P1 rig"
    for p1_command in version init send say join leave streams stream mind profile minds \
        retire reconcile sync link watch inbox presence; do
        if ! "$KHALA" "$p1_command" --help >"$p1_dir/$p1_command.out" \
            2>"$p1_dir/$p1_command.err"; then
            die "$p1_command --help exited nonzero"
        fi
        p1_first=$(sed -n '1p' "$p1_dir/$p1_command.out")
        case "$p1_first" in
            "usage: khala $p1_command"*) ;;
            *) die "$p1_command --help first line does not name the subcommand" ;;
        esac
    done
    if "$KHALA" nosuch --help >"$p1_dir/nosuch.out" 2>"$p1_dir/nosuch.err"; then
        die "nosuch --help unexpectedly succeeded"
    fi
}

property_2() {
    p2_home=$RIG/p2-home
    init_home "$p2_home"
    p2_short=$(KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" \
        send reader@alpha -s S -m M) || die "short send failed"
    p2_long=$(KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" \
        send reader@alpha --subject S --message M) || die "long send failed"
    p2_short_file=$(letter_path "$p2_home" "$p2_short") || die "short letter missing"
    p2_long_file=$(letter_path "$p2_home" "$p2_long") || die "long letter missing"
    sed '/^Id: /d; /^Date: /d; /^Expires: /d' "$p2_short_file" > "$RIG/p2-short.normalized"
    sed '/^Id: /d; /^Date: /d; /^Expires: /d' "$p2_long_file" > "$RIG/p2-long.normalized"
    cmp -s "$RIG/p2-short.normalized" "$RIG/p2-long.normalized" ||
        die "long send aliases changed letter bytes"
    p2_say=$(KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" \
        say --subject SS --body BB) || die "say long aliases failed"
    p2_say_file=$p2_home/streams/khala/alpha/$p2_say
    grep -qx 'Subject: SS' "$p2_say_file" || die "say --subject omitted Subject"
    grep -qx 'BB' "$p2_say_file" || die "say --body omitted body"
    p2_say_message=$(KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" \
        say --message MM) || die "say --message failed"
    grep -qx 'MM' "$p2_home/streams/khala/alpha/$p2_say_message" ||
        die "say --message omitted body"
    if KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" send reader@alpha --bogus \
        >"$RIG/p2-bogus.out" 2>"$RIG/p2-bogus.err"; then
        die "unknown send long option succeeded"
    fi
    grep -q -- '--subject.*--message.*--body' "$RIG/p2-bogus.err" ||
        die "unknown send long option did not name accepted spellings"
    if KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" send --bogus \
        >"$RIG/p2-first-bogus.out" 2>"$RIG/p2-first-bogus.err"; then
        die "unknown leading send long option succeeded"
    fi
    grep -q -- '--subject.*--message.*--body' "$RIG/p2-first-bogus.err" ||
        die "unknown leading send long option did not name accepted spellings"
    if KHALA_HOME=$p2_home KHALA_SESSION=sender "$KHALA" say --bogus \
        >"$RIG/p2-say-bogus.out" 2>"$RIG/p2-say-bogus.err"; then
        die "unknown say long option succeeded"
    fi
    grep -q -- '--subject.*--message.*--body' "$RIG/p2-say-bogus.err" ||
        die "unknown say long option did not name accepted spellings"
}

property_3() {
    p3_home=$RIG/p3-home
    p3_ref=100.2.3.remote@alpha
    init_home "$p3_home"
    p3_id=$(KHALA_HOME=$p3_home KHALA_SESSION=sender "$KHALA" send reader@alpha \
        --subject reply --reply-to "$p3_ref" --message body) || die "reply send failed"
    p3_file=$(letter_path "$p3_home" "$p3_id") || die "reply letter missing"
    [ "$(grep -c "^In-Reply-To: $p3_ref$" "$p3_file")" -eq 1 ] ||
        die "In-Reply-To is not present exactly once"
    p3_subject_line=$(grep -n '^Subject: reply$' "$p3_file" | cut -d: -f1)
    p3_reply_line=$(grep -n "^In-Reply-To: $p3_ref$" "$p3_file" | cut -d: -f1)
    [ "$p3_reply_line" -eq "$((p3_subject_line + 1))" ] ||
        die "In-Reply-To is not immediately after Subject"
    KHALA_HOME=$p3_home "$KHALA" reconcile >/dev/null || die "reply reconcile failed"
    KHALA_HOME=$p3_home KHALA_SESSION=reader "$KHALA" inbox --drain \
        > "$RIG/p3-drain.out" || die "reply drain failed"
    grep -qx "In-Reply-To: $p3_ref" "$RIG/p3-drain.out" ||
        die "drain omitted In-Reply-To"
    KHALA_HOME=$p3_home KHALA_SESSION=reader "$KHALA" inbox read "$p3_id" \
        > "$RIG/p3-read.out" || die "reply read failed"
    grep -qx "In-Reply-To: $p3_ref" "$RIG/p3-read.out" ||
        die "read omitted In-Reply-To"
    if KHALA_HOME=$p3_home KHALA_SESSION=sender "$KHALA" send reader@alpha \
        --reply-to invalid >"$RIG/p3-invalid.out" 2>"$RIG/p3-invalid.err"; then
        die "invalid reply Id succeeded"
    fi
}

property_4() {
    p4_home=$RIG/p4-home
    init_home "$p4_home"
    p4_n=1
    while [ "$p4_n" -le 8 ]; do
        KHALA_HOME=$p4_home KHALA_SESSION=sender "$KHALA" send reader@alpha \
            -m "letter $p4_n" >/dev/null || die "send $p4_n failed"
        p4_n=$((p4_n + 1))
    done
    KHALA_HOME=$p4_home "$KHALA" reconcile >/dev/null || die "reconcile failed"
    KHALA_HOME=$p4_home KHALA_SESSION=reader "$KHALA" inbox --drain 2>"$RIG/p4.err" |
        head -3 > "$RIG/p4-head.out"
    [ "$(count_files "$p4_home/inbox/reader/new")" -eq 0 ] ||
        die "SIGPIPE left letters in new"
    [ "$(count_files "$p4_home/inbox/reader/cur")" -eq 8 ] ||
        die "SIGPIPE did not move all eight letters to cur"
    KHALA_HOME=$p4_home KHALA_SESSION=reader "$KHALA" inbox --drain \
        > "$RIG/p4-second.out" || die "second drain failed"
    [ "$(grep -cv '^drained: letters 0, notices 0, streams 0$' "$RIG/p4-second.out")" -eq 0 ] ||
        die "second drain redelivered letters"
}

property_5() {
    p5_home=$RIG/p5-home
    init_home "$p5_home"
    p5_new_1=100.1.1.new-one@alpha
    p5_new_2=200.1.1.new-two@alpha
    p5_cur_1=300.1.1.cur-one@alpha
    p5_cur_2=400.1.1.cur-two@alpha
    write_letter "$p5_home/inbox/reader/new/$p5_new_2" "$p5_new_2" two@alpha \
        'new two' 2000-01-02T00:00:00Z || die "could not write new fixture"
    write_letter "$p5_home/inbox/reader/new/$p5_new_1" "$p5_new_1" one@alpha \
        'new one' 2000-01-01T00:00:00Z || die "could not write new fixture"
    write_letter "$p5_home/inbox/reader/cur/$p5_cur_2" "$p5_cur_2" four@alpha \
        'cur two' 2000-01-04T00:00:00Z || die "could not write cur fixture"
    write_letter "$p5_home/inbox/reader/cur/$p5_cur_1" "$p5_cur_1" three@alpha \
        'cur one' 2000-01-03T00:00:00Z || die "could not write cur fixture"
    KHALA_HOME=$p5_home KHALA_SESSION=reader "$KHALA" inbox list \
        > "$RIG/p5-list.out" || die "inbox list failed"
    {
        printf '%s\tone@alpha\tnew one\t2000-01-01T00:00:00Z\n' "$p5_new_1"
        printf '%s\ttwo@alpha\tnew two\t2000-01-02T00:00:00Z\n' "$p5_new_2"
        printf '%s\tthree@alpha\tcur one\t2000-01-03T00:00:00Z\n' "$p5_cur_1"
        printf '%s\tfour@alpha\tcur two\t2000-01-04T00:00:00Z\n' "$p5_cur_2"
    } > "$RIG/p5-expected.out"
    cmp -s "$RIG/p5-expected.out" "$RIG/p5-list.out" ||
        die "inbox list fields or new/cur order differ"
    p5_before_new=$(count_files "$p5_home/inbox/reader/new")
    p5_before_cur=$(count_files "$p5_home/inbox/reader/cur")
    KHALA_HOME=$p5_home KHALA_SESSION=reader "$KHALA" inbox read "$p5_cur_1" \
        > "$RIG/p5-read-cur.out" || die "read from cur failed"
    cmp -s "$p5_home/inbox/reader/cur/$p5_cur_1" "$RIG/p5-read-cur.out" ||
        die "read from cur changed letter bytes"
    KHALA_HOME=$p5_home KHALA_SESSION=reader "$KHALA" inbox read "$p5_new_1" \
        > "$RIG/p5-read-new.out" || die "read from new failed"
    cmp -s "$p5_home/inbox/reader/new/$p5_new_1" "$RIG/p5-read-new.out" ||
        die "read from new changed letter bytes"
    [ "$(count_files "$p5_home/inbox/reader/new")" -eq "$p5_before_new" ] &&
        [ "$(count_files "$p5_home/inbox/reader/cur")" -eq "$p5_before_cur" ] ||
        die "inbox read moved a letter"
}

property_6() {
    p6_home=$RIG/p6-home
    init_home "$p6_home"
    KHALA_HOME=$p6_home KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null ||
        die "reader heartbeat failed"
    KHALA_HOME=$p6_home KHALA_SESSION=reader "$KHALA" join khala --from-start >/dev/null ||
        die "join failed"
    p6_letter=$(KHALA_HOME=$p6_home KHALA_SESSION=sender "$KHALA" \
        send reader@alpha -m letter) || die "letter send failed"
    KHALA_HOME=$p6_home "$KHALA" reconcile >/dev/null || die "letter reconcile failed"
    p6_stream=$(KHALA_HOME=$p6_home KHALA_SESSION=speaker "$KHALA" \
        say -m stream) || die "stream say failed"
    KHALA_HOME=$p6_home KHALA_SESSION=reader "$KHALA" inbox --drain \
        > "$RIG/p6-drain.out" || die "mixed drain failed"
    grep -Fqx -- "--- letter $p6_letter ---" "$RIG/p6-drain.out" ||
        die "letter delimiter differs"
    grep -Fqx -- "--- stream khala $p6_stream ---" "$RIG/p6-drain.out" ||
        die "stream delimiter differs"
}

property_7() {
    p7_home=$RIG/p7-home
    init_home "$p7_home"
    p7_letter=$(KHALA_HOME=$p7_home KHALA_SESSION=sender "$KHALA" \
        send mail-reader@alpha -m wake) || die "watch letter send failed"
    KHALA_HOME=$p7_home "$KHALA" reconcile >/dev/null || die "watch letter reconcile failed"
    KHALA_HOME=$p7_home "$KHALA" watch --session mail-reader --interval 1 --max-wait 2 \
        > "$RIG/p7-mail.out" || die "delivery watch failed"
    [ "$(sed -n '1p' "$RIG/p7-mail.out")" = 'wake: delivery' ] ||
        die "delivery wake reason is not first"
    grep -Fq "$p7_letter" "$RIG/p7-mail.out" || die "delivery rows changed"
    KHALA_HOME=$p7_home KHALA_SESSION=stream-reader "$KHALA" inbox --drain >/dev/null ||
        die "stream reader heartbeat failed"
    KHALA_HOME=$p7_home KHALA_SESSION=stream-reader "$KHALA" join khala --from-start >/dev/null ||
        die "stream reader join failed"
    p7_stream=$(KHALA_HOME=$p7_home KHALA_SESSION=speaker "$KHALA" \
        say -m wake) || die "watch stream say failed"
    KHALA_HOME=$p7_home "$KHALA" watch --session stream-reader --interval 1 --max-wait 2 \
        > "$RIG/p7-stream.out" || die "stream watch failed"
    [ "$(sed -n '1p' "$RIG/p7-stream.out")" = 'wake: stream' ] ||
        die "stream wake reason is not first"
    grep -Fq "$p7_stream" "$RIG/p7-stream.out" || die "stream rows changed"
}

run_property() {
    property_number=$1
    property_title=$2
    if ( "property_$property_number" ); then
        printf 'ok P%s — %s\n' "$property_number" "$property_title"
    else
        printf 'not ok P%s — %s\n' "$property_number" "$property_title" >&2
        FAILURES="$FAILURES P$property_number"
    fi
}

mkdir -p "$RIG" || exit 1
trap cleanup EXIT HUP INT TERM

run_property 1 'every known subcommand has successful focused help'
run_property 2 'send and say long aliases preserve content and errors name spellings'
run_property 3 'reply metadata is validated, positioned, and displayed'
run_property 4 'SIGPIPE cannot redeliver already selected letters'
run_property 5 'inbox list and read expose letters without moving them'
run_property 6 'letter and stream drain delimiters are distinct'
run_property 7 'watch reason is the first line for delivery and stream wakes'

if [ -n "$FAILURES" ]; then
    printf 'RESULT: FAIL properties%s\n' "$FAILURES"
    exit 1
fi
printf 'RESULT: PASS\n'
