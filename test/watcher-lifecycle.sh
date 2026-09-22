#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
RIG=$HOME/.khala-watcher-lifecycle-test-$$
FAILURES=0

cleanup() {
    rm -rf -- "$RIG"
}

die() {
    printf '    %s\n' "$*" >&2
    exit 1
}

count_files() {
    count_files_n=0
    if [ -d "$1" ]; then
        for count_files_path in "$1"/*; do
            [ -f "$count_files_path" ] || continue
            count_files_n=$((count_files_n + 1))
        done
    fi
    printf '%s\n' "$count_files_n"
}

init_home() {
    init_home_path=$1
    KHALA_HOME=$init_home_path "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" ||
        die "init failed: $(tr '\n' ' ' < "$RIG/init.err")"
}

write_marker() {
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" "$6" "$7" > "$1"
}

write_notice() {
    notice_path=$1
    notice_id=$2
    notice_from=$3
    notice_urgency=$4
    notice_subject=$5
    notice_expires=$6
    mkdir -p "$(dirname "$notice_path")"
    {
        printf 'Khala: 0.1\n'
        printf 'Id: %s\n' "$notice_id"
        printf 'From: %s\n' "$notice_from"
        printf 'To: reader@alpha\n'
        printf 'Date: 2000-01-01T00:00:00Z\n'
        printf 'Type: notice\n'
        printf 'Urgency: %s\n' "$notice_urgency"
        printf 'Subject: %s\n' "$notice_subject"
        printf 'Expires: %s\n' "$notice_expires"
        printf '\n%s\n' "$notice_subject"
    } > "$notice_path"
}

run_property() {
    property_name=$1
    shift
    if ( "$@" ); then
        printf 'ok %s\n' "$property_name"
    else
        printf 'not ok %s\n' "$property_name"
        FAILURES=$((FAILURES + 1))
    fi
}

property_declared_notify() {
    home=$RIG/declared-notify
    init_home "$home"
    if printf '' | KHALA_HOME=$home "$KHALA" notify reader@alpha --as undeclared \
        >"$RIG/undeclared.out" 2>"$RIG/undeclared.err"; then
        die "P1 notify --as undeclared succeeded"
    fi
    grep -Fq 'watcher declare undeclared --cadence <초> --owner <session@node>' \
        "$RIG/undeclared.err" || die "P1 undeclared error does not name the declare command"
    [ ! -e "$home/presence/undeclared@alpha.watcher" ] ||
        die "P1 undeclared notify created a marker"
    [ "$(count_files "$home/spool/for/alpha")" -eq 0 ] ||
        die "P1 undeclared notify created a spool file"
    [ "$(count_files "$home/inbox/reader/new")" -eq 0 ] ||
        die "P1 undeclared notify created an inbox file"

    KHALA_HOME=$home "$KHALA" watcher declare declared --cadence 0 --owner reader >/dev/null ||
        die "P1 watcher declaration failed"
    declared_id=$(printf 'declared\n' | KHALA_HOME=$home "$KHALA" \
        notify reader@alpha --as declared -s declared) || die "P1 declared notify failed"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P1 declared reconcile failed"
    [ -f "$home/inbox/reader/new/$declared_id" ] || die "P1 declared notice was not delivered"

    KHALA_HOME=$home "$KHALA" watcher declare retired-name --cadence 0 --owner reader >/dev/null ||
        die "P1 retired watcher declaration failed"
    KHALA_HOME=$home "$KHALA" watcher retire retired-name >/dev/null ||
        die "P1 watcher retirement failed"
    before_spool=$(count_files "$home/spool/for/alpha")
    before_inbox=$(count_files "$home/inbox/reader/new")
    if printf '' | KHALA_HOME=$home "$KHALA" notify reader@alpha --as retired-name \
        >"$RIG/retired.out" 2>"$RIG/retired.err"; then
        die "P1 notify --as retired-name succeeded"
    fi
    grep -Fq 'watcher declare retired-name --cadence <초> --owner <session@node>' \
        "$RIG/retired.err" || die "P1 retired error does not name the declare command"
    grep -Eq '^retired [0-9]+$' "$home/presence/retired-name@alpha.watcher" ||
        die "P1 retired notify rewrote the marker"
    [ "$(count_files "$home/spool/for/alpha")" -eq "$before_spool" ] ||
        die "P1 retired notify created a spool file"
    [ "$(count_files "$home/inbox/reader/new")" -eq "$before_inbox" ] ||
        die "P1 retired notify created an inbox file"
}

property_presence_split() {
    home=$RIG/presence-split
    init_home "$home"
    now=$(date +%s)
    printf '%s\n' "$now" > "$home/presence/human@alpha"
    KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 0 --owner human >/dev/null ||
        die "P2 watcher declaration failed"
    KHALA_HOME=$home "$KHALA" presence >"$RIG/presence.out" || die "P2 presence failed"
    grep -q '^human@alpha' "$RIG/presence.out" || die "P2 session row is missing"
    ! grep -qx 'watchers:' "$RIG/presence.out" || die "P2 default presence printed watchers:"
    ! grep -q $'^guard\talpha\t' "$RIG/presence.out" ||
        die "P2 default presence printed a watcher row"
    grep -Fq 'khala watcher list' "$RIG/presence.out" ||
        die "P2 presence legend does not mention khala watcher list"
    KHALA_HOME=$home "$KHALA" presence --watchers >"$RIG/presence-watchers.out" ||
        die "P2 presence --watchers failed"
    grep -qx 'watchers:' "$RIG/presence-watchers.out" ||
        die "P2 presence --watchers omitted its heading"
    grep -q $'^guard\talpha\t' "$RIG/presence-watchers.out" ||
        die "P2 presence --watchers omitted the active watcher"
    KHALA_HOME=$home "$KHALA" watcher list >"$RIG/watcher-list.out" ||
        die "P2 watcher list failed"
    grep -q $'^guard\talpha\t' "$RIG/watcher-list.out" ||
        die "P2 watcher list omitted the watcher"
}

property_automatic_retire() {
    home=$RIG/automatic-retire
    init_home "$home"
    now=$(date +%s)
    old=$((now - 8 * 86400))
    very_old=$((now - 40 * 86400))
    recent=$((now - 6 * 86400))
    printf 'retired %s\n' "$now" > "$home/presence/dead-owner@alpha"
    printf '%s\n' "$now" > "$home/presence/live-owner@alpha"
    printf '%s\n' "$now" > "$home/presence/silent-owner@alpha"
    printf '%s\n' "$now" > "$home/presence/recent-owner@alpha"
    write_marker "$home/presence/owner-dead@alpha.watcher" "$now" 0 \
        dead-owner@alpha "$now" active "$now"
    write_marker "$home/presence/silent-old@alpha.watcher" "$now" 60 \
        silent-owner@alpha "$old" "silent $old" "$old"
    write_marker "$home/presence/orphan-old@alpha.watcher" "$old" 0 - 0 active "$old"
    write_marker "$home/presence/event-live@alpha.watcher" "$very_old" 0 \
        live-owner@alpha "$very_old" active "$very_old"
    write_marker "$home/presence/silent-recent@alpha.watcher" "$now" 60 \
        recent-owner@alpha "$recent" "silent $recent" "$recent"
    write_marker "$home/presence/remote-old@beta.watcher" "$now" 60 \
        remote-owner@beta "$old" "silent $old" "$old"
    owner_dead_tail=$(sed -n '2,6p' "$home/presence/owner-dead@alpha.watcher")
    silent_old_tail=$(sed -n '2,6p' "$home/presence/silent-old@alpha.watcher")
    orphan_old_tail=$(sed -n '2,6p' "$home/presence/orphan-old@alpha.watcher")

    rm -f "$home/run/retention.stamp"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P3 retire reconcile failed"
    grep -Eq '^retired [0-9]+$' "$home/presence/owner-dead@alpha.watcher" ||
        die "P3 watcher owned by a retired session was not retired"
    grep -Eq '^retired [0-9]+$' "$home/presence/silent-old@alpha.watcher" ||
        die "P3 watcher silent over seven days was not retired"
    grep -Eq '^retired [0-9]+$' "$home/presence/orphan-old@alpha.watcher" ||
        die "P3 old ownerless watcher was not retired"
    [ "$(sed -n '2,6p' "$home/presence/owner-dead@alpha.watcher")" = "$owner_dead_tail" ] ||
        die "P3 owner-dead retirement changed lines 2-6"
    [ "$(sed -n '2,6p' "$home/presence/silent-old@alpha.watcher")" = "$silent_old_tail" ] ||
        die "P3 silent retirement changed lines 2-6"
    [ "$(sed -n '2,6p' "$home/presence/orphan-old@alpha.watcher")" = "$orphan_old_tail" ] ||
        die "P3 ownerless retirement changed lines 2-6"
    [ -f "$home/presence/event-live@alpha.watcher" ] ||
        die "P3 live owned cadence-0 watcher disappeared"
    ! grep -q '^retired ' "$home/presence/event-live@alpha.watcher" ||
        die "P3 live owned cadence-0 watcher was retired"
    [ -f "$home/presence/silent-recent@alpha.watcher" ] ||
        die "P3 recently silent watcher disappeared"
    ! grep -q '^retired ' "$home/presence/silent-recent@alpha.watcher" ||
        die "P3 recently silent watcher was retired"
    [ -f "$home/presence/remote-old@beta.watcher" ] ||
        die "P3 remote-node watcher disappeared"
    ! grep -q '^retired ' "$home/presence/remote-old@beta.watcher" ||
        die "P3 remote-node watcher was retired"

    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P3 notice delivery reconcile failed"
    [ "$(count_files "$home/inbox/silent-owner/new")" -eq 1 ] ||
        die "P3 silent watcher owner did not receive exactly one notice"
    retire_notice=$(find "$home/inbox/silent-owner/new" -type f -print -quit)
    grep -qx 'Urgency: info' "$retire_notice" || die "P3 retirement notice is not info"
    grep -Eq '^Subject: \[watcher\] silent-old retired after [0-9]+[smhd] silent$' \
        "$retire_notice" || die "P3 retirement notice subject differs"
    [ "$(count_files "$home/inbox/dead-owner/new")" -eq 0 ] ||
        die "P3 owner-dead retirement sent a notice"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P3 steady reconcile failed"
    [ "$(count_files "$home/inbox/silent-owner/new")" -eq 1 ] ||
        die "P3 silent retirement sent more than one notice"
}

property_fold_info_notices() {
    home=$RIG/fold-info
    init_home "$home"
    now=$(date +%s)
    future=$((now + 10000))
    mkdir -p "$home/inbox/reader/new" "$home/inbox/reader/cur"
    cur_id="$((now - 1)).1.1.watcher-w@alpha"
    write_notice "$home/inbox/reader/cur/$cur_id" "$cur_id" watcher-w@alpha info \
        cur-preserved "$future"
    for sequence in 2 3 4; do
        notice_id="$((now + sequence)).1.$sequence.watcher-w@alpha"
        write_notice "$home/spool/for/alpha/$notice_id" "$notice_id" watcher-w@alpha info \
            "info-$sequence" "$future"
        KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P4 info reconcile $sequence failed"
    done
    [ "$(grep -l '^From: watcher-w@alpha$' "$home"/inbox/reader/new/* | \
        xargs grep -l '^Urgency: info$' | wc -l | tr -d ' ')" -eq 1 ] ||
        die "P4 three watcher W info notices did not fold to one"
    grep -q '^Subject: info-4$' "$home"/inbox/reader/new/* ||
        die "P4 newest watcher W info notice was not kept"

    urgent_id="$((now + 5)).1.5.watcher-w@alpha"
    write_notice "$home/spool/for/alpha/$urgent_id" "$urgent_id" watcher-w@alpha urgent \
        urgent-kept "$future"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P4 urgent reconcile failed"
    other_id="$((now + 6)).1.6.watcher-v@alpha"
    write_notice "$home/spool/for/alpha/$other_id" "$other_id" watcher-v@alpha info \
        other-kept "$future"
    KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "P4 other watcher reconcile failed"
    [ "$(count_files "$home/inbox/reader/new")" -eq 3 ] ||
        die "P4 urgent or other watcher notice was folded"
    [ -f "$home/inbox/reader/cur/$cur_id" ] || die "P4 cur notice was folded"

    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/fold-drain.out" ||
        die "P4 drain failed"
    grep -q 'info-4' "$RIG/fold-drain.out" || die "P4 drain omitted the newest folded notice"
    ! grep -Eq 'info-2|info-3' "$RIG/fold-drain.out" ||
        die "P4 drain showed an older folded notice"
    grep -q 'urgent-kept' "$RIG/fold-drain.out" || die "P4 drain omitted the urgent notice"
    grep -q 'other-kept' "$RIG/fold-drain.out" || die "P4 drain omitted watcher V info"
}

mkdir -p "$RIG"
trap cleanup EXIT HUP INT TERM

run_property P1 property_declared_notify
run_property P2 property_presence_split
run_property P3 property_automatic_retire
run_property P4 property_fold_info_notices

if [ "$FAILURES" -ne 0 ]; then
    printf 'RESULT: FAIL (%s properties)\n' "$FAILURES"
    exit 1
fi
printf 'RESULT: PASS\n'
