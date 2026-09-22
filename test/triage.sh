#!/usr/bin/env bash
# Jev triage display (CLI half, review/jev-triage-r1.md §2.3-2.4): the conduit
# writes run/triage/<identity>/<id>.tag; drain, inbox list and status only show it.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
RIG=$HOME/.khala-triage-test-$$
DOT=$(printf '\302\267')

cleanup() {
    rm -rf -- "$RIG"
}

die() {
    printf '    %s\n' "$*" >&2
    exit 1
}

init_home() {
    init_home_path=$1
    KHALA_HOME=$init_home_path "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" ||
        die "init failed: $(tr '\n' ' ' < "$RIG/init.err")"
    printf 'retention-interval 0\n' >> "$init_home_path/config" || die "config append failed"
    # status needs a link binary; the stub prints the runtime line and table head.
    mkdir -p "$init_home_path/bin" || die "bin mkdir failed"
    printf '%s\n' '#!/bin/sh' \
        'case "$*" in' \
        '  "runtime status") printf "runtime: /fixture/runtime\nIDENTITY\tPENDING\n" ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$init_home_path/bin/khala-link" || die "stub write failed"
    chmod 755 "$init_home_path/bin/khala-link" || die "stub chmod failed"
}

write_letter() {
    write_home=$1
    write_id=$2
    write_from=$3
    write_type=$4
    write_subject=$5
    write_dir=$write_home/inbox/reader/new
    mkdir -p "$write_dir" "$write_home/inbox/reader/cur"
    {
        printf 'Khala: 0.1\n'
        printf 'Id: %s\n' "$write_id"
        printf 'From: %s\n' "$write_from"
        printf 'To: reader@alpha\n'
        printf 'Date: 2000-01-01T00:00:00Z\n'
        printf 'Type: %s\n' "$write_type"
        [ "$write_type" != notice ] || printf 'Urgency: urgent\n'
        printf 'Subject: %s\n' "$write_subject"
        printf 'Expires: %s\n' "$future"
        printf '\nbody of %s\n' "$write_subject"
    } > "$write_dir/$write_id"
}

# 2 letters + 1 notice
fixture() {
    init_home "$1"
    write_letter "$1" "$A" a@alpha message 'letter a'
    write_letter "$1" "$B" b@alpha message 'letter b'
    write_letter "$1" "$N" guard@alpha notice 'notice n'
}

run_khala() {
    run_home=$1
    shift
    KHALA_HOME=$run_home KHALA_SESSION=reader "$KHALA" "$@"
}

mkdir -p "$RIG"
trap cleanup EXIT HUP INT TERM
now=$(date +%s)
future=$((now + 99999))
A=$now.1.1.a@alpha
B=$now.1.2.b@alpha
N=$now.1.3.guard@alpha

# P1: no run/triage and no triage.conf -> drain and list unchanged, status says off.
property_P1() {
    home=$RIG/p1
    fixture "$home"
    run_khala "$home" inbox > "$RIG/p1-summary.out" 2>"$RIG/p1.err" || die "P1 summary failed"
    printf '%s\ta@alpha\tmessage\n%s\tb@alpha\tmessage\n%s\tguard@alpha\tnotice\n' "$A" "$B" "$N" \
        > "$RIG/p1-summary.exp"
    cmp -s "$RIG/p1-summary.exp" "$RIG/p1-summary.out" || die "P1 inbox summary changed without triage"
    run_khala "$home" inbox list > "$RIG/p1-list.out" 2>>"$RIG/p1.err" || die "P1 list failed"
    printf '%s\ta@alpha\tletter a\t2000-01-01T00:00:00Z\n%s\tb@alpha\tletter b\t2000-01-01T00:00:00Z\n%s\tguard@alpha\tnotice n\t2000-01-01T00:00:00Z\n' "$A" "$B" "$N" \
        > "$RIG/p1-list.exp"
    cmp -s "$RIG/p1-list.exp" "$RIG/p1-list.out" || die "P1 inbox list changed without triage"
    cp -R "$home" "$RIG/p1-copy" || die "P1 copy failed"
    run_khala "$home" inbox --drain > "$RIG/p1-drain.out" 2>>"$RIG/p1.err" || die "P1 drain failed"
    grep -qx -- "--- letter $A ---" "$RIG/p1-drain.out" || die "P1 letter A line changed"
    grep -qx -- "--- letter $B ---" "$RIG/p1-drain.out" || die "P1 letter B line changed"
    grep -qx -- "--- notice $N --- guard@alpha $DOT urgent $DOT notice n" "$RIG/p1-drain.out" ||
        die "P1 notice line changed"
    run_khala "$home" status > "$RIG/p1-status.out" 2>>"$RIG/p1.err" || die "P1 status failed"
    printf 'runtime: /fixture/runtime\ntriage: off\nIDENTITY\tPENDING\n' > "$RIG/p1-status.exp"
    cmp -s "$RIG/p1-status.exp" "$RIG/p1-status.out" ||
        die "P1 status differs: $(tr '\n' '|' < "$RIG/p1-status.out")"
    [ ! -s "$RIG/p1.err" ] || die "P1 stderr not empty: $(cat "$RIG/p1.err")"
    [ ! -e "$home/run/triage" ] || die "P1 CLI created run/triage"
    printf 'ok P1 — without triage, drain and list are unchanged and status says off\n'
}

# P2: valid tags are shown on the drain line and as the list's last column.
property_P2() {
    home=$RIG/p2
    fixture "$home"
    mkdir -p "$home/run/triage/reader"
    printf 'action,urgent\n' > "$home/run/triage/reader/$A.tag"
    printf 'fyi\n' > "$home/run/triage/reader/$B.tag"
    printf '{"id":"x"}\n' > "$home/run/triage/reader/$A.json"
    run_khala "$home" inbox > "$RIG/p2-summary.out" 2>"$RIG/p2.err" || die "P2 summary failed"
    printf '%s\ta@alpha\tmessage\taction,urgent\n%s\tb@alpha\tmessage\tfyi\n%s\tguard@alpha\tnotice\t-\n' "$A" "$B" "$N" \
        > "$RIG/p2-summary.exp"
    cmp -s "$RIG/p2-summary.exp" "$RIG/p2-summary.out" ||
        die "P2 inbox summary lacks the Triage column: $(tr '\n\t' '|,' < "$RIG/p2-summary.out")"
    run_khala "$home" inbox list > "$RIG/p2-list.out" 2>>"$RIG/p2.err" || die "P2 list failed"
    printf '%s\ta@alpha\tletter a\t2000-01-01T00:00:00Z\taction,urgent\n%s\tb@alpha\tletter b\t2000-01-01T00:00:00Z\tfyi\n%s\tguard@alpha\tnotice n\t2000-01-01T00:00:00Z\t-\n' "$A" "$B" "$N" \
        > "$RIG/p2-list.exp"
    cmp -s "$RIG/p2-list.exp" "$RIG/p2-list.out" || die "P2 inbox list lacks the Triage column"
    run_khala "$home" inbox --drain > "$RIG/p2-drain.out" 2>>"$RIG/p2.err" || die "P2 drain failed"
    grep -qx -- "--- letter $A --- $DOT action,urgent" "$RIG/p2-drain.out" || die "P2 letter A tag missing"
    grep -qx -- "--- letter $B --- $DOT fyi" "$RIG/p2-drain.out" || die "P2 letter B tag missing"
    grep -qx -- "--- notice $N --- guard@alpha $DOT urgent $DOT notice n" "$RIG/p2-drain.out" ||
        die "P2 notice line changed"
    # Apart from the suffixes, the drain output equals the untagged one.
    run_khala "$RIG/p1-copy" inbox --drain > "$RIG/p2-base.out" 2>>"$RIG/p2.err" || die "P2 base drain failed"
    sed "s/ $DOT action,urgent\$//; s/ $DOT fyi\$//" "$RIG/p2-drain.out" > "$RIG/p2-stripped.out"
    cmp -s "$RIG/p2-base.out" "$RIG/p2-stripped.out" || die "P2 drain differs beyond the tag suffix"
    # After the drain the letters are in cur/ and list still shows the tags.
    run_khala "$home" inbox list > "$RIG/p2-list2.out" 2>>"$RIG/p2.err" || die "P2 list after drain failed"
    cmp -s "$RIG/p2-list.exp" "$RIG/p2-list2.out" || die "P2 list after drain lost the tags"
    [ ! -s "$RIG/p2.err" ] || die "P2 stderr not empty: $(cat "$RIG/p2.err")"
    printf 'ok P2 — tags on the drain line and the list column; notice untouched\n'
}

# P3: malformed tags are silently no triage.
property_P3() {
    home=$RIG/p3
    init_home "$home"
    tdir=$home/run/triage/reader
    mkdir -p "$tdir"
    L1=$now.3.1.a@alpha L2=$now.3.2.a@alpha L3=$now.3.3.a@alpha L4=$now.3.4.a@alpha
    L5=$now.3.5.a@alpha L6=$now.3.6.a@alpha L7=$now.3.7.a@alpha L8=$now.3.8.a@alpha
    for l in "$L1" "$L2" "$L3" "$L4" "$L5" "$L6" "$L7" "$L8"; do
        write_letter "$home" "$l" a@alpha message "m $l"
    done
    : > "$tdir/$L1.tag"
    printf 'action,bogus\n' > "$tdir/$L2.tag"
    head -c 199 /dev/zero | tr '\0' 'a' > "$tdir/$L3.tag"; printf '\n' >> "$tdir/$L3.tag"
    printf 'fyi\n' > "$RIG/valid.tag"
    ln -s "$RIG/valid.tag" "$tdir/$L4.tag"
    mkdir "$tdir/$L5.tag"
    printf 'reply,action\n' > "$tdir/$L6.tag"
    printf 'fyi' > "$tdir/$L7.tag"
    printf 'fyi\nfyi\n' > "$tdir/$L8.tag"
    run_khala "$home" inbox > "$RIG/p3-summary.out" 2>"$RIG/p3.err" || die "P3 summary exit"
    [ "$(grep -c "$(printf '\t-$')" "$RIG/p3-summary.out")" -eq 8 ] ||
        die "P3 summary shows a malformed tag: $(tr '\n\t' '|,' < "$RIG/p3-summary.out")"
    run_khala "$home" inbox list > "$RIG/p3-list.out" 2>>"$RIG/p3.err" || die "P3 list exit"
    [ "$(grep -c "$(printf '\t-$')" "$RIG/p3-list.out")" -eq 8 ] || die "P3 list shows a malformed tag"
    run_khala "$home" inbox --drain > "$RIG/p3-drain.out" 2>>"$RIG/p3.err" || die "P3 drain exit"
    for l in "$L1" "$L2" "$L3" "$L4" "$L5" "$L6" "$L7" "$L8"; do
        grep -qx -- "--- letter $l ---" "$RIG/p3-drain.out" || die "P3 malformed tag shown for $l"
    done
    [ ! -s "$RIG/p3.err" ] || die "P3 stderr not empty: $(cat "$RIG/p3.err")"
    # A symlinked identity directory is refused as a whole.
    home=$RIG/p3b
    init_home "$home"
    mkdir -p "$home/run/triage" "$RIG/elsewhere"
    ln -s "$RIG/elsewhere" "$home/run/triage/reader"
    printf 'fyi\n' > "$RIG/elsewhere/$A.tag"
    write_letter "$home" "$A" a@alpha message 'letter a'
    run_khala "$home" inbox --drain > "$RIG/p3b-drain.out" 2>"$RIG/p3b.err" || die "P3b drain exit"
    grep -qx -- "--- letter $A ---" "$RIG/p3b-drain.out" || die "P3b followed a symlinked triage dir"
    [ ! -s "$RIG/p3b.err" ] || die "P3b stderr not empty"
    printf 'ok P3 — empty, bogus, long, symlink, directory, unordered, unterminated, multi-line tags ignored\n'
}

# P4: a stray tag for a notice or operator letter is never shown, while a
# message letter in the same drain keeps its tag.
property_P4() {
    home=$RIG/p4
    init_home "$home"
    O=$now.4.2.op@alpha
    write_letter "$home" "$A" a@alpha message 'letter a'
    write_letter "$home" "$O" op@alpha operator 'op letter'
    write_letter "$home" "$N" guard@alpha notice 'notice n'
    mkdir -p "$home/run/triage/reader"
    printf 'reply\n' > "$home/run/triage/reader/$A.tag"
    printf 'action\n' > "$home/run/triage/reader/$O.tag"
    printf 'action\n' > "$home/run/triage/reader/$N.tag"
    run_khala "$home" inbox > "$RIG/p4-summary.out" 2>"$RIG/p4.err" || die "P4 summary exit"
    grep -qx "$(printf '%s\top@alpha\toperator\t-' "$O")" "$RIG/p4-summary.out" ||
        die "P4 summary shows a stray operator tag"
    grep -qx "$(printf '%s\tguard@alpha\tnotice\t-' "$N")" "$RIG/p4-summary.out" ||
        die "P4 summary shows a stray notice tag"
    run_khala "$home" inbox --drain > "$RIG/p4-drain.out" 2>>"$RIG/p4.err" || die "P4 drain exit"
    grep -qx -- "--- letter $A --- $DOT reply" "$RIG/p4-drain.out" || die "P4 message tag missing"
    grep -qx -- "--- letter $O ---" "$RIG/p4-drain.out" || die "P4 operator line changed by a stray tag"
    grep -qx -- "--- notice $N --- guard@alpha $DOT urgent $DOT notice n" "$RIG/p4-drain.out" ||
        die "P4 notice line changed by a stray tag"
    grep -q "$DOT action" "$RIG/p4-drain.out" && die "P4 stray tag shown"
    [ ! -s "$RIG/p4.err" ] || die "P4 stderr not empty: $(cat "$RIG/p4.err")"
    printf 'ok P4 — stray tags on notice/operator are not shown; the message tag is\n'
}

# P5: status line from triage.conf; the key never appears.
property_P5() {
    home=$RIG/p5
    init_home "$home"
    conf=$home/triage.conf
    status_line() {
        run_khala "$home" status > "$RIG/p5.out" 2>"$RIG/p5.err" || die "P5 status exit"
        [ ! -s "$RIG/p5.err" ] || die "P5 stderr not empty: $(cat "$RIG/p5.err")"
        sed -n '2p' "$RIG/p5.out"
    }
    [ "$(status_line)" = 'triage: off' ] || die "P5 absent conf"
    printf 'provider typesafe\nkey SECRET-KEY-123\nmodel jev-1.13.0\nthreshold 0.6\n' > "$conf"
    chmod 600 "$conf"
    [ "$(status_line)" = 'triage: on (jev-1.13.0, threshold 0.6)' ] || die "P5 model/threshold: $(status_line)"
    grep -q SECRET "$RIG/p5.out" && die "P5 key printed"
    printf 'key x\n' > "$conf"
    [ "$(status_line)" = 'triage: on (jev-latest, threshold 0.7)' ] || die "P5 defaults: $(status_line)"
    printf 'key SECRET-KEY-123\nmodel jev-latest   # pinned later\n' > "$conf"
    [ "$(status_line)" = 'triage: on (jev-latest, threshold 0.7)' ] || die "P5 trailing comment: $(status_line)"
    chmod 644 "$conf"
    [ "$(status_line)" = 'triage: off (triage.conf must be a regular 0600 file)' ] ||
        die "P5 0644: $(status_line)"
    grep -q SECRET "$RIG/p5.out" && die "P5 key printed (0644)"
    rm -f "$conf"
    printf 'model jev-1\n' > "$RIG/real.conf"; chmod 600 "$RIG/real.conf"
    ln -s "$RIG/real.conf" "$conf"
    [ "$(status_line)" = 'triage: off (triage.conf must be a regular 0600 file)' ] ||
        die "P5 symlink: $(status_line)"
    rm -f "$conf"; mkdir "$conf"
    [ "$(status_line)" = 'triage: off (triage.conf must be a regular 0600 file)' ] ||
        die "P5 directory: $(status_line)"
    rmdir "$conf"
    printf 'model jev$(x)\n' > "$conf"; chmod 600 "$conf"
    case "$(status_line)" in
        'triage: invalid (triage.conf model)') ;;
        *) die "P5 unsafe model value: $(status_line)" ;;
    esac
    printf 'ok P5 — status triage line: off, on with values/defaults, 0600 rule, no key\n'
}

# P6: the plugin copy is identical.
property_P6() {
    cmp -s "$ROOT/bin/khala" "$ROOT/plugin/bin/khala" || die "plugin/bin/khala differs from bin/khala"
    sh -n "$ROOT/bin/khala" || die "sh -n failed"
    printf 'ok P6 — plugin copy identical, syntax clean\n'
}

failed=0
for p in P1 P2 P3 P4 P5 P6; do
    ( "property_$p" ) || { printf 'FAIL %s\n' "$p"; failed=1; }
done
[ "$failed" -eq 0 ] || { printf 'RESULT: FAIL\n'; exit 1; }
printf 'RESULT: PASS\n'
