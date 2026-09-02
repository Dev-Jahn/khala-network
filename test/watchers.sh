#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
RIG=$HOME/.khala-watchers-test-$$

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
    marker_path=$1
    marker_l1=$2
    marker_l2=$3
    marker_l3=$4
    marker_l4=$5
    marker_l5=$6
    printf '%s\n%s\n%s\n%s\n%s\n' "$marker_l1" "$marker_l2" "$marker_l3" \
        "$marker_l4" "$marker_l5" > "$marker_path"
}

mkdir -p "$RIG"
trap cleanup EXIT HUP INT TERM

# P5: declaration, re-declaration, fleet listing, and retirement.
home=$RIG/crud
init_home "$home"
if KHALA_HOME=$home "$KHALA" watcher declare 'bad_name' --cadence 10 --owner owner \
    >"$RIG/bad-name.out" 2>"$RIG/bad-name.err"; then
    die "invalid watcher name succeeded"
fi
if KHALA_HOME=$home "$KHALA" watcher declare guard --cadence -1 --owner owner \
    >"$RIG/bad-cadence.out" 2>"$RIG/bad-cadence.err"; then
    die "negative cadence succeeded"
fi
if KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 10 --owner 'bad_owner' \
    >"$RIG/bad-owner.out" 2>"$RIG/bad-owner.err"; then
    die "invalid owner succeeded"
fi
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 10 --owner owner \
    >"$RIG/declare.out" 2>"$RIG/declare.err" || die "watcher declare failed"
marker=$home/presence/guard@alpha.watcher
[ -f "$marker" ] || die "watcher marker missing"
[ "$(wc -l < "$marker" | tr -d ' ')" -eq 5 ] || die "watcher marker is not five lines"
declared=$(sed -n '1p' "$marker")
[ "$declared" -gt 0 ] || die "declared epoch invalid"
[ "$(sed -n '2p' "$marker")" = 10 ] || die "cadence differs"
[ "$(sed -n '3p' "$marker")" = owner ] || die "owner differs"
[ "$(sed -n '4p' "$marker")" = 0 ] || die "new declaration did not start at never"
[ "$(sed -n '5p' "$marker")" = active ] || die "new declaration state differs"
write_marker "$marker" "$declared" 10 owner 123 'silent 124'
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 30 --owner new-owner >/dev/null ||
    die "watcher re-declare failed"
[ "$(sed -n '2p' "$marker")" = 30 ] && [ "$(sed -n '3p' "$marker")" = new-owner ] ||
    die "re-declare did not update cadence/owner"
[ "$(sed -n '4p' "$marker")" = 123 ] && [ "$(sed -n '5p' "$marker")" = 'silent 124' ] ||
    die "re-declare did not preserve L4/L5"
write_marker "$home/presence/remote@beta.watcher" "$declared" 60 remote-owner 0 active
KHALA_HOME=$home "$KHALA" watcher list >"$RIG/list.out" || die "watcher list failed"
head -n 1 "$RIG/list.out" | grep -qx $'NAME\tNODE\tOWNER\tCADENCE\tLAST\tSTATE' ||
    die "watcher list header differs"
grep -q $'^guard\talpha\tnew-owner\t30\t.*\tsilent$' "$RIG/list.out" ||
    die "local watcher list row differs"
grep -q $'^remote\tbeta\tremote-owner\t60\t-\tactive$' "$RIG/list.out" ||
    die "remote watcher list row differs"
KHALA_HOME=$home "$KHALA" watcher retire guard >"$RIG/retire.out" || die "watcher retire failed"
grep -Eq '^retired [0-9]+$' "$marker" || die "retire did not rewrite L1"
KHALA_HOME=$home "$KHALA" watcher list >"$RIG/retired-list.out" || die "retired list failed"
grep -q $'^guard\talpha\tnew-owner\t30\t.*\tretired$' "$RIG/retired-list.out" ||
    die "retired watcher row differs"
printf 'ok P5 — watcher declare/list/retire and five-line marker\n'

# P6: watcher identities stay out of session tables and obey marker retention.
home=$RIG/display
init_home "$home"
now=$(date +%s)
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 0 --owner owner >/dev/null ||
    die "display watcher declaration failed"
printf '%s\n' "$now" > "$home/presence/guard@alpha"
printf '%s\n' "$now" > "$home/presence/human@alpha"
KHALA_HOME=$home KHALA_SESSION=guard "$KHALA" mind -m monitoring >/dev/null ||
    die "watcher mind fixture failed"
KHALA_HOME=$home "$KHALA" presence >"$RIG/presence.out" || die "presence failed"
grep -q '^guard@alpha' "$RIG/presence.out" && die "watcher leaked into main presence table"
grep -q '^human@alpha' "$RIG/presence.out" || die "human missing from presence"
grep -qx 'watchers:' "$RIG/presence.out" || die "presence watcher section missing"
grep -q $'^guard\talpha\towner\t0\t-\tactive$' "$RIG/presence.out" ||
    die "presence watcher row differs"
KHALA_HOME=$home "$KHALA" presence --watchers >"$RIG/only-watchers.out" ||
    die "presence --watchers failed"
head -n 1 "$RIG/only-watchers.out" | grep -qx 'watchers:' ||
    die "watchers-only section heading differs"
grep -q '^ADDRESS' "$RIG/only-watchers.out" && die "watchers-only printed session table"
grep -q 'asleep = ' "$RIG/only-watchers.out" && die "watchers-only printed session legend"
KHALA_HOME=$home "$KHALA" minds >"$RIG/minds.out" || die "minds failed"
grep -q '^guard@alpha' "$RIG/minds.out" && die "watcher leaked into minds"

sed 's/^retain .*/retain 1/' "$home/config" > "$home/tmp/config.retention"
mv "$home/tmp/config.retention" "$home/config"
old=$((now - 172800))
write_marker "$home/presence/retired-old@alpha.watcher" "retired $old" 0 owner "$now" active
write_marker "$home/presence/stale@alpha.watcher" "$old" 0 owner "$old" active
write_marker "$home/presence/recent-notify@alpha.watcher" "$old" 0 owner "$now" active
write_marker "$home/presence/recent-declare@alpha.watcher" "$now" 0 owner "$old" active
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/prune.err" ||
    die "watcher prune reconcile failed: $(tr '\n' ' ' < "$RIG/prune.err")"
[ ! -e "$home/presence/retired-old@alpha.watcher" ] || die "old retired watcher survived"
[ ! -e "$home/presence/stale@alpha.watcher" ] || die "fully stale watcher survived"
[ -f "$home/presence/recent-notify@alpha.watcher" ] || die "recent notify watcher was pruned"
[ -f "$home/presence/recent-declare@alpha.watcher" ] || die "recent declaration watcher was pruned"
printf 'ok P6 — presence/minds split and watcher retention\n'

# P7: dead-man emits exactly one notice for each silent/active transition.
home=$RIG/deadman
init_home "$home"
now=$(date +%s)
old=$((now - 100))
write_marker "$home/presence/guard@alpha.watcher" "$old" 10 owner 0 active
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/deadman-1.err" ||
    die "silent transition reconcile failed: $(tr '\n' ' ' < "$RIG/deadman-1.err")"
[ "$(count_files "$home/inbox/owner/new")" -eq 1 ] || die "silent transition did not deliver one notice"
silent_notice=
for path in "$home/inbox/owner/new"/*; do silent_notice=$path; break; done
grep -qx 'From: guard@alpha' "$silent_notice" || die "silent notice From differs"
grep -qx 'To: owner@alpha' "$silent_notice" || die "silent notice To differs"
grep -qx 'Type: notice' "$silent_notice" || die "silent notice Type differs"
grep -qx 'Urgency: urgent' "$silent_notice" || die "silent notice is not urgent"
grep -Eq '^Subject: \[watcher\] guard silent [0-9]+[smhd] \(cadence 10s\)$' "$silent_notice" ||
    die "silent notice subject differs"
grep -Fqx "watcher marker: $home/presence/guard@alpha.watcher" "$silent_notice" ||
    die "silent notice body does not name marker path"
grep -Eq '^silent [0-9]+$' "$home/presence/guard@alpha.watcher" ||
    die "marker did not enter silent state"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "steady silent reconcile failed"
[ "$(count_files "$home/inbox/owner/new")" -eq 1 ] || die "steady silent state emitted another notice"
silent_since=$(sed -n '5p' "$home/presence/guard@alpha.watcher")
write_marker "$home/presence/guard@alpha.watcher" "$old" 10 owner "$(date +%s)" "$silent_since"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/deadman-2.err" ||
    die "recovery transition reconcile failed: $(tr '\n' ' ' < "$RIG/deadman-2.err")"
[ "$(count_files "$home/inbox/owner/new")" -eq 2 ] || die "recovery did not emit exactly one notice"
active_notice=
for path in "$home/inbox/owner/new"/*; do
    grep -q '^Urgency: info$' "$path" && active_notice=$path
done
[ -n "$active_notice" ] || die "recovery info notice missing"
grep -Fqx 'Subject: [watcher] guard active again' "$active_notice" ||
    die "recovery subject differs"
[ "$(sed -n '5p' "$home/presence/guard@alpha.watcher")" = active ] ||
    die "marker did not return active"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "steady active reconcile failed"
[ "$(count_files "$home/inbox/owner/new")" -eq 2 ] || die "steady active state emitted another notice"
[ "$(count_files "$home/outbox/new")" -eq 0 ] || die "dead-man notices entered outbox"
printf 'ok P7 — one notice per dead-man transition\n'

# P8: runtime registration is never attempted for a live watcher identity.
home=$RIG/bind
init_home "$home"
log=$RIG/link-invocations
stub=$home/bin/khala-link
mkdir -p "$home/bin"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> '$log'" \
    'printf "instance fixture\\n"' > "$stub"
chmod 755 "$stub"
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 0 --owner owner >/dev/null ||
    die "bind watcher declaration failed"
if KHALA_HOME=$home KHALA_SESSION=guard "$KHALA" bind --register starting \
    >"$RIG/bind.out" 2>"$RIG/bind.err"; then
    die "watcher runtime registration succeeded"
fi
[ ! -e "$log" ] || die "watcher refusal happened after runtime invocation"
[ "$(wc -l < "$RIG/bind.err" | tr -d ' ')" -eq 1 ] || die "watcher refusal was not one stderr line"
grep -q 'watcher' "$RIG/bind.err" || die "watcher refusal is unclear"
KHALA_HOME=$home "$KHALA" watcher retire guard >/dev/null || die "bind watcher retire failed"
KHALA_HOME=$home KHALA_SESSION=guard "$KHALA" bind --register starting \
    >"$RIG/bind-retired.out" 2>"$RIG/bind-retired.err" || die "retired watcher registration failed"
[ -s "$log" ] || die "retired watcher registration did not reach runtime"
printf 'ok P8 — live watcher identity cannot acquire a session lease\n'

printf 'RESULT: PASS\n'
