#!/usr/bin/env bash
# D18 core: lane identities and their parents — `khala whoami`, `--parent` /
# KHALA_PARENT, the Claude-bind guard inside codex, the unknown-recipient
# warning, `inbox --as`, the conduit's parent notice end to end, and prompt
# same-node delivery on a node with no dial connection.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO:-$(command -v go)}
RIG=$HOME/.khala-lanes-test-$$
BIN=$RIG/khala-link
PIDS=
. "$ROOT/test/lib/isolate.sh"

cleanup() {
    for cleanup_pid in $PIDS; do
        kill "$cleanup_pid" 2>/dev/null || :
        wait "$cleanup_pid" 2>/dev/null || :
    done
    rm -rf -- "$RIG"
}

fail() {
    printf 'FAIL %s — %s\n' "$1" "$2" >&2
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

wait_for() {
    wait_limit=$1
    shift
    wait_i=0
    until "$@"; do
        [ "$wait_i" -lt "$wait_limit" ] || return 1
        sleep 0.05
        wait_i=$((wait_i + 1))
    done
}

file_mode() {
    lanes_mode=$(stat -c %a "$1" 2>/dev/null) || lanes_mode=
    if [ -n "$lanes_mode" ]; then
        printf '%s\n' "$lanes_mode"
        return 0
    fi
    stat -f %Lp "$1" 2>/dev/null
}

count_files() {
    count=0
    for count_path in "$1"/*; do
        [ -f "$count_path" ] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

# Parent notices about ended@alpha queued for this node and not yet delivered.
queued_notices() {
    grep -l '^Subject: ended@alpha ' "$KHALA_HOME"/spool/for/alpha/*.conduit@alpha 2>/dev/null |
        wc -l | tr -d ' '
}

# A process to stand in for a running lane; killed by pid, never by pattern.
start_stand_in() {
    sleep 600 &
    STAND_IN=$!
    PIDS="$PIDS $STAND_IN"
}

mkdir -p "$RIG" || fail setup "could not create the rig"
trap 'cleanup; isolate_cleanup' EXIT HUP INT TERM
(cd "$ROOT/link" && CGO_ENABLED=0 "$GO" build -o "$BIN" .) || fail setup "Go build failed"
export KHALA_HOME=$RIG/home
"$KHALA" init alpha >/dev/null 2>"$RIG/init.err" || fail setup "init failed: $(cat "$RIG/init.err")"
mkdir -p "$KHALA_HOME/bin" && cp "$BIN" "$KHALA_HOME/bin/khala-link" || fail setup "could not install khala-link"
printf '%s\n' 'retention-interval 0' >> "$KHALA_HOME/config"
RUNTIME=$("$BIN" runtime root) || fail setup "no runtime root"

# W — whoami resolves the identity the way every command does.
mkdir -p "$RIG/declared" "$RIG/bare"
printf '%s\n' declared > "$RIG/declared/.khala-session"
[ "$(KHALA_SESSION=lane "$KHALA" whoami)" = lane@alpha ] || fail W "KHALA_SESSION not used"
[ "$(KHALA_SESSION=lane "$KHALA" whoami --as other)" = other@alpha ] || fail W "--as does not win"
[ "$(cd "$RIG/declared" && "$KHALA" whoami)" = declared@alpha ] || fail W ".khala-session not used"
if (cd "$RIG/bare" && "$KHALA" whoami >"$RIG/w.out" 2>"$RIG/w.err"); then
    fail W "whoami without an identity exited 0"
fi
[ ! -s "$RIG/w.out" ] && [ -s "$RIG/w.err" ] || fail W "no identity: stdout must be empty and stderr say why"
if KHALA_SESSION=conduit "$KHALA" whoami >/dev/null 2>&1; then
    fail W "a reserved name resolved"
fi
[ "$("$KHALA" whoami --help)" = 'usage: khala whoami [--as session]' ] || fail W "whoami --help"
"$KHALA" --help 2>&1 | grep -qF 'khala whoami [--as session]' || fail W "whoami missing from usage"
pass W "whoami prints <identity>@<node> from --as, KHALA_SESSION, .khala-session; refuses without one"

# P — the parent record: validated, written once, outlives release.
start_stand_in
P_PID=$STAND_IN
register_worker() {
    "$KHALA" bind --register ready --harness codex --kind worker --receive-opt-in=false \
        --pid "$1" --session-id "$2" "${@:3}"
}
for p_bad in main main@ @alpha Main@alpha a@b@c conduit@alpha lane@alpha; do
    if KHALA_SESSION=lane register_worker "$P_PID" thread-1 --parent "$p_bad" >/dev/null 2>"$RIG/p.err"; then
        fail P "parent $p_bad was accepted"
    fi
    grep -q 'invalid parent' "$RIG/p.err" || fail P "parent $p_bad: $(cat "$RIG/p.err")"
done
[ ! -e "$KHALA_HOME/parents/lane" ] || fail P "a refused parent was recorded"
P_OUT=$(KHALA_SESSION=lane KHALA_PARENT=main@alpha register_worker "$P_PID" thread-1) ||
    fail P "worker registration with KHALA_PARENT failed"
P_INSTANCE=$(printf '%s\n' "$P_OUT" | sed -n 's/^instance //p')
[ "$(cat "$KHALA_HOME/parents/lane")" = main@alpha ] || fail P "KHALA_PARENT not recorded"
[ "$(file_mode "$KHALA_HOME/parents/lane")" = 600 ] || fail P "record mode is not 0600"
printf '%s\n' "$P_OUT" | grep -qx 'owner no' || fail P "a Codex worker took the lease: $P_OUT"
KHALA_SESSION=plain "$KHALA" bind --parent eddy@beta >/dev/null 2>"$RIG/p.err" ||
    fail P "bind --parent failed: $(cat "$RIG/p.err")"
[ "$(cat "$KHALA_HOME/parents/plain")" = eddy@beta ] || fail P "bind --parent not recorded"
"$BIN" runtime release --identity lane --instance "$P_INSTANCE" || fail P "release failed"
[ "$(cat "$KHALA_HOME/parents/lane")" = main@alpha ] || fail P "release dropped the parent record"
pass P "--parent/KHALA_PARENT recorded at parents/<identity> (0600), bad parents refused, release keeps it"

# G — inside codex, the Claude path of bind/register is refused.
for g_args in "bind" "bind --register ready"; do
    # shellcheck disable=SC2086
    if CODEX_THREAD_ID=019a KHALA_SESSION=main "$KHALA" $g_args >/dev/null 2>"$RIG/g.err"; then
        fail G "khala $g_args accepted a Claude bind inside codex"
    fi
    grep -qF 'this is a codex session; use khala-codex' "$RIG/g.err" || fail G "khala $g_args: $(cat "$RIG/g.err")"
done
CODEX_THREAD_ID=019a KHALA_SESSION=guarded register_worker "$P_PID" 019a >/dev/null 2>"$RIG/g.err" ||
    fail G "the codex path was refused: $(cat "$RIG/g.err")"
pass G "CODEX_THREAD_ID refuses the Claude bind and register paths; the codex path still registers"

# S — send warns once about an address no session has used, and still sends.
s_send() {
    KHALA_SESSION=main "$KHALA" send "$1" -s probe -m body >"$RIG/s.out" 2>"$RIG/s.err" ||
        fail S "send to $1 failed: $(cat "$RIG/s.err")"
    S_ID=$(cat "$RIG/s.out")
    [ -f "$KHALA_HOME/outbox/new/$S_ID" ] || fail S "send to $1 was not queued"
}
s_quiet() {
    s_send "$1"
    [ ! -s "$RIG/s.err" ] || fail S "warning for $1 ($2): $(cat "$RIG/s.err")"
}
s_send nobody@alpha
[ "$(cat "$RIG/s.err")" = 'khala: no session has used nobody@alpha; the letter is stored and will wait' ] ||
    fail S "unknown local address: $(cat "$RIG/s.err")"
s_send ghost@beta
grep -qF 'no session has used ghost@beta' "$RIG/s.err" || fail S "unknown remote address not warned"
KHALA_SESSION=main "$KHALA" send nobody@alpha -m body --request-id probe-1 >/dev/null 2>"$RIG/s.err" ||
    fail S "keyed send failed"
grep -qF 'no session has used nobody@alpha' "$RIG/s.err" || fail S "keyed send not warned"
date +%s > "$KHALA_HOME/presence/peer@beta"
s_quiet peer@beta "heartbeat"
printf 'ears 1\nnode beta\nidentity name=listed principal=session listening=no route=none reason=optin\n' \
    > "$KHALA_HOME/presence/conduit@beta.ear"
s_quiet listed@beta "conduit snapshot"
s_quiet lane@alpha "parent record"
s_quiet guarded@alpha "registration without a lease"
printf '{}\n' > "$RUNTIME/identities/leased.lease"
s_quiet leased@alpha "lease"
s_quiet main@alpha "the sender itself"
s_quiet user@alpha "gateway user"
s_quiet khala-gateway@alpha "gateway reply address"
pass S "unseen addresses warn on stderr and still queue (exit 0); presence, .ear, parent, lease, registration and gateway names do not"

# I — inbox list/read/ack-read --as look into another identity's mailbox.
I_ID=1700000100.1.1.ink@alpha
mkdir -p "$KHALA_HOME/inbox/reader/new"
printf 'Khala: 0.1\nId: %s\nFrom: ink@alpha\nTo: reader@alpha\nDate: 2026-10-21T00:00:00Z\nType: message\nSubject: for reader\nExpires: 4102444800\n\nreader body\n' \
    "$I_ID" > "$KHALA_HOME/inbox/reader/new/$I_ID"
KHALA_SESSION=main "$KHALA" inbox list --as reader | grep -qF "for reader" || fail I "list --as"
I_READ=1700000000.1.2.ink@alpha
mkdir -p "$KHALA_HOME/inbox/reader/cur"
sed "s/^Id: .*/Id: $I_READ/" "$KHALA_HOME/inbox/reader/new/$I_ID" > "$KHALA_HOME/inbox/reader/cur/$I_READ"
KHALA_SESSION=main "$KHALA" inbox list --as reader | cut -f1,5 > "$RIG/i.list"
printf '%s\tunread\n%s\tread\n' "$I_ID" "$I_READ" | cmp -s - "$RIG/i.list" ||
    fail I "list does not tell unread from read: $(cat "$RIG/i.list")"
rm -f "$KHALA_HOME/inbox/reader/cur/$I_READ"
KHALA_SESSION=main "$KHALA" inbox read "$I_ID" --as reader | grep -qx 'reader body' || fail I "read --as"
[ -f "$KHALA_HOME/inbox/reader/new/$I_ID" ] || fail I "read --as moved the letter"
[ ! -e "$KHALA_HOME/presence/reader@alpha" ] || fail I "--as refreshed the other identity's presence"
[ "$(KHALA_SESSION=main "$KHALA" inbox ack-read --as reader "$I_ID")" = "$I_ID" ] || fail I "ack-read --as"
[ -f "$KHALA_HOME/inbox/reader/cur/$I_ID" ] || fail I "ack-read --as did not mark it read"
pass I "inbox list/read/ack-read --as <identity> work on that mailbox without touching its presence; list marks unread and read"

# N — a lane that ended with mail: its parent gets one notice, through the
# real reconcile and drain, and a restarted conduit does not repeat it.
start_stand_in
N_PID=$STAND_IN
KHALA_SESSION=ended KHALA_PARENT=main@alpha register_worker "$N_PID" thread-2 >/dev/null ||
    fail N "lane registration failed"
KHALA_SESSION=main "$KHALA" send ended@alpha -s "reply to your report" -m "done?" >/dev/null 2>&1 ||
    fail N "send to the lane failed"
"$KHALA" reconcile >/dev/null 2>&1 || :
[ "$(count_files "$KHALA_HOME/inbox/ended/new")" = 1 ] || fail N "the letter did not reach the lane"
start_conduit() {
    KHALA_CONDUIT_TEST_SCAN_INTERVAL=50ms KHALA_CONDUIT_TEST_PARENT_GRACE=1s "$BIN" conduit &
    CONDUIT_PID=$!
    PIDS="$PIDS $CONDUIT_PID"
}
start_conduit
sleep 1.5
[ "$(queued_notices)" = 0 ] || fail N "notice while the lane was alive"
kill "$N_PID"
wait "$N_PID" 2>/dev/null
n_noticed() { [ "$(queued_notices)" -ge 1 ]; }
wait_for 100 n_noticed || fail N "no parent notice after the lane ended"
kill "$CONDUIT_PID"
wait "$CONDUIT_PID" 2>/dev/null
"$KHALA" reconcile >/dev/null 2>&1 || :
KHALA_SESSION=main "$KHALA" inbox --drain > "$RIG/n.drain" 2>&1 || fail N "parent drain failed"
grep -qF 'From: conduit@alpha' "$RIG/n.drain" || fail N "drain: $(cat "$RIG/n.drain")"
grep -qF 'Urgency: urgent' "$RIG/n.drain" || fail N "the notice is not urgent"
grep -qF 'ended@alpha has 1 unread letter (oldest ' "$RIG/n.drain" || fail N "drain: $(cat "$RIG/n.drain")"
grep -qF 'khala inbox list --as ended' "$RIG/n.drain" || fail N "no read instructions"
start_conduit
sleep 2
kill "$CONDUIT_PID"
wait "$CONDUIT_PID" 2>/dev/null
[ "$(queued_notices)" = 0 ] || fail N "a restarted conduit repeated the notice"
[ "$(grep -c 'parent notice ended -> main@alpha' "$KHALA_HOME/log/conduit.log")" = 1 ] ||
    fail N "conduit log: $(grep 'parent notice' "$KHALA_HOME/log/conduit.log")"
[ "$(count_files "$KHALA_HOME/inbox/ended/new")" = 1 ] || fail N "the lane's letter was touched"
pass N "after the lane ends its parent gets one urgent notice via reconcile/drain; a restart does not repeat it"

# D — on a node with no dial connection a letter to this node reaches the inbox
# within 5 s: send leaves the trigger the relay polls. The periodic scan is an
# hour here, so nothing else can deliver it once the startup pass is over.
rm -f "$KHALA_HOME/run/reconcile.trigger" "$KHALA_HOME/run/retention.stamp"
KHALA_BRAIN=$KHALA KHALA_LINK_TEST_SCAN_INTERVAL=1h "$BIN" >"$RIG/link.out" 2>&1 &
LINK_PID=$!
PIDS="$PIDS $LINK_PID"
d_idle() { [ -f "$KHALA_HOME/run/retention.stamp" ] && [ ! -e "$KHALA_HOME/run/brain.lock.d" ]; }
d_delivered() { [ -f "$KHALA_HOME/inbox/quick/new/$D_ID" ]; }
wait_for 200 d_idle || fail D "the relay's startup reconcile did not finish: $(cat "$RIG/link.out")"
for d_key in '' quick-1; do
    D_ID=$(KHALA_SESSION=main "$KHALA" send quick@alpha -m now ${d_key:+--request-id "$d_key"} 2>"$RIG/d.err") ||
        fail D "send failed: $(cat "$RIG/d.err")"
    wait_for 100 d_delivered || fail D "letter ${d_key:-without a key} not in the inbox after 5 s"
done
kill "$LINK_PID"
wait "$LINK_PID" 2>/dev/null
pass D "with no dial connection, send and send --request-id to this node reach the inbox within 5 s"

printf '%s\n' 'RESULT: PASS'
