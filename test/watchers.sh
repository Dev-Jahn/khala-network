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

first_file() {
    for first_file_path in "$1"/*; do
        [ -f "$first_file_path" ] || continue
        printf '%s\n' "$first_file_path"
        return 0
    done
    return 1
}

init_home() {
    init_home_path=$1
    KHALA_HOME=$init_home_path "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" ||
        die "init failed: $(tr '\n' ' ' < "$RIG/init.err")"
    printf 'retention-interval 0\n' >> "$init_home_path/config" || die "config append failed"
}

write_marker() {
    marker_path=$1
    marker_l1=$2
    marker_l2=$3
    marker_l3=$4
    marker_l4=$5
    marker_l5=$6
    marker_l6=${7-}
    if [ "$#" -eq 7 ]; then
        printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$marker_l1" "$marker_l2" "$marker_l3" \
            "$marker_l4" "$marker_l5" "$marker_l6" > "$marker_path"
    else
        printf '%s\n%s\n%s\n%s\n%s\n' "$marker_l1" "$marker_l2" "$marker_l3" \
            "$marker_l4" "$marker_l5" > "$marker_path"
    fi
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
[ "$(wc -l < "$marker" | tr -d ' ')" -eq 6 ] || die "watcher marker is not six lines"
declared=$(sed -n '1p' "$marker")
[ "$declared" -gt 0 ] || die "declared epoch invalid"
[ "$(sed -n '2p' "$marker")" = 10 ] || die "cadence differs"
[ "$(sed -n '3p' "$marker")" = owner@alpha ] || die "owner differs"
[ "$(sed -n '4p' "$marker")" = 0 ] || die "new declaration did not start at never"
[ "$(sed -n '5p' "$marker")" = active ] || die "new declaration state differs"
[ "$(sed -n '6p' "$marker")" = "$declared" ] || die "new declaration state-since differs"
# A five-line 0.8.0/0.8.1 marker remains readable. Its silent timestamp is the
# state-since value when the next writer upgrades it to six lines.
write_marker "$marker" "$declared" 10 owner 123 'silent 124'
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 30 --owner new-owner >/dev/null ||
    die "watcher re-declare failed"
[ "$(sed -n '2p' "$marker")" = 30 ] && [ "$(sed -n '3p' "$marker")" = new-owner@alpha ] ||
    die "re-declare did not update cadence/owner"
[ "$(sed -n '4p' "$marker")" = 123 ] && [ "$(sed -n '5p' "$marker")" = 'silent 124' ] ||
    die "re-declare did not preserve L4/L5"
[ "$(sed -n '6p' "$marker")" = 124 ] || die "re-declare did not preserve legacy state-since"
write_marker "$home/presence/remote@beta.watcher" "$declared" 60 remote-owner 0 active
KHALA_HOME=$home "$KHALA" watcher list >"$RIG/list.out" || die "watcher list failed"
head -n 1 "$RIG/list.out" | grep -qx $'NAME\tNODE\tOWNER\tCADENCE\tLAST\tSTATE\tSINCE' ||
    die "watcher list header differs"
grep -q $'^guard\talpha\tnew-owner@alpha\t30\t.*\tsilent\t[0-9smhd-]*$' "$RIG/list.out" ||
    die "local watcher list row differs"
grep -q $'^remote\tbeta\tremote-owner\t60\t-\tactive\t[0-9smhd-]*$' "$RIG/list.out" ||
    die "remote watcher list row differs"
KHALA_HOME=$home "$KHALA" watcher retire guard >"$RIG/retire.out" || die "watcher retire failed"
grep -Eq '^retired [0-9]+$' "$marker" || die "retire did not rewrite L1"
[ "$(wc -l < "$marker" | tr -d ' ')" -eq 6 ] || die "retire did not write six lines"
KHALA_HOME=$home "$KHALA" watcher list >"$RIG/retired-list.out" || die "retired list failed"
grep -q $'^guard\talpha\tnew-owner@alpha\t30\t.*\tretired\t[0-9smhd-]*$' "$RIG/retired-list.out" ||
    die "retired watcher row differs"
printf 'ok P5 — watcher declare/list/retire, legacy read, six-line write, and SINCE\n'

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
grep -q $'^guard\talpha\towner@alpha\t0\t-\tactive\t[0-9smhd-]*$' "$RIG/presence.out" ||
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
[ "$(wc -l < "$home/presence/guard@alpha.watcher" | tr -d ' ')" -eq 6 ] ||
    die "dead-man transition did not upgrade marker to six lines"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null || die "steady silent reconcile failed"
[ "$(count_files "$home/inbox/owner/new")" -eq 1 ] || die "steady silent state emitted another notice"
silent_since=$(sed -n '5p' "$home/presence/guard@alpha.watcher")
[ "$(sed -n '6p' "$home/presence/guard@alpha.watcher")" = "${silent_since#silent }" ] ||
    die "silent state-since differs from transition epoch"
write_marker "$home/presence/guard@alpha.watcher" "$old" 10 owner "$(date +%s)" \
    "$silent_since" "${silent_since#silent }"
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
active_since=$(sed -n '6p' "$home/presence/guard@alpha.watcher")
[ "$active_since" -ge "$now" ] || die "active state-since was not refreshed on recovery"
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

# P9: beat refreshes only last-notify on the watcher's own node.
home=$RIG/beat
init_home "$home"
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 60 --owner owner >/dev/null ||
    die "beat watcher declaration failed"
marker=$home/presence/guard@alpha.watcher
declared=$(sed -n '1p' "$marker")
write_marker "$marker" "$declared" 60 owner@alpha 1 active "$declared"
mkdir "$home/run/brain.lock.d" || die "could not create beat contention lock"
printf '%s\npid 4242 beat-holder\n' "$(date +%s)" > "$home/run/brain.lock.d/owner"
(
    sleep 1
    rm -f "$home/run/brain.lock.d/owner"
    rmdir "$home/run/brain.lock.d"
) &
beat_holder_pid=$!
KHALA_HOME=$home "$KHALA" watcher beat guard >"$RIG/beat.out" 2>"$RIG/beat.err" ||
    die "watcher beat failed"
wait "$beat_holder_pid" || die "beat contention holder failed"
[ ! -s "$RIG/beat.err" ] || die "watcher beat wrote stderr"
[ "$(sed -n '1p' "$marker")" = "$declared" ] || die "beat changed declaration"
[ "$(sed -n '2p' "$marker")" = 60 ] || die "beat changed cadence"
[ "$(sed -n '3p' "$marker")" = owner@alpha ] || die "beat changed owner"
[ "$(sed -n '4p' "$marker")" -gt 1 ] || die "beat did not refresh last-notify"
[ "$(sed -n '5p' "$marker")" = active ] || die "beat changed state"
[ "$(sed -n '6p' "$marker")" = "$declared" ] || die "beat changed state-since"
[ ! -e "$home/presence/guard@alpha" ] || die "beat wrote a presence heartbeat"
[ ! -e "$home/run/reconcile.trigger" ] || die "beat wrote reconcile.trigger"
[ "$(count_files "$home/outbox/new")" -eq 0 ] || die "beat wrote outbox"
[ "$(count_files "$home/spool/for/alpha")" -eq 0 ] || die "beat wrote spool"
[ "$(count_files "$home/inbox/owner/new")" -eq 0 ] || die "beat wrote inbox"
if KHALA_HOME=$home "$KHALA" watcher beat missing >"$RIG/beat-missing.out" \
    2>"$RIG/beat-missing.err"; then
    die "undeclared watcher beat succeeded"
fi
[ ! -s "$RIG/beat-missing.out" ] || die "undeclared beat wrote stdout"
[ "$(wc -l < "$RIG/beat-missing.err" | tr -d ' ')" -eq 1 ] ||
    die "undeclared beat error was not one line"
KHALA_HOME=$home "$KHALA" watcher retire guard >/dev/null || die "beat watcher retire failed"
if KHALA_HOME=$home "$KHALA" watcher beat guard >"$RIG/beat-retired.out" \
    2>"$RIG/beat-retired.err"; then
    die "retired watcher beat succeeded"
fi
[ ! -s "$RIG/beat-retired.out" ] || die "retired beat wrote stdout"
[ "$(wc -l < "$RIG/beat-retired.err" | tr -d ' ')" -eq 1 ] ||
    die "retired beat error was not one line"
printf 'ok P9 — watcher beat refreshes only L4 and rejects undeclared/retired names\n'


# P5b — the owner is a full address; a remote owner receives the dead-man notice in its node's spool
# (GPT-Pro P0-2, 2026-09-02).
home=$RIG/remote-owner
KHALA_HOME=$home "$KHALA" init alpha >/dev/null 2>&1 || die "remote-owner init failed"
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 60 --owner steno@beta >/dev/null || die "remote owner declare failed"
marker=$home/presence/guard@alpha.watcher
now=$(date +%s)
printf '%s\n60\nsteno@beta\n%s\nactive\n' "$((now - 1000))" "$((now - 1000))" > "$marker"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>&1 || die "remote-owner reconcile failed"
[ "$(wc -l < "$marker" | tr -d ' ')" -eq 6 ] || die "remote legacy marker was not upgraded"
deadman=$(first_file "$home/spool/for/beta") || die "dead-man notice for a remote owner was not spooled to its node"
grep -q '^To: steno@beta$' "$deadman" || die "dead-man notice is not addressed to the remote owner"
KHALA_HOME=$home "$KHALA" watcher declare local --cadence 60 --owner steno >/dev/null || die "bare owner declare failed"
grep -q '^steno@alpha$' "$home/presence/local@alpha.watcher" || die "bare owner was not qualified with the local node"
printf 'ok P5b — owner is a full address; remote owners get the dead-man notice via their node spool\n'

printf 'RESULT: PASS\n'
