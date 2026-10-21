#!/usr/bin/env bash
# End to end: khala-link gateway with the fake chat adapter (file queues under
# run/gateway-fake) on a temporary single node, driven through the real CLI.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
GO=${GO:-$(command -v go)}
RIG=${KHALA_TEST_ROOT:-${HOME}/.khala-gateway-test-$$}
BIN=$RIG/khala-link
NODE=$RIG/node
FAKE=$NODE/run/gateway-fake
GW_PID=
. "$ROOT/test/lib/isolate.sh"

cleanup() {
    [ -z "$GW_PID" ] || { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }
    rm -rf -- "$RIG"
}

fail() {
    printf 'FAIL %s — %s\n' "$1" "$2" >&2
    [ ! -f "$NODE/log/gateway.log" ] || sed 's/^/  log: /' "$NODE/log/gateway.log" >&2
    [ ! -d "$FAKE/outbound" ] || cat "$FAKE"/outbound/*.json >&2 2>/dev/null
    printf 'RESULT: FAIL\n'
    exit 1
}

pass() { printf 'ok %s — %s\n' "$1" "$2"; }

# wait_for <seconds> <command...>: poll until the command succeeds.
wait_for() {
    wait_limit=$(( $1 * 10 ))
    shift
    wait_i=0
    while [ "$wait_i" -lt "$wait_limit" ]; do
        "$@" && return 0
        sleep 0.1
        wait_i=$((wait_i + 1))
    done
    return 1
}

# outbound_find <python predicate on o>: print the first matching outbound JSON.
outbound_find() {
    python3 - "$FAKE/outbound" "$1" <<'PY'
import json, os, sys
d, pred = sys.argv[1], sys.argv[2]
if not os.path.isdir(d):
    sys.exit(1)
for name in sorted(os.listdir(d)):
    if not name.endswith(".json"):
        continue
    o = json.load(open(os.path.join(d, name)))
    o.setdefault("text", ""); o.setdefault("reply_to", 0); o.setdefault("name", "")
    if eval(pred, {}, {"o": o}):
        print(json.dumps(o)); sys.exit(0)
sys.exit(1)
PY
}

field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], 0))' "$1" "$2"; }

inbound() { # inbound <update> <thread> <message> <text>
    mkdir -p "$FAKE/inbound"
    python3 -c 'import json,sys; json.dump({"update_id":int(sys.argv[1]),"thread_id":int(sys.argv[2]),"message_id":int(sys.argv[3]),"user_id":1,"text":sys.argv[4]}, open(sys.argv[5],"w"))' \
        "$1" "$2" "$3" "$4" "$FAKE/inbound/.tmp" && mv "$FAKE/inbound/.tmp" "$FAKE/inbound/$1.json"
}

count() { find "$1" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

trap 'cleanup; isolate_cleanup' EXIT HUP INT TERM
mkdir -p "$RIG"

(cd "$ROOT/link" && CGO_ENABLED=0 "$GO" build -o "$BIN" .) || fail 0 "go build"
KHALA_HOME=$NODE "$KHALA" init gw >/dev/null || fail 0 "khala init"
export KHALA_HOME=$NODE
pass 0 "built khala-link and initialized node gw"

# 1. Refuses to start without gateway.conf.
"$BIN" gateway --once >"$RIG/g1.out" 2>&1
rc=$?
[ "$rc" -eq 2 ] && grep -q 'gateway.conf' "$RIG/g1.out" || fail 1 "absent conf: rc=$rc $(cat "$RIG/g1.out")"
pass 1 "absent gateway.conf → rc 2"

printf 'adapter fake\ntelegram allow 1\nkhala bin %s\n' "$KHALA" > "$NODE/gateway.conf"
chmod 600 "$NODE/gateway.conf"

# A listener snapshot for this node that lists session alpha as listening.
now=$(date +%s)
cat > "$NODE/presence/conduit@gw.ear" <<EAR
ears 1
node gw
generation $now
written-at $now
interval 60
state running
complete yes
component conduit release=0.9.10 adapter=1 ears=1
mailbox gw
link -
identity name=alpha principal=session listening=yes route=socket phase=ready cc=2.1.260 reason=- pending-ring=0 pending-info=0 pending-operator=0 generation=- first-seen=0 oldest-pending=0 written-rings=0 last-written=0 last-drain=0 last-drain-before=- last-drain-after=- last-drain-status=-
EAR

"$BIN" gateway >"$RIG/gateway.out" 2>&1 &
GW_PID=$!
wait_for 10 grep -qs 'connected as @fake' "$NODE/log/gateway.log" || fail 2 "no startup line"
"$BIN" gateway --once >"$RIG/g2.out" 2>&1 && fail 2 "second gateway started while the first holds run/gateway.pid"
grep -q 'another gateway' "$RIG/g2.out" || fail 2 "second gateway: $(cat "$RIG/g2.out")"
pass 2 "daemon started; a second poller is refused"

# 3. /open in General creates the topic and posts the first status.
inbound 1 0 10 "/open alpha@gw"
wait_for 10 outbound_find 'o["method"]=="createTopic" and o["name"]=="alpha@gw"' >/dev/null || fail 3 "no createTopic"
topic=$(field "$(outbound_find 'o["method"]=="createTopic"')" thread)
wait_for 10 outbound_find "o['method']=='post' and o['thread']==$topic and o['text']=='connected'" >/dev/null || fail 3 "no connected status post"
pass 3 "/open alpha@gw → topic $topic, status connected"

# 4. A message in the topic becomes a khala message from user@gw.
inbound 2 "$topic" 20 "$(printf 'please check GPU 2\nsecond line')"
wait_for 10 sh -c "ls '$NODE/outbox/new' | grep -q ."  || fail 4 "no message in outbox/new"
id=$(ls "$NODE/outbox/new")
grep -qx 'From: user@gw' "$NODE/outbox/new/$id" || fail 4 "From is not user@gw"
grep -qx 'Subject: please check GPU 2' "$NODE/outbox/new/$id" || fail 4 "subject"
grep -qx 'second line' "$NODE/outbox/new/$id" || fail 4 "body"
[ -d "$NODE/requests/send/user/tg-2" ] || fail 4 "request ledger tg-2 missing"
pass 4 "topic message → $id (From: user@gw, request tg-2)"

# 5. Delivery to the local session and its reply.
"$KHALA" reconcile >/dev/null 2>&1 || fail 5 "reconcile"
[ -f "$NODE/inbox/alpha/new/$id" ] || fail 5 "not delivered to inbox/alpha/new"
reply=$(printf 'GPU 2 is fine\n' | KHALA_SESSION=alpha "$KHALA" send user@gw --reply-to "$id" -s "re: GPU") || fail 5 "alpha reply send"
"$KHALA" reconcile >/dev/null 2>&1 || fail 5 "reconcile reply"
[ -f "$NODE/inbox/user/new/$reply" ] || [ -f "$NODE/inbox/user/cur/$reply" ] || fail 5 "reply not in inbox/user"
pass 5 "delivered to alpha; alpha replied $reply"

# 6. The reply is posted to alpha's topic as a reply to message 20, then acknowledged.
wait_for 15 outbound_find "o['method']=='post' and o['thread']==$topic and o['reply_to']==20 and 'GPU 2 is fine' in o['text']" >/dev/null \
    || fail 6 "reply not posted as a threaded reply"
wait_for 10 test -f "$NODE/inbox/user/cur/$reply" || fail 6 "reply not acked (inbox/user/cur)"
[ "$(count "$NODE/inbox/user/new")" -eq 0 ] || fail 6 "inbox/user/new not empty"
pass 6 "reply posted to topic $topic with reply_to 20 and acknowledged"

# 7. Replaying an already confirmed update is a no-op; SIGTERM saves state.
inbound 2 "$topic" 20 "please check GPU 2"
sleep 1
[ "$(count "$NODE/outbox/new")" -eq 0 ] || fail 7 "replayed update produced a new message"
[ "$(count "$NODE/outbox/acked")" -eq 2 ] || fail 7 "outbox/acked should hold exactly the user message and alpha's reply"
kill -TERM "$GW_PID"
wait "$GW_PID"
rc=$?
GW_PID=
[ "$rc" -eq 0 ] || fail 7 "daemon exit rc=$rc"
python3 - "$NODE/gateway.state.json" "$topic" "$id" <<'PY' || fail 7 "state file"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["offset"] == 3, s["offset"]
assert s["topics"]["alpha@gw"] == int(sys.argv[2]), s["topics"]
assert s["threads"][sys.argv[3]]["message_id"] == 20, s["threads"]
assert s["status"]["alpha@gw"]["kind"] == "connected", s["status"]
PY
[ "$(stat -c %a "$NODE/gateway.state.json" 2>/dev/null || stat -f %Lp "$NODE/gateway.state.json")" = 600 ] || fail 7 "state mode"
[ "$(count "$FAKE/inbound")" -eq 0 ] || fail 7 "confirmed inbound files remain"
pass 7 "SIGTERM → rc 0, state saved (offset 3, topic, thread, status)"

printf 'RESULT: PASS\n'
