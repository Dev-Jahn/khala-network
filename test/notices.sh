#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
RIG=$HOME/.khala-notices-test-$$
. "$ROOT/test/lib/isolate.sh"

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

write_letter() {
    write_home=$1
    write_session=$2
    write_id=$3
    write_from=$4
    write_type=$5
    write_urgency=$6
    write_subject=$7
    write_expires=$8
    write_body=$9
    write_dir=$write_home/inbox/$write_session/new
    mkdir -p "$write_dir" "$write_home/inbox/$write_session/cur"
    {
        printf 'Khala: 0.1\n'
        printf 'Id: %s\n' "$write_id"
        printf 'From: %s\n' "$write_from"
        printf 'To: %s@alpha\n' "$write_session"
        printf 'Date: 2000-01-01T00:00:00Z\n'
        printf 'Type: %s\n' "$write_type"
        [ -z "$write_urgency" ] || printf 'Urgency: %s\n' "$write_urgency"
        [ -z "$write_subject" ] || printf 'Subject: %s\n' "$write_subject"
        printf 'Expires: %s\n' "$write_expires"
        printf '\n%s\n' "$write_body"
    } > "$write_dir/$write_id"
}

mkdir -p "$RIG"
trap 'cleanup; isolate_cleanup' EXIT HUP INT TERM

# P1-P2: an alert has its own header block and infrastructure-only lifecycle.
home=$RIG/envelope
init_home "$home"
if printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta -s missing \
    >"$RIG/missing.out" 2>"$RIG/missing.err"; then
    die "notify without --as succeeded"
fi
grep -q -- '--as' "$RIG/missing.err" || die "missing --as error is unclear"
if printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta --as 'bad_name' \
    >"$RIG/bad.out" 2>"$RIG/bad.err"; then
    die "invalid watchdog name succeeded"
fi
if printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta --as sentinel \
    -s $'bad\nsubject' >"$RIG/newline.out" 2>"$RIG/newline.err"; then
    die "multiline alert subject succeeded"
fi
KHALA_HOME=$home "$KHALA" watcher declare sentinel --cadence 0 --owner reader >/dev/null ||
    die "sentinel watchdog declaration failed"
printf 'temperature high\n' | KHALA_HOME=$home "$KHALA" notify reader@beta \
    --as sentinel -s 'thermal alarm' --urgent >"$RIG/notify.out" 2>"$RIG/notify.err" ||
    die "urgent notify failed: $(tr '\n' ' ' < "$RIG/notify.err")"
[ ! -s "$RIG/notify.err" ] || die "declared notify wrote stderr"
[ "$(count_files "$home/outbox/new")" -eq 0 ] || die "alert entered outbox/new"
[ "$(count_files "$home/outbox/acked")" -eq 0 ] || die "alert entered outbox/acked"
notice=$(first_file "$home/spool/for/beta") || die "alert did not enter remote spool"
notice_id=$(sed -n 's/^Id: //p' "$notice")
[ "$(basename "$notice")" = "$notice_id" ] || die "alert filename differs from Id"
printf '%s\n' "$notice_id" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.sentinel@alpha$' ||
    die "alert Id was not minted with watchdog identity"
expected_headers='Khala Id From To Date Type Urgency Subject Expires'
actual_headers=$(sed '/^$/q' "$notice" | sed '/^$/d; s/:.*//' | tr '\n' ' ' | sed 's/ $//')
[ "$actual_headers" = "$expected_headers" ] || die "alert header order differs: $actual_headers"
grep -qx 'From: sentinel@alpha' "$notice" || die "alert From differs"
grep -qx 'To: reader@beta' "$notice" || die "alert To differs"
grep -qx 'Type: notice' "$notice" || die "alert Type differs"
grep -qx 'Urgency: urgent' "$notice" || die "alert urgency differs"
grep -qx 'Subject: thermal alarm' "$notice" || die "alert subject differs"
grep -qx 'temperature high' "$notice" || die "alert body differs"
grep -Eq '^(Refs|In-Reply-To|Priority):' "$notice" && die "alert has a forbidden header"
expires=$(sed -n 's/^Expires: //p' "$notice")
now=$(date +%s)
[ "$expires" -gt "$((now + 172700))" ] && [ "$expires" -lt "$((now + 172900))" ] ||
    die "alert default expiry is not about 172800 seconds"
marker=$home/presence/sentinel@alpha.watcher
[ -f "$marker" ] || die "declared watchdog marker disappeared"
[ "$(sed -n '2p' "$marker")" = 0 ] || die "declared heartbeat interval changed"
[ "$(sed -n '3p' "$marker")" = reader@alpha ] || die "declared owner changed"
[ "$(sed -n '5p' "$marker")" = active ] || die "declared state changed"
[ "$(sed -n '4p' "$marker")" -gt 0 ] || die "notify did not update L4"
[ ! -e "$home/presence/sentinel@alpha" ] || die "notify wrote a plain heartbeat"
marker_declared=$(sed -n '1p' "$marker")
printf '%s\n%s\n%s\n%s\n%s\n' "$marker_declared" 000 reader@alpha 1 active > "$marker"
printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta --as sentinel \
    >"$RIG/notify-again.out" 2>"$RIG/notify-again.err" || die "repeat notify failed"
[ ! -s "$RIG/notify-again.err" ] || die "declared watchdog notify wrote stderr"
[ "$(sed -n '1p' "$marker")" = "$marker_declared" ] || die "notify changed watchdog L1"
[ "$(sed -n '2p' "$marker")" = 000 ] || die "notify changed watchdog L2"
[ "$(sed -n '3p' "$marker")" = reader@alpha ] || die "notify changed watchdog L3"
[ "$(sed -n '5p' "$marker")" = active ] || die "notify changed watchdog L5"
[ "$(sed -n '4p' "$marker")" -gt 1 ] || die "repeat notify did not replace watchdog L4"

KHALA_HOME=$home "$KHALA" watcher declare local --cadence 0 --owner reader >/dev/null ||
    die "local watchdog declaration failed"
printf '' | KHALA_HOME=$home "$KHALA" notify reader@alpha --as local \
    >"$RIG/local.out" 2>"$RIG/local.err" || die "local notify failed"
local_id=$(tr -d '\n' < "$RIG/local.out")
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/local-reconcile.err" ||
    die "local alert reconcile failed"
[ -f "$home/inbox/reader/new/$local_id" ] || die "local alert was not delivered"
[ "$(count_files "$home/outbox/acked")" -eq 0 ] || die "local alert minted an ack"
printf 'ok P1-P2 — alert header block, infrastructure path, and watchdog heartbeat split\n'

# P3: read mail, alerts, and streams in distinct lanes with separate selection.
home=$RIG/drain
init_home "$home"
now=$(date +%s)
future=$((now + 10000))
write_letter "$home" reader "$((now - 30)).1.1.sender@alpha" sender@alpha message '' letter-one "$future" mail-one
write_letter "$home" reader "$((now - 29)).1.2.guard-a@alpha" guard-a@alpha notice urgent urgent-one "$future" notice-one
write_letter "$home" reader "$((now - 28)).1.3.sender@alpha" sender@alpha message '' letter-two "$future" mail-two
write_letter "$home" reader "$((now - 27)).1.4.guard-b@alpha" guard-b@alpha notice info info-one "$future" notice-two
KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say news -m stream-one >/dev/null ||
    die "stream fixture write failed"
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" join news --from-start >/dev/null ||
    die "stream fixture join failed"
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --notices-only \
    --max-notices 1 --max-notice-bytes 16384 >"$RIG/notices-only.out" ||
    die "notices-only inbox read failed"
grep -q '^=== notices (1) ===$' "$RIG/notices-only.out" || die "alerts header differs"
grep -q '^--- notice .* --- guard-a@alpha · urgent · urgent-one$' "$RIG/notices-only.out" ||
    die "urgent alert display differs"
grep -q '^--- letter ' "$RIG/notices-only.out" && die "notices-only read mail"
grep -q '^--- stream ' "$RIG/notices-only.out" && die "notices-only read a stream"
grep -qx 'drained: letters 0, notices 1, streams 0' "$RIG/notices-only.out" ||
    die "notices-only summary differs"
[ ! -e "$home/cursor/reader/news" ] || die "notices-only advanced a stream cursor"
[ "$(grep -l '^Type: message$' "$home"/inbox/reader/new/* | wc -l | tr -d ' ')" -eq 2 ] ||
    die "notices-only moved mail"

KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --mail-only \
    >"$RIG/mail-only.out" || die "mail-only inbox read failed"
grep -q '^--- letter ' "$RIG/mail-only.out" || die "mail-only omitted messages"
grep -q '^--- stream news ' "$RIG/mail-only.out" || die "mail-only omitted streams"
grep -q '^=== notices' "$RIG/mail-only.out" && die "mail-only printed alerts"
grep -qx 'drained: letters 2, notices 0, streams 1' "$RIG/mail-only.out" ||
    die "mail-only summary differs"
[ "$(grep -l '^Type: notice$' "$home"/inbox/reader/new/* | wc -l | tr -d ' ')" -eq 1 ] ||
    die "mail-only moved an alert"

write_letter "$home" reader "$((now - 26)).1.5.sender@alpha" sender@alpha message '' final-letter "$future" final-mail
write_letter "$home" reader "$((now - 25)).1.6.guard-c@alpha" guard-c@alpha notice info final-notice "$future" final-info
KHALA_HOME=$home KHALA_SESSION=speaker "$KHALA" say news -m stream-two >/dev/null ||
    die "second stream fixture failed"
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/all.out" ||
    die "combined inbox read failed"
letter_line=$(grep -n '^--- letter ' "$RIG/all.out" | head -n 1 | cut -d: -f1)
notice_line=$(grep -n '^=== notices' "$RIG/all.out" | head -n 1 | cut -d: -f1)
stream_line=$(grep -n '^--- stream ' "$RIG/all.out" | head -n 1 | cut -d: -f1)
[ "$letter_line" -lt "$notice_line" ] && [ "$notice_line" -lt "$stream_line" ] ||
    die "inbox read order is not messages, alerts, streams"
grep -qx 'drained: letters 1, notices 2, streams 1' "$RIG/all.out" ||
    die "combined inbox read summary differs"
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/empty.out" ||
    die "empty inbox read failed"
[ "$(cat "$RIG/empty.out")" = 'drained: letters 0, notices 0, streams 0' ] ||
    die "empty inbox read did not print explicit zero summary"

# Count overflow independently and group alert senders by descending count.
for suffix in 10 11 12; do
    write_letter "$home" reader "$((now + suffix)).1.$suffix.guard-a@alpha" guard-a@alpha notice info cap-a "$future" cap
done
for suffix in 13 14; do
    write_letter "$home" reader "$((now + suffix)).1.$suffix.guard-b@alpha" guard-b@alpha notice info cap-b "$future" cap
done
write_letter "$home" reader "$((now + 9)).1.9.guard-c@alpha" guard-c@alpha notice info cap-c "$future" cap
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --max-notices 1 \
    --max-notice-bytes 16384 >"$RIG/cap.out" || die "capped alert inbox read failed"
grep -Fqx '알림 5건 더 (guard-a@alpha 3, guard-b@alpha 2)' "$RIG/cap.out" ||
    die "alert overflow grouping/order differs"
grep -qx 'drained: letters 0, notices 1, streams 0' "$RIG/cap.out" ||
    die "capped summary differs"

home=$RIG/envelope-controls
init_home "$home"
now=$(date +%s)
future=$((now + 10000))
write_letter "$home" reader "$now.4.1.sender@alpha" sender@alpha message '' body-spoof "$future" \
    $'Type: notice\nUrgency: info'
write_letter "$home" reader "$((now + 1)).4.2.guard@alpha" guard@alpha notice info envelope-info "$future" \
    'Urgency: urgent'
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --max-notice-bytes 1 \
    >"$RIG/byte-cap.out" || die "alert byte cap inbox read failed"
grep -q '^--- letter ' "$RIG/byte-cap.out" || die "body Type spoof changed mail classification"
grep -q '^--- notice ' "$RIG/byte-cap.out" && die "alert byte cap was not independent"
grep -qx 'drained: letters 1, notices 0, streams 0' "$RIG/byte-cap.out" ||
    die "alert byte cap changed mail/stream caps"
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/envelope-info.out" ||
    die "header-only alert inbox read failed"
grep -q '^--- notice .* · info · envelope-info$' "$RIG/envelope-info.out" ||
    die "body Urgency spoof changed alert urgency"
printf 'ok P3 — inbox read split, modes, order, caps, overflow, and zero summary\n'

# P4: expiry and retain clean archives without deleting unread mail.
home=$RIG/retention
init_home "$home"
sed 's/^retain .*/retain 1/' "$home/config" > "$home/tmp/config.retention"
mv "$home/tmp/config.retention" "$home/config"
now=$(date +%s)
old=$((now - 172800))
future=$((now + 10000))
expired=$((now - 1))
write_letter "$home" reader "$old.2.1.oldmail@alpha" oldmail@alpha message '' unread "$expired" unread-truth
write_letter "$home" reader "$old.2.2.oldnotice@alpha" oldnotice@alpha notice info expired-new "$expired" gone
mv "$home/inbox/reader/new/$old.2.2.oldnotice@alpha" "$home/inbox/reader/cur/$old.2.2.oldnotice@alpha"
write_letter "$home" reader "$old.2.3.oldnotice@alpha" oldnotice@alpha notice info expired-cur "$expired" gone
mv "$home/inbox/reader/new/$old.2.3.oldnotice@alpha" "$home/inbox/reader/cur/$old.2.3.oldnotice@alpha"
write_letter "$home" reader "$now.2.4.live@alpha" live@alpha notice info live "$future" stay
mv "$home/inbox/reader/new/$now.2.4.live@alpha" "$home/inbox/reader/cur/$now.2.4.live@alpha"
write_letter "$home" reader "$old.2.5.archive@alpha" archive@alpha message '' old-cur "$future" old
mv "$home/inbox/reader/new/$old.2.5.archive@alpha" "$home/inbox/reader/cur/$old.2.5.archive@alpha"
# retention counts from the time the file entered cur/ (its mtime), so age it explicitly
touch -d "@$old" "$home/inbox/reader/cur/$old.2.5.archive@alpha" 2>/dev/null ||
    touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null)" "$home/inbox/reader/cur/$old.2.5.archive@alpha"
for archive_dir in outbox/acked outbox/dead; do
    cp "$home/inbox/reader/new/$old.2.1.oldmail@alpha" "$home/$archive_dir/$old.2.1.oldmail@alpha"
    # retention ages from the time the file entered acked/dead (its mtime)
    touch -d "@$old" "$home/$archive_dir/$old.2.1.oldmail@alpha" 2>/dev/null ||
        touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null)" "$home/$archive_dir/$old.2.1.oldmail@alpha"
done
mkdir -p "$home/spool/for/beta"
cp "$home/inbox/reader/cur/$old.2.3.oldnotice@alpha" "$home/spool/for/beta/$old.2.3.oldnotice@alpha"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/retention.err" ||
    die "retention reconcile failed: $(tr '\n' ' ' < "$RIG/retention.err")"
[ -f "$home/inbox/reader/new/$old.2.1.oldmail@alpha" ] || die "retention deleted unread mail"
[ ! -e "$home/inbox/reader/cur/$old.2.2.oldnotice@alpha" ] || die "expired cur alert survived"
[ ! -e "$home/inbox/reader/cur/$old.2.3.oldnotice@alpha" ] || die "second expired cur alert survived"
[ -f "$home/inbox/reader/cur/$now.2.4.live@alpha" ] || die "live cur alert was deleted"
[ ! -e "$home/inbox/reader/cur/$old.2.5.archive@alpha" ] || die "old cur mail survived retain"
[ ! -e "$home/outbox/acked/$old.2.1.oldmail@alpha" ] || die "old acked file survived retain"
[ ! -e "$home/outbox/dead/$old.2.1.oldmail@alpha" ] || die "old dead file survived retain"
[ ! -e "$home/spool/for/beta/$old.2.3.oldnotice@alpha" ] || die "expired spool alert survived"
[ ! -d "$home/inbox/oldnotice" ] || die "expired spool alert was delivered"
[ ! -s "$RIG/retention.err" ] || die "alert expiry was not silent"
printf 'ok P4 — alert expiry, archive retention, and unread-mail truth\n'

# P9: send compatibility hint and empty KHALA_SESSION resolution.
home=$RIG/session
init_home "$home"
# A recipient some session has used, so the hint is the only stderr line
# (an unseen address adds the D18 warning).
date +%s > "$home/presence/reader@alpha"
KHALA_HOME=$home "$KHALA" send reader@alpha --as machine -m body \
    >"$RIG/send-as.out" 2>"$RIG/send-as.err" || die "send --as failed"
[ "$(cat "$RIG/send-as.err")" = 'khala send --as: 세션이 아닌 발신자라면 khala notify를 쓰세요' ] ||
    die "send --as hint differs or is not exactly one line"
project=$RIG/project
mkdir -p "$project"
printf 'file-session\n' > "$project/.khala-session"
(cd "$project" && KHALA_HOME=$home KHALA_SESSION= "$KHALA" send reader@alpha -m file-body \
    >"$RIG/empty-session.out" 2>"$RIG/empty-session.err") || die "empty KHALA_SESSION did not fall through"
[ "$(wc -l < "$RIG/empty-session.err" | tr -d ' ')" -eq 1 ] ||
    die "empty KHALA_SESSION did not emit exactly one warning"
empty_id=$(tr -d '\n' < "$RIG/empty-session.out")
grep -qx 'From: file-session@alpha' "$home/outbox/new/$empty_id" ||
    die "empty KHALA_SESSION did not use .khala-session"
printf 'ok P9 — send hint and empty environment resolution\n'

# P10: SessionStart reports the actual mail/alert split among read files.
home=$RIG/hook-khala
init_home "$home"
hook_home=$RIG/hook-home
hook_project=$RIG/hook-project
hook_shim=$RIG/hook-shim
mkdir -p "$hook_home/.local/bin" "$hook_project" "$hook_shim" "$home/bin"
ln -s "$KHALA" "$hook_home/.local/bin/khala"
ln -s "$KHALA" "$hook_shim/khala"
printf 'reader\n' > "$hook_project/.khala-session"
write_letter "$home" reader "$now.3.1.sender@alpha" sender@alpha message '' hook-mail "$future" mail
write_letter "$home" reader "$now.3.2.guard@alpha" guard@alpha notice info hook-notice "$future" notice
apply_stub=$home/bin/khala-link
printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  "runtime register --identity reader --phase starting"*) printf "instance fixture\\n" ;;' \
    '  "runtime register --identity reader --phase ready"*) printf "owner yes\\n" ;;' \
    '  "runtime native-warning"*) exit 0 ;;' \
    '  "runtime daemon-status"*) exit 0 ;;' \
    'esac' > "$apply_stub"
chmod 755 "$apply_stub"
HOME=$hook_home KHALA_HOME=$home CLAUDE_PROJECT_DIR=$hook_project \
    KHALA_RUNTIME_DIR=$home/runtime-root KHALA_TEST_BOOT_ID=notices-test \
    KHALA_CLAUDE_SESSION_ID=fixture KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    PATH=$hook_shim:/usr/bin:/bin "$START" </dev/null >"$RIG/hook.out" 2>"$RIG/hook.err" ||
    die "SessionStart fixture failed"
grep -q '편지 1건·알림 1건 드레인' "$RIG/hook.out" ||
    die "SessionStart inbox read split summary differs"
printf 'ok P10 — SessionStart inbox read report splits mail and alerts\n'


# P4b — retention never follows a directory symlink out of KHALA_HOME, and a symlinked
# file is never deleted (verification finding 2026-09-02).
home=$RIG/escape
init_home "$home"
outside=$RIG/outside
mkdir -p "$outside/new" "$outside/cur" "$outside/spool"
now=$(date +%s)
old=$((now - 40 * 86400))
expired=$((now - 1))
future=$((now + 99999))
write_letter "$home" real "$old.1.1.sender@alpha" sender@alpha message '' keep "$expired" mail
{
    printf 'Khala: 0.1\nId: %s\nFrom: guard@alpha\nTo: real@alpha\nDate: 2000-01-01T00:00:00Z\nType: notice\nUrgency: info\nExpires: %s\n\nbody\n' \
        "$old.1.2.guard@alpha" "$expired"
} > "$outside/direct-target"
ln -s "$outside/direct-target" "$home/inbox/real/new/$old.1.2.guard@alpha"
ln -s "$outside" "$home/inbox/escape"
printf 'Khala: 0.1\nId: %s\nFrom: guard@alpha\nTo: x@alpha\nDate: 2000-01-01T00:00:00Z\nType: notice\nUrgency: info\nExpires: %s\n\nbody\n' \
    "$old.1.3.guard@alpha" "$expired" > "$outside/new/$old.1.3.guard@alpha"
printf 'Khala: 0.1\nId: %s\nFrom: sender@alpha\nTo: x@alpha\nDate: 2000-01-01T00:00:00Z\nType: message\nExpires: %s\n\nbody\n' \
    "$old.1.4.sender@alpha" "$future" > "$outside/cur/$old.1.4.sender@alpha"
ln -s "$outside/spool" "$home/spool/for/escape"
printf 'Khala: 0.1\nId: %s\nFrom: guard@alpha\nTo: x@escape\nDate: 2000-01-01T00:00:00Z\nType: notice\nUrgency: info\nExpires: %s\n\nbody\n' \
    "$old.1.5.guard@alpha" "$expired" > "$outside/spool/$old.1.5.guard@alpha"
KHALA_HOME=$home "$KHALA" reconcile >"$RIG/escape.out" 2>"$RIG/escape.err" || die "escape reconcile failed"
[ -f "$home/inbox/real/new/$old.1.1.sender@alpha" ] || die "retention deleted undrained mail"
[ -f "$outside/direct-target" ] || die "retention deleted a symlink target"
[ -f "$outside/new/$old.1.3.guard@alpha" ] || die "retention followed inbox/ directory symlink (new)"
[ -f "$outside/cur/$old.1.4.sender@alpha" ] || die "retention followed inbox/ directory symlink (cur)"
[ -f "$outside/spool/$old.1.5.guard@alpha" ] || die "retention followed spool/for directory symlink"
printf 'ok P4b — retention never follows a symlink out of KHALA_HOME\n'

# P4c — oversized numbers are rejected instead of wrapping (verification finding 2026-09-02).
home=$RIG/bounds
init_home "$home"
huge=999999999999999999999999999999
if printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta --as guard -e "$huge" \
    >"$RIG/huge-e.out" 2>"$RIG/huge-e.err"; then
    die "notify accepted an unbounded -e"
fi
if KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 9223372036854775807 --owner owner \
    >"$RIG/huge-cadence.out" 2>"$RIG/huge-cadence.err"; then
    die "watchdog declare accepted an unbounded heartbeat interval"
fi
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 600 --owner owner >/dev/null ||
    die "bounded heartbeat interval declare failed"
now=$(date +%s)
future_id="$((now + 3000000000)).1.1.sender@alpha"
mkdir -p "$home/inbox/reader/cur"
printf 'Khala: 0.1\nId: %s\nFrom: sender@alpha\nTo: reader@alpha\nDate: 2000-01-01T00:00:00Z\nType: message\nExpires: %s\n\nbody\n' \
    "$future_id" "$((now + 3000000000))" > "$home/inbox/reader/cur/$future_id"
mkdir -p "$home/inbox/reader/new"
printf 'Khala: 0.1\nId: %s\nFrom: guard@alpha\nTo: reader@alpha\nDate: 2000-01-01T00:00:00Z\nType: notice\nUrgency: info\nExpires: %s\n\nbody\n' \
    "$now.1.2.guard@alpha" "$huge" > "$home/inbox/reader/new/$now.1.2.guard@alpha"
KHALA_HOME=$home "$KHALA" reconcile >"$RIG/bounds.out" 2>"$RIG/bounds.err" || die "bounds reconcile failed"
[ -f "$home/inbox/reader/cur/$future_id" ] || die "a future Id epoch was pruned as old"
[ -f "$home/inbox/reader/new/$now.1.2.guard@alpha" ] || die "an unparseable Expires deleted an alert"
[ "$(count_files "$home/spool/for/alpha")" -eq 0 ] || die "a bounded heartbeat interval fired heartbeat timeout immediately"
printf 'ok P4c — oversized numbers are refused; future epochs and unparseable Expires never delete\n'


# P1b — a same-node alert leaves the core CLI trigger so the relay's 200 ms poll delivers it now.
home=$RIG/trigger
init_home "$home"
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 0 --owner reader >/dev/null ||
    die "trigger watchdog declaration failed"
rm -f "$home/run/reconcile.trigger"
printf '' | KHALA_HOME=$home "$KHALA" notify reader@alpha --as guard -s local >/dev/null 2>&1 || die "same-node notify failed"
[ -f "$home/run/reconcile.trigger" ] || die "same-node notify left no reconcile trigger"
rm -f "$home/run/reconcile.trigger"
printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta --as guard -s remote >/dev/null 2>&1 || die "remote notify failed"
[ ! -f "$home/run/reconcile.trigger" ] || die "remote notify wrote a trigger it does not need"
printf 'ok P1b — same-node notify triggers reconcile; remote notify does not\n'


# P1c — an alert keeps its source queued copy: no outbox, and reconcile (which runs the
# same infrastructure pruning the rsync fallback uses) leaves an unexpired copy in place
# (GPT-Pro P0-1, 2026-09-02). The upstream accepting bytes is not delivery.
home=$RIG/custody
init_home "$home"
KHALA_HOME=$home "$KHALA" watcher declare guard --cadence 0 --owner reader >/dev/null ||
    die "custody watchdog declaration failed"
printf '' | KHALA_HOME=$home "$KHALA" notify reader@beta --as guard -s custody >/dev/null 2>&1 || die "custody notify failed"
notice_copy=$(first_file "$home/spool/for/beta") || die "custody alert missing from spool"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>&1 || die "custody reconcile failed"
[ -f "$notice_copy" ] || die "reconcile removed an unexpired alert source copy"
[ "$(count_files "$home/outbox/new")" -eq 0 ] || die "alert entered outbox/new"
grep -q 'ack|bounce)' "$KHALA" || die "remove_pushed_infrastructure still deletes alerts after a push"
! grep -q 'ack|bounce|notice)' "$KHALA" || die "remove_pushed_infrastructure still lists alert"
printf 'ok P1c — alert source copy survives reconcile and is excluded from post-push removal\n'

# P4d — retention counts from the time a message entered cur/, not from its Id epoch (GPT-Pro P0-3).
home=$RIG/state-clock
init_home "$home"
now=$(date +%s)
old_id="$((now - 40 * 86400)).1.1.sender@alpha"
write_letter "$home" reader "$old_id" sender@alpha message '' waited "$((now + 99999))" body
KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >/dev/null 2>&1 || die "state-clock inbox read failed"
[ -f "$home/inbox/reader/cur/$old_id" ] || die "read message not in cur"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>&1 || die "state-clock reconcile failed"
[ -f "$home/inbox/reader/cur/$old_id" ] || die "a message read today was pruned because its Id is old"
touch -d '@'"$((now - 40 * 86400))" "$home/inbox/reader/cur/$old_id" 2>/dev/null || touch -t "$(date -r $((now - 40 * 86400)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((now - 40 * 86400)) +%Y%m%d%H%M.%S)" "$home/inbox/reader/cur/$old_id"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>&1 || die "state-clock reconcile 2 failed"
[ ! -f "$home/inbox/reader/cur/$old_id" ] || die "a message in cur for 40 days was not pruned"
if KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" send other@alpha -s ttl -m x -e 6000000 >/dev/null 2>"$RIG/ttl.err"; then
    die "send accepted a TTL beyond the dedup horizon"
fi
grep -q 5097600 "$RIG/ttl.err" || die "TTL refusal does not name the cap"
printf 'ok P4d — retention uses state-entry time; send TTL is capped below the dedup horizon\n'

# P4e — age-out sweeps run at most once per retention-interval (0.8.1): the relay reconciles
# once a second while fresh, and a full-tree sweep on every pass starved the state lock.
home=$RIG/interval
KHALA_HOME=$home "$KHALA" init alpha >/dev/null 2>&1 || die "interval init failed"
grep -q '^retention-interval' "$home/config" && die "init wrote a retention-interval line (default must be implicit)"
now=$(date +%s)
aged() {
    touch -d "@$2" "$1" 2>/dev/null || touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)" "$1"
}
write_letter "$home" reader "$now.3.1.first@alpha" first@alpha notice info first "$((now - 1))" gone
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-1.err" || die "interval reconcile 1 failed"
[ ! -e "$home/inbox/reader/new/$now.3.1.first@alpha" ] || die "first pass on a fresh node did not sweep"
[ -f "$home/run/retention.stamp" ] || die "sweep left no retention marker"
write_letter "$home" reader "$now.3.2.second@alpha" second@alpha notice info second "$((now - 1))" waits
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-2.err" || die "interval reconcile 2 failed"
[ -f "$home/inbox/reader/new/$now.3.2.second@alpha" ] || die "a pass inside the interval swept anyway"
# Inside the interval the per-pass semantics still run: a garbage stream entry and a
# future-epoch one are quarantined (loudly), and a lower session status generation is collected.
mkdir -p "$home/streams/khala/alpha"
printf 'garbage\n' > "$home/streams/khala/alpha/$now.9.9.reader@alpha"
printf 'Khala: 0.1\nId: %s.9.8.reader@alpha\nFrom: reader@alpha\nStream: khala\nDate: 2000-01-01T00:00:00Z\nType: entry\n\nfuture\n' "$((now + 100000))" \
    > "$home/streams/khala/alpha/$((now + 100000)).9.8.reader@alpha"
low=$(KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" mind -m low 2>/dev/null) || die "low status update failed"
cp "$home/minds/alpha/reader/$low" "$home/tmp/low.fixture" || die "low fixture failed"
high=$(KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" mind -m high 2>/dev/null) || die "high status update failed"
cp "$home/tmp/low.fixture" "$home/minds/alpha/reader/$low" || die "low re-injection failed"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-2b.err" || die "interval reconcile 2b failed"
[ ! -e "$home/streams/khala/alpha/$now.9.9.reader@alpha" ] || die "garbage stream entry survived a pass inside the interval"
[ ! -e "$home/streams/khala/alpha/$((now + 100000)).9.8.reader@alpha" ] || die "future stream entry survived a pass inside the interval"
[ "$(grep -c '격리' "$RIG/interval-2b.err")" -eq 2 ] || die "quarantine inside the interval was not loud twice: $(tr '\n' ' ' < "$RIG/interval-2b.err")"
[ ! -e "$home/minds/alpha/reader/$low" ] || die "lower session status generation survived a pass inside the interval"
[ -f "$home/minds/alpha/reader/$high" ] || die "current session status generation was collected"
[ -f "$home/inbox/reader/new/$now.3.2.second@alpha" ] || die "the semantic pass swept the age-out anyway"
aged "$home/run/retention.stamp" "$((now - 301))"
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-3.err" || die "interval reconcile 3 failed"
[ ! -e "$home/inbox/reader/new/$now.3.2.second@alpha" ] || die "a pass after the interval did not sweep"
aged "$home/run/retention.stamp" "$((now + 100000))"
write_letter "$home" reader "$now.3.3.third@alpha" third@alpha notice info third "$((now - 1))" clock
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-4.err" || die "interval reconcile 4 failed"
[ ! -e "$home/inbox/reader/new/$now.3.3.third@alpha" ] || die "a future marker locked the sweep out"
printf 'retention-interval 0\n' >> "$home/config"
write_letter "$home" reader "$now.3.4.fourth@alpha" fourth@alpha notice info fourth "$((now - 1))" every
KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-5.err" || die "interval reconcile 5 failed"
[ ! -e "$home/inbox/reader/new/$now.3.4.fourth@alpha" ] || die "interval 0 did not sweep on every pass"
sed 's/^retention-interval 0$/retention-interval x/' "$home/config" > "$home/tmp/config.bad" && mv "$home/tmp/config.bad" "$home/config"
write_letter "$home" reader "$now.3.5.fifth@alpha" fifth@alpha notice info fifth "$((now - 1))" broken
if KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/interval-6.err"; then
    die "a non-integer retention-interval was accepted silently"
fi
grep -q 'retention-interval' "$RIG/interval-6.err" || die "bad interval error does not name the key"
[ ! -e "$home/inbox/reader/new/$now.3.5.fifth@alpha" ] || die "a broken interval silently stopped the sweep"
for f in 1 2 3 4 5; do [ ! -s "$RIG/interval-$f.err" ] || die "interval pass $f was not silent: $(tr '\n' ' ' < "$RIG/interval-$f.err")"; done
printf 'ok P4e — age-out sweeps wait for retention-interval; a future marker and interval 0 sweep at once\n'

printf 'RESULT: PASS\n'
