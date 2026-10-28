#!/usr/bin/env bash
# D18 r3 (D): Claude Code subagents with a khala mailbox — the plugin hooks
# plugin/hooks/subagent.sh (PreToolUse, PostToolUse, SubagentStop, SessionEnd)
# and plugin/hooks/tool-boundary.sh (the PostToolUse fast path), driven with the
# hook inputs Claude Code 2.1.312 writes. A stand-in process plays the Claude
# Code process (CLAUDE_PID); meta.json files play its subagent records.
#
#   FAST_SH=/bin/dash bash test/cc-subagents.sh    (fast path under another sh)
#
# The fast path runs as hooks.json runs it: sourced into `sh -c` with
# CLAUDE_PLUGIN_ROOT set.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
HOOKS=$ROOT/plugin/hooks
GO=${GO:-$(command -v go)}
FAST_SH=${FAST_SH:-sh}
RIG=$HOME/.khala-ccsub-test-$$
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
    [ ! -f "${KHALA_HOME-}/log/cc-subagents.log" ] || sed 's/^/  log: /' "$KHALA_HOME/log/cc-subagents.log" >&2
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

file_mode() {
    ccsub_mode=$(stat -c %a "$1" 2>/dev/null) || ccsub_mode=
    if [ -n "$ccsub_mode" ]; then
        printf '%s\n' "$ccsub_mode"
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

# A process standing in for a running Claude Code; killed by pid only.
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
mkdir -p "$RIG/shim" && ln -s "$KHALA" "$RIG/shim/khala" || fail setup "could not create the PATH shim"
export PATH=$RIG/shim:/usr/bin:/bin:/usr/sbin:/sbin
LINK=$KHALA_HOME/bin/khala-link

start_stand_in
export CLAUDE_PID=$STAND_IN
export KHALA_SESSION=main
SID=11111111-2222-4333-8444-555555555555
PROJ=$RIG/proj
TRANSCRIPTS=$RIG/claude/projects/proj
TRANSCRIPT=$TRANSCRIPTS/$SID.jsonl
mkdir -p "$PROJ" "$TRANSCRIPTS/$SID/subagents" && : > "$TRANSCRIPT" || fail setup "could not create the transcript tree"
STATE=$KHALA_HOME/run/cc-subagents/$CLAUDE_PID
OUT=$RIG/out

# hook <out-name> <command...> — run a hook with stdin from $RIG/in; it must
# exit 0 and write nothing to stderr.
hook() {
    hook_name=$1
    shift
    "$@" < "$RIG/in" > "$OUT.$hook_name" 2> "$OUT.$hook_name.err"
    hook_status=$?
    [ "$hook_status" -eq 0 ] || fail "$hook_name" "hook exited $hook_status"
    [ ! -s "$OUT.$hook_name.err" ] || fail "$hook_name" "hook wrote to stderr: $(cat "$OUT.$hook_name.err")"
}

# The PostToolUse command exactly as hooks.json declares it.
fast_path() {
    CLAUDE_PLUGIN_ROOT=$ROOT/plugin "$FAST_SH" -c '. "${CLAUDE_PLUGIN_ROOT}/hooks/tool-boundary.sh"'
}

# pre_tool_use <name> <tool_use_id> <prompt as a JSON string body> [tool]
pre_tool_use() {
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","prompt_id":"p1","permission_mode":"default","effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"description":"work","prompt":"%s","subagent_type":"general-purpose","model":"haiku"},"tool_use_id":"%s"}\n' \
        "${SESSION-$SID}" "$TRANSCRIPT" "$PROJ" "${4-Agent}" "$3" "$2" > "$RIG/in"
    hook "$1" bash "$HOOKS/subagent.sh" PreToolUse
}

# post_tool_use <name> [agent_id] — a Bash tool call of the main (no agent id)
# or of a subagent; tool_input/tool_response carry decoy agent_id keys.
post_tool_use() {
    post_agent=
    [ -z "${2-}" ] || post_agent="\"agent_id\":\"$2\",\"agent_type\":\"general-purpose\","
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","prompt_id":"p1","permission_mode":"default",%s"effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo \\"agent_id\\":\\"decoy\\""},"tool_response":{"stdout":"x","agent_id":"decoy2"},"tool_use_id":"toolu_post","duration_ms":5}\n' \
        "${SESSION-$SID}" "$TRANSCRIPT" "$PROJ" "$post_agent" > "$RIG/in"
    hook "$1" fast_path
}

subagent_stop() {
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","prompt_id":"p1","permission_mode":"default","agent_id":"%s","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"%s","last_assistant_message":"DONE","background_tasks":[{"id":"%s","type":"subagent","status":"running","agent_type":"general-purpose"}]}\n' \
        "${SESSION-$SID}" "$TRANSCRIPT" "$PROJ" "$2" "$TRANSCRIPTS/$SID/subagents/agent-$2.jsonl" "$2" > "$RIG/in"
    hook "$1" bash "$HOOKS/subagent.sh" SubagentStop
}

session_end() {
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","prompt_id":"p2","hook_event_name":"SessionEnd","reason":"other"}\n' \
        "$2" "$TRANSCRIPT" "$PROJ" > "$RIG/in"
    hook "$1" bash "$HOOKS/subagent.sh" SessionEnd
}

write_meta() {
    mkdir -p "$TRANSCRIPTS/${SESSION-$SID}/subagents" || fail setup "could not create a subagents dir"
    printf '{"agentType":"general-purpose","isBuiltIn":true,"description":"work","toolUseId":"%s","spawnDepth":1,"requestShape":"foreground","requestNonInteractive":true,"model":"haiku"}' \
        "$2" > "$TRANSCRIPTS/${SESSION-$SID}/subagents/agent-$1.meta.json"
}

# The additionalContext / reason of a hook's JSON output (empty without output).
context_of() {
    [ -s "$OUT.$1" ] || return 0
    python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(d.get("reason") or d["hookSpecificOutput"]["additionalContext"])' "$OUT.$1" ||
        fail "$1" "output is not the expected JSON: $(cat "$OUT.$1")"
}

expect_silent() {
    [ ! -s "$OUT.$1" ] || fail "$1" "expected no output, got: $(cat "$OUT.$1")"
}

expect_context() {
    context=$(context_of "$1")
    case $context in
        *"$2"*) ;;
        *) fail "$1" "context lacks '$2': $context" ;;
    esac
}

send_to() {
    KHALA_SESSION=sender "$KHALA" send "$1@alpha" -s "${3-note}" -m "$2" >/dev/null 2>"$RIG/send.err" ||
        fail setup "send failed: $(cat "$RIG/send.err")"
    "$KHALA" reconcile >/dev/null 2>>"$RIG/send.err" || fail setup "reconcile failed: $(cat "$RIG/send.err")"
}

holders() {
    "$LINK" runtime holders --identity "$1"
}

# --- 1: declarations ---------------------------------------------------------

pre_tool_use d0 toolu_none 'Do the work.\nThen report.'
expect_silent d0
[ ! -e "$KHALA_HOME/run/cc-subagents" ] || fail d0 "a prompt without a declaration created state"
pre_tool_use d1 toolu_cmd 'Send with:\nKHALA_SESSION=worker-a khala send main@alpha -m hi\nand KHALA_SESSION=worker-a inline.'
expect_silent d1
pre_tool_use d2 toolu_esc 'a literal \\nKHALA_SESSION=worker-a stays text'
expect_silent d2
pre_tool_use d3 toolu_tool 'KHALA_SESSION=worker-a' Bash
expect_silent d3
[ ! -e "$KHALA_HOME/run/cc-subagents" ] || fail d3 "non-declarations created state"
pass 1a "no standalone KHALA_SESSION line (none, command prefix, escaped \\n, other tool): silent, no state"

pre_tool_use d4 toolu_two 'KHALA_SESSION=worker-a\nwork\nKHALA_SESSION=worker-b'
expect_context d4 'declares several khala names (worker-a worker-b)'
pre_tool_use d5 toolu_bad 'KHALA_SESSION=Worker_A\nwork'
expect_context d5 'KHALA_SESSION=Worker_A in this Agent prompt is not a usable khala name'
pre_tool_use d6 toolu_res 'KHALA_SESSION=conduit'
expect_context d6 'not a usable khala name'
pre_tool_use d7 toolu_own 'KHALA_SESSION=main'
expect_context d7 "main@alpha is the launching session's own address"
[ "$(count_files "$STATE")" = 0 ] || fail 1b "a refused declaration was recorded"
pass 1b "several names, invalid, reserved and own name are refused and told to the launching session"

pre_tool_use d8 toolu_A 'Task.\r\n  KHALA_SESSION=worker-a  \nmore\nKHALA_SESSION=worker-a\n'
expect_context d8 'the subagent receives as worker-a@alpha from its first tool call; letters that reach it after it ends are announced to main@alpha.'
[ -f "$STATE/p.toolu_A" ] || fail 1c "declaration not recorded"
[ "$(file_mode "$KHALA_HOME/run/cc-subagents")$(file_mode "$STATE")$(file_mode "$STATE/p.toolu_A")" = 700700600 ] ||
    fail 1c "modes: $(file_mode "$KHALA_HOME/run/cc-subagents") $(file_mode "$STATE") $(file_mode "$STATE/p.toolu_A")"
pass 1c "one name (blank-padded, CRLF, repeated) is recorded under the Agent call's tool_use_id (0700/0600)"

# --- 2: fast path ------------------------------------------------------------

post_tool_use f1
expect_silent f1
post_tool_use f2 aundeclared1
expect_silent f2
[ -e "$STATE/p.toolu_A" ] && [ ! -e "$STATE/n.aundeclared1" ] || fail f2 "a subagent without meta.json was settled"
pass 2a "with a declaration waiting: the main's tool call (decoy agent_id in tool_input/response) and a subagent without meta.json stay silent"

write_meta aundeclared1 toolu_other
post_tool_use f3 aundeclared1
expect_silent f3
[ -e "$STATE/n.aundeclared1" ] || fail f3 "an undeclared subagent was not marked"
pass 2b "an undeclared subagent is looked up once (n.<agent>) and stays silent"

(unset CLAUDE_PID; fast_path < /dev/null > "$OUT.f4" 2>&1) || fail f4 "exit status"
expect_silent f4
(CLAUDE_PID=999999999 fast_path < /dev/null > "$OUT.f5" 2>&1) || fail f5 "exit status"
expect_silent f5
pass 2c "no CLAUDE_PID, or a process without state: exit 0, no output, input not needed"

# --- 3: binding --------------------------------------------------------------

write_meta abound1 toolu_A
post_tool_use b1 abound1
expect_context b1 'Khala: you have your own khala address, worker-a@alpha (the KHALA_SESSION=worker-a line of your prompt).'
expect_context b1 'khala send <session@node> --as worker-a'
expect_context b1 'Without it, khala sends as your launching session, main@alpha.'
[ -f "$STATE/b.abound1.worker-a" ] && [ ! -e "$STATE/p.toolu_A" ] || fail b1 "binding not recorded or declaration kept"
[ "$(file_mode "$STATE/b.abound1.worker-a")" = 600 ] || fail b1 "binding mode $(file_mode "$STATE/b.abound1.worker-a")"
holders worker-a > "$RIG/holders" || fail b1 "holders failed"
grep -q " claude worker $CLAUDE_PID\$" "$RIG/holders" || fail b1 "registration: $(cat "$RIG/holders")"
[ "$(cat "$KHALA_HOME/parents/worker-a")" = main@alpha ] || fail b1 "parent record: $(cat "$KHALA_HOME/parents/worker-a" 2>&1)"
reg=$(grep -l '"identity":"worker-a"' "$KHALA_RUNTIME_DIR"/sessions/*.json)
grep -q '"socketPath"' "$reg" && fail b1 "the subagent registration has a socket: $(cat "$reg")"
grep -q '"claudeSessionId":"agent-abound1"' "$reg" || fail b1 "session id: $(cat "$reg")"
post_tool_use b2 abound1
expect_silent b2
pass 3a "first tool call binds via meta.json: told its address, socketless claude worker (pid = CLAUDE_PID), parent main@alpha; then silent"

# --- 4: delivery -------------------------------------------------------------

send_to worker-a 'the secret word is quartz'
post_tool_use m1
expect_silent m1
post_tool_use m2 aundeclared1
expect_silent m2
[ "$(count_files "$KHALA_HOME/inbox/worker-a/new")" = 1 ] || fail m2 "mail moved for another caller"
post_tool_use m3 abound1
expect_context m3 'Khala mail for worker-a@alpha, your khala address, delivered by the khala plugin; the items below are now marked read.'
expect_context m3 'the secret word is quartz'
[ "$(count_files "$KHALA_HOME/inbox/worker-a/new")" = 0 ] || fail m3 "delivered mail still unread"
post_tool_use m4 abound1
expect_silent m4
pass 4a "mail reaches only the bound subagent's next tool call (not the main, not another subagent), marked read once"

i=0
while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    send_to worker-a "page letter $i"
done
post_tool_use m5 abound1
context=$(context_of m5)
[ "$(printf '%s\n' "$context" | grep -c '^--- letter ')" = 10 ] || fail m5 "page size: $context"
expect_context m5 'Unread mail remains; read it with: KHALA_SESSION=worker-a khala inbox --drain'
[ "${#context}" -lt 10000 ] || fail m5 "context is ${#context} characters"
post_tool_use m6 abound1
[ "$(context_of m6 | grep -c '^--- letter ')" = 2 ] || fail m6 "rest: $(context_of m6)"
pass 4b "a page holds 10 letters (under 10,000 characters) and says more remains; the next tool call takes the rest"

big=$(head -c 6000 /dev/zero | tr '\0' 'x')
send_to worker-a "$big" oversized
post_tool_use m7 abound1
expect_context m7 '1건 더 (sender@alpha)'
[ -f "$STATE/h.abound1" ] || fail m7 "held mail not recorded"
sleep 1.1
post_tool_use m8 abound1
expect_silent m8
send_to worker-a 'small after big'
post_tool_use m9 abound1
expect_context m9 'small after big'
pass 4c "an oversized letter is announced once, then held (silent) until the inbox changes"

# --- 5: names held by live sessions -------------------------------------------

start_stand_in
holder_pid=$STAND_IN
KHALA_SESSION=taken "$KHALA" bind --register ready --session-id taken-session --pid "$holder_pid" \
    --socket '' --kind interactive >/dev/null 2>"$RIG/bind.err" || fail 5a "holder registration: $(cat "$RIG/bind.err")"
pre_tool_use h1 toolu_T 'KHALA_SESSION=taken'
expect_context h1 'taken@alpha is held by a live claude interactive session'
[ ! -e "$STATE/p.toolu_T" ] || fail h1 "a held name was declared"
pass 5a "a name a live session holds is refused at the Agent call"

pre_tool_use h2 toolu_L 'KHALA_SESSION=late'
[ -f "$STATE/p.toolu_L" ] || fail h2 "free name not declared"
KHALA_SESSION=late "$KHALA" bind --register ready --session-id late-session --pid "$holder_pid" \
    --socket '' --kind interactive >/dev/null 2>"$RIG/bind.err" || fail 5b "late holder: $(cat "$RIG/bind.err")"
write_meta alate1 toolu_L
post_tool_use h3 alate1
expect_context h3 'Khala: your prompt declares KHALA_SESSION=late, but no khala mailbox was bound for you: late@alpha is held by a live claude interactive session'
[ ! -e "$STATE/b.alate1.late" ] && [ -e "$STATE/n.alate1" ] || fail h3 "a held name was bound"
post_tool_use h4 alate1
expect_silent h4
pass 5b "a name taken between the Agent call and the first tool call is refused and told to the subagent, once"

# --- 6: SubagentStop -----------------------------------------------------------

subagent_stop s0 aundeclared1
expect_silent s0
[ ! -e "$STATE/n.aundeclared1" ] || fail s0 "undeclared marker kept"
for round in 1 2 3; do
    send_to worker-a "stop letter $round"
    subagent_stop "s$round" abound1
    expect_context "s$round" "stop letter $round"
    grep -q '"decision":"block"' "$OUT.s$round" || fail "s$round" "not a block: $(cat "$OUT.s$round")"
    [ "$(cat "$STATE/s.abound1")" = "$round" ] || fail "s$round" "stop count $(cat "$STATE/s.abound1")"
done
send_to worker-a 'stop letter 4'
subagent_stop s4 abound1
expect_silent s4
[ -z "$(holders worker-a)" ] || fail s4 "registration kept: $(holders worker-a)"
[ ! -e "$STATE/b.abound1.worker-a" ] && [ ! -e "$STATE/s.abound1" ] && [ ! -e "$STATE/h.abound1" ] ||
    fail s4 "binding state kept: $(ls "$STATE")"
post_tool_use s5 abound1
expect_silent s5
grep -lq '^stop letter 4$' "$KHALA_HOME/inbox/worker-a/new"/* || fail s5 "the late letter was consumed"
pass 6a "SubagentStop continues with unread mail 3 times, then releases: later mail stays for the parent notice"

pre_tool_use s6 toolu_Q 'KHALA_SESSION=quiet-one'
write_meta aquiet1 toolu_Q
post_tool_use s7 aquiet1
expect_context s7 'quiet-one@alpha'
subagent_stop s8 aquiet1
expect_silent s8
[ -z "$(holders quiet-one)" ] && [ ! -e "$STATE/b.aquiet1.quiet-one" ] || fail s8 "not released"
pre_tool_use s9 toolu_Z 'KHALA_SESSION=no-tools'
write_meta anotools1 toolu_Z
send_to no-tools 'waiting before the first tool call'
subagent_stop s10 anotools1
expect_context s10 'you have your own khala address, no-tools@alpha'
expect_context s10 'waiting before the first tool call'
subagent_stop s11 anotools1
expect_silent s11
[ -z "$(holders no-tools)" ] || fail s11 "not released"
pass 6b "without mail SubagentStop just releases; a declared subagent with no tool call is bound at its stop"

# --- 7: SessionEnd -------------------------------------------------------------

pre_tool_use e1 toolu_E1 'KHALA_SESSION=end-one'
write_meta aend1 toolu_E1
post_tool_use e2 aend1
SESSION=99999999-2222-4333-8444-555555555555 pre_tool_use e3 toolu_E2 'KHALA_SESSION=end-two'
SESSION=99999999-2222-4333-8444-555555555555 write_meta aend2 toolu_E2
SESSION=99999999-2222-4333-8444-555555555555 post_tool_use e4 aend2
pre_tool_use e5 toolu_E3 'KHALA_SESSION=end-three'
session_end e6 "$SID"
expect_silent e6
[ -z "$(holders end-one)" ] && [ ! -e "$STATE/b.aend1.end-one" ] && [ ! -e "$STATE/p.toolu_E3" ] ||
    fail e6 "the ending session's state kept: $(ls "$STATE")"
[ -n "$(holders end-two)" ] && [ -e "$STATE/b.aend2.end-two" ] || fail e6 "another session's binding released"
session_end e7 99999999-2222-4333-8444-555555555555
[ -z "$(holders end-two)" ] && [ ! -e "$STATE" ] || fail e7 "state left: $(ls -a "$STATE" 2>&1)"
pass 7a "SessionEnd releases the ending session's subagents and declarations only, and removes an empty state dir"

# --- 8: failure stays out of the session ----------------------------------------

mv "$KHALA_HOME/bin/khala-link" "$RIG/khala-link.away"
pre_tool_use x1 toolu_X 'KHALA_SESSION=no-link'
expect_context x1 'whether another session holds no-link@alpha could not be checked'
mv "$RIG/khala-link.away" "$KHALA_HOME/bin/khala-link"
grep -q 'could not check who holds no-link' "$KHALA_HOME/log/cc-subagents.log" || fail x1 "failure not logged"
pre_tool_use x2 toolu_X2 'KHALA_SESSION=left-behind'
[ -f "$STATE/p.toolu_X2" ] || fail x2 "declaration not recorded"
kill "$CLAUDE_PID" 2>/dev/null
wait "$CLAUDE_PID" 2>/dev/null
start_stand_in
CLAUDE_PID=$STAND_IN pre_tool_use x3 toolu_X3 'KHALA_SESSION=next'
[ ! -e "$STATE" ] || fail x3 "a gone process's state was kept"
[ -f "$KHALA_HOME/run/cc-subagents/$STAND_IN/p.toolu_X3" ] || fail x3 "the live process's declaration is missing"
pass 8a "an internal failure is told plainly and logged (stderr stays empty); a gone process's state is pruned"
