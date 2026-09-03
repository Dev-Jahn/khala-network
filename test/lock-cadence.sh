#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
RIG=$HOME/.khala-lock-cadence-test-$$

cleanup() {
    rm -rf -- "$RIG"
}

die() {
    printf '    %s\n' "$*" >&2
    exit 1
}

mkdir -p "$RIG"
trap cleanup EXIT HUP INT TERM

home=$RIG/home
KHALA_HOME=$home "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" ||
    die "init failed"
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 0 --owner owner >/dev/null ||
    die "watcher declaration failed"

# Keep all six callers behind the same live lock long enough that a one-second
# retry cadence cannot meet the bound. The 300-second stale threshold remains
# irrelevant: this holder is live for only seven seconds.
mkdir "$home/run/brain.lock.d" || die "could not create contention lock"
printf '%s\npid 4242 cadence-holder\n' "$(date +%s)" > "$home/run/brain.lock.d/owner"
(
    sleep 7
    rm -f "$home/run/brain.lock.d/owner"
    rmdir "$home/run/brain.lock.d"
) &
holder_pid=$!

slot=1
while [ "$slot" -le 6 ]; do
    date +%s > "$RIG/start.$slot"
    (
        if printf 'notice %s\n' "$slot" | KHALA_HOME=$home "$KHALA" \
            notify owner@beta --as guard >"$RIG/notify.$slot.out" \
            2>"$RIG/notify.$slot.err"; then
            printf '0\n' > "$RIG/status.$slot"
        else
            printf '%s\n' "$?" > "$RIG/status.$slot"
        fi
        date +%s > "$RIG/end.$slot"
    ) &
    eval "pid_$slot=$!"
    slot=$((slot + 1))
done

slot=1
while [ "$slot" -le 6 ]; do
    eval "notify_pid=\$pid_$slot"
    wait "$notify_pid" || :
    slot=$((slot + 1))
done
wait "$holder_pid" || die "contention holder failed"

printf 'pid\tstart\tend\twall\n'
max_wall=0
slot=1
while [ "$slot" -le 6 ]; do
    eval "notify_pid=\$pid_$slot"
    start=$(sed -n '1p' "$RIG/start.$slot")
    end=$(sed -n '1p' "$RIG/end.$slot")
    wall=$((end - start))
    printf '%s\t%s\t%s\t%s\n' "$notify_pid" "$start" "$end" "$wall"
    [ "$(sed -n '1p' "$RIG/status.$slot")" -eq 0 ] ||
        die "notify pid $notify_pid failed: $(tr '\n' ' ' < "$RIG/notify.$slot.err")"
    [ "$wall" -gt "$max_wall" ] && max_wall=$wall
    slot=$((slot + 1))
done

[ "$max_wall" -lt 10 ] || die "last concurrent notify finished in ${max_wall}s (bound <10s)"
printf 'ok B4 — six concurrent notify calls finished in at most %ss\n' "$max_wall"
printf 'RESULT: PASS\n'
