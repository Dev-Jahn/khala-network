#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
STOP=$ROOT/plugin/hooks/stop.sh
END=$ROOT/plugin/hooks/session-end.sh
GO=${GO:-$(command -v go)}
RIG=$ROOT/.plugin-test-$$
SHIM=$RIG/shim
LINK_BIN=$RIG/khala-link
. "$ROOT/test/lib/isolate.sh"

cleanup() {
    for cleanup_status in "$RIG"/*/runtime-root/conduit.status.json; do
        [ -f "$cleanup_status" ] || continue
        cleanup_pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$cleanup_status")
        [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || :
    done
    for cleanup_status in "$RIG"/*/run/link.status; do
        [ -f "$cleanup_status" ] || continue
        cleanup_pid=$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$cleanup_status")
        [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || :
    done
    rm -rf -- "$RIG"
}

dump_layout() {
    if [ -d "$RIG" ]; then
        find "$RIG" -print | sort >&2
    else
        printf '%s\n' "$RIG (missing)" >&2
    fi
}

fail() {
    step=$1
    shift
    printf 'FAIL %s — %s\n' "$step" "$*" >&2
    dump_layout
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

# Permission bits in octal: GNU stat -c, else BSD/macOS stat -f.
file_mode() {
    plugin_mode=$(stat -c %a "$1" 2>/dev/null) || plugin_mode=
    if [ -n "$plugin_mode" ]; then
        printf '%s\n' "$plugin_mode"
        return 0
    fi
    stat -f %Lp "$1" 2>/dev/null
}

init_home() {
    init_target=$1
    KHALA_HOME=$init_target "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" || \
        fail setup "khala init failed: $(tr '\n' ' ' < "$RIG/init.err")"
    mkdir -p "$init_target/bin" || fail setup "could not create fixture bin"
    cp "$LINK_BIN" "$init_target/bin/khala-link" || fail setup "could not install fixture relay binary"
}

make_project() {
    project_path=$1
    session_value=${2-}
    mkdir -p "$project_path" || fail setup "could not create $project_path"
    if [ -n "$session_value" ]; then
        printf '%s\n' "$session_value" > "$project_path/.khala-session" || \
            fail setup "could not write identity"
    fi
}

stage_letter() {
    stage_home=$1
    stage_to=$2
    stage_body=$3
    KHALA_HOME=$stage_home KHALA_SESSION=sender "$KHALA" send "$stage_to@alpha" \
        -m "$stage_body" >/dev/null 2>"$RIG/send.err" || \
        fail setup "send failed: $(tr '\n' ' ' < "$RIG/send.err")"
    KHALA_HOME=$stage_home "$KHALA" reconcile >/dev/null 2>>"$RIG/send.err" || \
        fail setup "reconcile failed: $(tr '\n' ' ' < "$RIG/send.err")"
}

count_files() {
    count_dir=$1
    count=0
    if [ -d "$count_dir" ]; then
        for count_path in "$count_dir"/*; do
            [ -f "$count_path" ] || continue
            count=$((count + 1))
        done
    fi
    printf '%s\n' "$count"
}

run_start_without_env() {
    run_home=$1
    run_project=$2
    run_output=$3
    (
        unset KHALA_SESSION
        # SessionStart reads its hook payload from stdin; Claude Code always
        # closes it. A suite must not inherit the caller's stdin instead —
        # an open one (a terminal, or a background shell's pipe) blocks the
        # hook's `cat` forever. Closed here, at every invocation.
        HOME=$FAKE_HOME KHALA_HOME=$run_home CLAUDE_PROJECT_DIR=$run_project \
            KHALA_RUNTIME_DIR=$run_home/runtime-root KHALA_TEST_BOOT_ID=plugin-test-boot \
            KHALA_CLAUDE_SESSION_ID=$(basename "$run_project")-test KHALA_SESSION_PID=$$ \
            KHALA_SESSION_KIND=interactive \
            PATH=$SHIM:/usr/bin:/bin "$START" < /dev/null
    ) > "$run_output" 2> "$run_output.err"
}

run_stop_without_env() {
    run_home=$1
    run_project=$2
    run_input=$3
    run_output=$4
    (
        unset KHALA_SESSION
        printf '%s\n' "$run_input" | HOME=$FAKE_HOME KHALA_HOME=$run_home \
            CLAUDE_PROJECT_DIR=$run_project PATH=$SHIM:/usr/bin:/bin "$STOP"
    ) > "$run_output" 2> "$run_output.err"
}

mkdir -p "$RIG" "$SHIM" || fail setup "could not create fixture root"
mkdir -p "$HOME/.cache/khala-go-tmp" || fail setup "could not create Go tmp"
(cd "$ROOT/link" && GOTMPDIR=$HOME/.cache/khala-go-tmp CGO_ENABLED=0 "$GO" build -o "$LINK_BIN" .) || \
    fail setup "could not build fixture khala-link"
ln -s "$KHALA" "$SHIM/khala" || fail setup "could not create PATH shim"
# Hooks self-install the bundled CLI into $HOME/.local/bin; every hook run in
# this suite gets an isolated fake HOME, pre-seeded so ensure stays silent.
FAKE_HOME=$RIG/home
mkdir -p "$FAKE_HOME/.local/bin" || fail setup "could not create fake home"
cp "$KHALA" "$FAKE_HOME/.local/bin/khala" || fail setup "could not seed fake CLI"
chmod 755 "$FAKE_HOME/.local/bin/khala"
printf 'khala-plugin\n' > "$FAKE_HOME/.local/bin/.khala.plugin-receipt"
trap 'cleanup; isolate_cleanup' EXIT HUP INT TERM

# Python is a test-rig-only JSON parser; the plugin runtime has no Python dependency.
uv run --no-project python -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$ROOT/plugin/.claude-plugin/plugin.json" || fail 1 "plugin.json is invalid"
uv run --no-project python -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$ROOT/plugin/hooks/hooks.json" || fail 1 "hooks.json is invalid"
uv run --no-project python - "$ROOT/plugin/.mcp.json" "$ROOT/plugin/channel/package.json" <<'PY' || \
    fail 1 "channel MCP/package manifests are invalid"
import json, sys
mcp = json.load(open(sys.argv[1], encoding="utf-8"))
package = json.load(open(sys.argv[2], encoding="utf-8"))
assert set(mcp["mcpServers"]) == {"khala"}
assert mcp["mcpServers"]["khala"]["command"] == "bun"
assert set(package["dependencies"]) == {"@modelcontextprotocol/sdk"}
assert package["scripts"]["start"] == "bun install --no-summary 1>&2 && bun server.ts"
PY
[ -f "$ROOT/plugin/channel/bun.lock" ] || fail 1 "channel bun.lock is missing"
cmp -s "$ROOT/bin/khala" "$ROOT/plugin/bin/khala" || \
    fail 1 "plugin/bin/khala drifted from bin/khala"
# CC auto-loads hooks/hooks.json; a manifest "hooks" key naming it again is a
# duplicate that fails the whole plugin load (observed in the cluster, 2026-08-13).
grep -q '"hooks"' "$ROOT/plugin/.claude-plugin/plugin.json" && \
    fail 1 "plugin.json references hooks (auto-loaded path must not be repeated)"
pass 1 "plugin/channel manifests are valid, no duplicate hooks ref, bundled CLI matches bin/khala"

UNINIT=$RIG/uninitialized
UNINIT_PROJECT=$RIG/uninit-session
make_project "$UNINIT_PROJECT" uninit-session
mkdir -p "$UNINIT"
run_start_without_env "$UNINIT" "$UNINIT_PROJECT" "$RIG/uninit-start.out"
[ "$?" -eq 0 ] || fail 2 "uninitialized SessionStart exited nonzero"
[ "$(wc -l < "$RIG/uninit-start.out" | tr -d ' ')" -eq 1 ] || \
    fail 2 "uninitialized SessionStart did not print exactly one line"
grep -Fqx 'khala: 노드 미초기화 — 이 노드는 칼라 밖입니다 (참여하려면: khala init <노드별칭> 후 ~/.khala/config에 함대 선언)' \
    "$RIG/uninit-start.out" || fail 2 "uninitialized SessionStart line differs"
run_stop_without_env "$UNINIT" "$UNINIT_PROJECT" '{"stop_hook_active":false}' "$RIG/uninit-stop.out"
[ ! -s "$RIG/uninit-stop.out" ] && [ ! -s "$RIG/uninit-stop.out.err" ] || \
    fail 2 "uninitialized Stop was not silent"
pass 2 "uninitialized start is loud once and stop allows silently"

DRAIN_HOME=$RIG/drain-home
DRAIN_PROJECT=$RIG/drain-session
init_home "$DRAIN_HOME"
make_project "$DRAIN_PROJECT" drain-session
stage_letter "$DRAIN_HOME" drain-session first-body
stage_letter "$DRAIN_HOME" drain-session second-body
run_start_without_env "$DRAIN_HOME" "$DRAIN_PROJECT" "$RIG/drain.out" || \
    fail 3 "inbox read SessionStart exited nonzero"
grep -q 'first-body' "$RIG/drain.out" || fail 3 "first body missing"
grep -q 'second-body' "$RIG/drain.out" || fail 3 "second body missing"
[ "$(count_files "$DRAIN_HOME/inbox/drain-session/new")" -eq 0 ] || \
    fail 3 "new inbox is not empty after inbox read"
[ "$(count_files "$DRAIN_HOME/inbox/drain-session/cur")" -eq 2 ] || \
    fail 3 "two messages did not reach cur"
pass 3 "SessionStart reconciles and reads two staged messages"

CAP_HOME=$RIG/cap-home
CAP_PROJECT=$RIG/cap-session
init_home "$CAP_HOME"
make_project "$CAP_PROJECT" cap-session
cap_i=1
while [ "$cap_i" -le 25 ]; do
    stage_letter "$CAP_HOME" cap-session "cap-body-$cap_i"
    cap_i=$((cap_i + 1))
done
run_start_without_env "$CAP_HOME" "$CAP_PROJECT" "$RIG/cap.out" || \
    fail 4 "cap SessionStart exited nonzero"
[ "$(grep -c '^--- .* ---$' "$RIG/cap.out")" -eq 20 ] || fail 4 "inbox read did not stop at 20"
grep -q '^5건 더 (' "$RIG/cap.out" || fail 4 "remaining-letter summary did not reach stdout"
[ "$(count_files "$CAP_HOME/inbox/cap-session/new")" -eq 5 ] || \
    fail 4 "cap did not leave five messages new"
pass 4 "khala's 20-letter cap and remainder summary reach hook output"

PRE_HOME=$RIG/precedence-home
PRE_PROJECT=$RIG/base-session
init_home "$PRE_HOME"
make_project "$PRE_PROJECT" file-session
stage_letter "$PRE_HOME" env-session env-wins
stage_letter "$PRE_HOME" file-session file-next
stage_letter "$PRE_HOME" base-session basename-last
HOME=$FAKE_HOME KHALA_HOME=$PRE_HOME CLAUDE_PROJECT_DIR=$PRE_PROJECT KHALA_SESSION=env-session \
    KHALA_RUNTIME_DIR=$PRE_HOME/runtime-root KHALA_TEST_BOOT_ID=plugin-test-boot \
    KHALA_CLAUDE_SESSION_ID=precedence-env-test KHALA_SESSION_PID=$$ KHALA_SESSION_KIND=interactive \
    PATH=$SHIM:/usr/bin:/bin "$START" < /dev/null \
    > "$RIG/precedence-env.out" 2> "$RIG/precedence-env.err" || \
    fail 5 "environment precedence run failed"
grep -q 'env-wins' "$RIG/precedence-env.out" || fail 5 "environment identity did not win"
grep -q 'file-next' "$RIG/precedence-env.out" && fail 5 "file identity beat environment"
run_start_without_env "$PRE_HOME" "$PRE_PROJECT" "$RIG/precedence-file.out" || \
    fail 5 "file precedence run failed"
grep -q 'file-next' "$RIG/precedence-file.out" || fail 5 "file identity did not beat basename"
printf '%s\n' 'UpperCase' > "$PRE_PROJECT/.khala-session"
run_start_without_env "$PRE_HOME" "$PRE_PROJECT" "$RIG/precedence-fallback.out" || \
    fail 5 "malformed-file refusal run failed"
grep -q '.khala-session이 한 줄의 유효한 세션 이름이 아닙니다' "$RIG/precedence-fallback.out" || \
    fail 5 "malformed identity warning missing"
grep -q '세션 신원이 없습니다' "$RIG/precedence-fallback.out" || \
    fail 5 "malformed file did not refuse inference"
[ "$(count_files "$PRE_HOME/inbox/base-session/new")" -eq 1 ] || \
    fail 5 "identity refusal consumed basename mail"
UPPER_PROJECT=$RIG/UpperProject
make_project "$UPPER_PROJECT"
run_start_without_env "$PRE_HOME" "$UPPER_PROJECT" "$RIG/uppercase-basename.out" || \
    fail 5 "uppercase basename path exited nonzero"
grep -q '세션 신원이 없습니다' "$RIG/uppercase-basename.out" || \
    fail 5 "missing identity instruction missing"
pass 5 "identity resolution is env then file and never infers a basename"

ARM_HOME=$RIG/arm-home
ARM_PROJECT=$RIG/arm-session
init_home "$ARM_HOME"
make_project "$ARM_PROJECT" arm-session
run_start_without_env "$ARM_HOME" "$ARM_PROJECT" "$RIG/ready.out" || fail 6 "ready run failed"
grep -q 'registration ready, lease yes' "$RIG/ready.out" || fail 6 "ready/lease status missing"
grep -R -q '"phase":"ready"' "$ARM_HOME/runtime-root/sessions" || \
    fail 6 "registration did not reach ready"
grep -R -q 'run_in_background\|watch --session\|재무장' "$RIG/ready.out" && \
    fail 6 "SessionStart retained arm/re-arm guidance"
pass 6 "SessionStart reaches ready lease ownership and emits no arm guidance"

LINK_HOME=$RIG/link-home
LINK_PROJECT=$RIG/link-session
init_home "$LINK_HOME"
make_project "$LINK_PROJECT" link-session
run_start_without_env "$LINK_HOME" "$LINK_PROJECT" "$RIG/node-first.out" || fail 7 "first node ensure failed"
grep -q 'node ensure started conduit,link' "$RIG/node-first.out" || fail 7 "notifier/relay start line missing"
grep -q 'crossSessionInbound.*accept' "$RIG/node-first.out.err" || fail 7 "accept setting instruction missing"
[ ! -e "$FAKE_HOME/.claude/settings.json" ] || fail 7 "hook edited user settings"
node_wait=0
while ! KHALA_RUNTIME_DIR=$LINK_HOME/runtime-root KHALA_TEST_BOOT_ID=plugin-test-boot \
    KHALA_HOME=$LINK_HOME "$LINK_HOME/bin/khala-link" runtime daemon-status >/dev/null 2>&1 && \
    [ "$node_wait" -lt 40 ]; do
    sleep 0.05
    node_wait=$((node_wait + 1))
done
[ "$node_wait" -lt 40 ] || fail 7 "notifier did not outlive SessionStart"
node_wait=0
while [ ! -f "$LINK_HOME/run/link.status" ] && [ "$node_wait" -lt 40 ]; do
    sleep 0.05
    node_wait=$((node_wait + 1))
done
[ "$node_wait" -lt 40 ] || fail 7 "relay did not outlive SessionStart"
node_link_pid=$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$LINK_HOME/run/link.status")
kill -0 "$node_link_pid" 2>/dev/null || fail 7 "relay status pid is not live"
node_conduit_pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$LINK_HOME/runtime-root/conduit.status.json")
node_own_group=$(ps -o pgid= -p "$$" | tr -d ' ')
for node_pid in "$node_conduit_pid" "$node_link_pid"; do
    node_group=$(ps -o pgid= -p "$node_pid" | tr -d ' ')
    [ -n "$node_group" ] && [ "$node_group" != "$node_own_group" ] || \
        fail 7 "daemon $node_pid was not detached into its own session"
done
run_start_without_env "$LINK_HOME" "$LINK_PROJECT" "$RIG/node-second.out" || fail 7 "second node ensure failed"
grep -q 'node ensure started' "$RIG/node-second.out" && fail 7 "idempotent ensure started a duplicate"
pass 7 "node ensure starts detached notifier/relay processes in their own sessions and is idempotent"

# The service-manager choice under `auto`. Real systemctl/launchctl calls would
# act on this host's own user services, so every call here lands on a
# recording shim that shadows systemctl, launchctl, setsid and uname on PATH.
MANAGER_SHIM=$RIG/manager-shim
mkdir -p "$MANAGER_SHIM" || fail 7b "could not create manager shims"
for manager_tool in systemctl launchctl setsid uname; do
    cat > "$MANAGER_SHIM/$manager_tool" <<'EOF'
#!/bin/sh
manager_tool=$(basename "$0")
printf '%s %s\n' "$manager_tool" "$*" >> "$KHALA_TEST_MANAGER_LOG"
case "$manager_tool ${1-}" in
    'systemctl --user') [ "${2-}" != show-environment ] || [ "$KHALA_TEST_USER_BUS" = 1 ] ;;
    'launchctl bootstrap') exit "$KHALA_TEST_BOOTSTRAP_STATUS" ;;
    'uname -s') printf '%s\n' "$KHALA_TEST_UNAME" ;;
esac
EOF
    chmod 755 "$MANAGER_SHIM/$manager_tool" || fail 7b "could not create the $manager_tool shim"
done
SELECT_HOME=$RIG/select-home
init_home "$SELECT_HOME"
# select_manager CASE KHALA_SERVICE_MANAGER USER_BUS UNAME BOOTSTRAP_STATUS: one
# `node ensure` in its own HOME; the shim calls land in $RIG/select-CASE.log.
select_manager() {
    mkdir -p "$RIG/select-$1-home" || fail 7b "could not create the $1 HOME"
    : > "$RIG/select-$1.log"
    HOME=$RIG/select-$1-home KHALA_HOME=$SELECT_HOME KHALA_RUNTIME_DIR=$SELECT_HOME/runtime-root \
        KHALA_TEST_BOOT_ID=plugin-test-boot KHALA_SERVICE_MANAGER=$2 \
        KHALA_TEST_MANAGER_LOG=$RIG/select-$1.log KHALA_TEST_USER_BUS=$3 KHALA_TEST_UNAME=$4 \
        KHALA_TEST_BOOTSTRAP_STATUS=$5 PATH=$MANAGER_SHIM:/usr/bin:/bin \
        "$KHALA" node ensure > "$RIG/select-$1.out" 2> "$RIG/select-$1.err"
}
# Detached starts reach the setsid shim in the background, after ensure returns.
wait_select_log() {
    select_wait=0
    while [ "$(wc -l < "$RIG/select-$1.log" | tr -d ' ')" -lt "$2" ] && [ "$select_wait" -lt 40 ]; do
        sleep 0.05
        select_wait=$((select_wait + 1))
    done
}
select_uid=$(id -u)
select_agents=$RIG/select-launchd-home/Library/LaunchAgents

select_manager systemd auto 1 Linux 0 || fail 7b "systemd ensure failed: $(cat "$RIG/select-systemd.err")"
printf '%s\n' 'systemctl --user show-environment' 'systemctl --user daemon-reload' \
    'systemctl --user enable --now khala-conduit.service' \
    'systemctl --user enable --now khala-link.service' > "$RIG/select-systemd.expected"
cmp -s "$RIG/select-systemd.expected" "$RIG/select-systemd.log" || \
    fail 7b "a live user bus did not select systemd: $(cat "$RIG/select-systemd.log")"
[ -f "$RIG/select-systemd-home/.config/systemd/user/khala-conduit.service" ] && \
    [ -f "$RIG/select-systemd-home/.config/systemd/user/khala-link.service" ] || \
    fail 7b "systemd units were not written"
grep -q 'node ensure started conduit,link' "$RIG/select-systemd.out" || fail 7b "systemd start line missing"

select_manager launchd auto 0 Darwin 0 || fail 7b "launchd ensure failed: $(cat "$RIG/select-launchd.err")"
printf '%s\n' 'systemctl --user show-environment' 'uname -s' \
    "launchctl bootstrap gui/$select_uid $select_agents/dev.khala.conduit.plist" \
    "launchctl bootstrap gui/$select_uid $select_agents/dev.khala.link.plist" > "$RIG/select-launchd.expected"
cmp -s "$RIG/select-launchd.expected" "$RIG/select-launchd.log" || \
    fail 7b "Darwin without a user bus did not select launchd: $(cat "$RIG/select-launchd.log")"
[ -f "$select_agents/dev.khala.conduit.plist" ] && [ -f "$select_agents/dev.khala.link.plist" ] || \
    fail 7b "LaunchAgents were not written"

# A label that is already loaded refuses bootstrap; ensure restarts it instead.
select_agents=$RIG/select-loaded-home/Library/LaunchAgents
select_manager loaded auto 0 Darwin 5 || fail 7b "loaded-label ensure failed: $(cat "$RIG/select-loaded.err")"
printf '%s\n' 'systemctl --user show-environment' 'uname -s' \
    "launchctl bootstrap gui/$select_uid $select_agents/dev.khala.conduit.plist" \
    "launchctl kickstart -k gui/$select_uid/dev.khala.conduit" \
    "launchctl bootstrap gui/$select_uid $select_agents/dev.khala.link.plist" \
    "launchctl kickstart -k gui/$select_uid/dev.khala.link" > "$RIG/select-loaded.expected"
cmp -s "$RIG/select-loaded.expected" "$RIG/select-loaded.log" || \
    fail 7b "a loaded label was not kickstarted: $(cat "$RIG/select-loaded.log")"

select_manager detached auto 0 Linux 0 || fail 7b "detached ensure failed: $(cat "$RIG/select-detached.err")"
wait_select_log detached 4
{
    printf '%s\n' 'systemctl --user show-environment' 'uname -s'
    printf 'setsid sh -c KHALA_HOME=$1; export KHALA_HOME; "$2" %s </dev/null >>"$3" 2>&1 & sh %s %s %s\n' \
        conduit "$SELECT_HOME" "$SELECT_HOME/bin/khala-link" "$SELECT_HOME/log/conduit.log" \
        link "$SELECT_HOME" "$KHALA" "$SELECT_HOME/log/link.log"
} | sort > "$RIG/select-detached.expected"
sort "$RIG/select-detached.log" | cmp -s "$RIG/select-detached.expected" - || \
    fail 7b "no user bus and no launchd did not detach both daemons: $(cat "$RIG/select-detached.log")"

# An explicit choice is taken as given: no probe, even where both would answer.
select_manager explicit detached 1 Darwin 0 || fail 7b "explicit ensure failed: $(cat "$RIG/select-explicit.err")"
wait_select_log explicit 2
[ "$(grep -c '^setsid sh -c ' "$RIG/select-explicit.log")" -eq 2 ] && \
    ! grep -qv '^setsid ' "$RIG/select-explicit.log" || \
    fail 7b "explicit detached still probed or used a manager: $(cat "$RIG/select-explicit.log")"

select_manager unknown launchctl 1 Darwin 0 && fail 7b "an unknown KHALA_SERVICE_MANAGER was accepted"
grep -q 'KHALA_SERVICE_MANAGER' "$RIG/select-unknown.err" || fail 7b "unknown-manager refusal was unclear"
[ ! -s "$RIG/select-unknown.log" ] || fail 7b "an unknown manager still ran: $(cat "$RIG/select-unknown.log")"
pass 7b "auto picks systemd, else launchd (kickstarting a loaded label), else detached; explicit skips the probe; unknown is refused"

STOP_HOME=$RIG/stop-home
STOP_PROJECT=$RIG/stop-session
NO_ID_PROJECT=$RIG/no-identity
init_home "$STOP_HOME"
make_project "$STOP_PROJECT" stop-session
make_project "$NO_ID_PROJECT"
HOME=$FAKE_HOME KHALA_HOME=$STOP_HOME CLAUDE_PROJECT_DIR=$STOP_PROJECT KHALA_SESSION=stop-session \
    PATH=$SHIM:/usr/bin:/bin "$STOP" <<<'{"stop_hook_active":true}' \
    > "$RIG/stop-active.out" 2> "$RIG/stop-active.err" || fail 8 "active Stop exited nonzero"
[ ! -s "$RIG/stop-active.out" ] && [ ! -s "$RIG/stop-active.err" ] || \
    fail 8 "recursive Stop was not silent"
[ ! -e "$STOP_HOME/run/turns/stop-session" ] || fail 8 "recursive Stop wrote a turn marker"
run_stop_without_env "$STOP_HOME" "$NO_ID_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-no-id.out" || \
    fail 8 "no-identity Stop exited nonzero"
[ ! -s "$RIG/stop-no-id.out" ] && [ ! -s "$RIG/stop-no-id.out.err" ] || \
    fail 8 "basename-only Stop was not silent"
[ ! -d "$STOP_HOME/run/turns" ] || \
    [ -z "$(find "$STOP_HOME/run/turns" -type f -print -quit)" ] || fail 8 "no-identity Stop wrote a turn marker"
mkdir -p "$STOP_HOME/run/watch.stop-session.lock.d"
stop_now=$(date +%s) || fail 8 "could not read Stop epoch"
printf '%s\npid 5252 watch\n30\n' "$stop_now" > "$STOP_HOME/run/watch.stop-session.lock.d/owner"
stop_started=$(date +%s%N) || fail 8 "could not read Stop start time"
run_stop_without_env "$STOP_HOME" "$STOP_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-fresh.out" || \
    fail 8 "fresh-lock Stop exited nonzero"
stop_finished=$(date +%s%N) || fail 8 "could not read Stop finish time"
[ ! -s "$RIG/stop-fresh.out" ] && [ ! -s "$RIG/stop-fresh.out.err" ] || \
    fail 8 "fresh-lock Stop was not silent"
stop_elapsed_ms=$(((stop_finished - stop_started) / 1000000))
[ "$stop_elapsed_ms" -lt 1000 ] || fail 8 "Stop took ${stop_elapsed_ms}ms, want <1000ms"
STOP_STAMP=$STOP_HOME/run/turns/stop-session
[ -f "$STOP_STAMP" ] && [ ! -L "$STOP_STAMP" ] || fail 8 "valid Stop did not write a regular turn marker"
stop_first=$(sed -n 's/^turn 1 \([0-9][0-9]*\)$/\1/p' "$STOP_STAMP")
[ -n "$stop_first" ] && [ "$(wc -l < "$STOP_STAMP" | tr -d ' ')" -eq 1 ] || \
    fail 8 "turn marker grammar differs: $(tr '\n' ' ' < "$STOP_STAMP")"
[ "$(file_mode "$STOP_STAMP")" = 600 ] || fail 8 "turn marker mode is not 0600"
[ "$(file_mode "$STOP_HOME/run")" = 700 ] || fail 8 "run mode is not 0700"
[ "$(file_mode "$STOP_HOME/run/turns")" = 700 ] || fail 8 "turns mode is not 0700"
while [ "$(date +%s)" -le "$stop_first" ]; do
    sleep 0.05
done
run_stop_without_env "$STOP_HOME" "$STOP_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-second.out" || \
    fail 8 "second Stop exited nonzero"
[ ! -s "$RIG/stop-second.out" ] && [ ! -s "$RIG/stop-second.out.err" ] || \
    fail 8 "second Stop was not silent"
stop_second=$(sed -n 's/^turn 1 \([0-9][0-9]*\)$/\1/p' "$STOP_STAMP")
[ "$stop_second" -gt "$stop_first" ] || fail 8 "second Stop did not overwrite with a newer epoch"
pass 8 "Stop writes a turn marker for the resolved identity in ${stop_elapsed_ms}ms and suppresses recursive/unresolved writes"

END_HOME=$RIG/end-home
END_PROJECT=$RIG/end-session
init_home "$END_HOME"
make_project "$END_PROJECT" end-session
run_start_without_env "$END_HOME" "$END_PROJECT" "$RIG/end-start.out" || fail 9 "SessionStart for end fixture failed"
printf '%s\n' '{"session_id":"end-session-test"}' | HOME=$FAKE_HOME KHALA_HOME=$END_HOME \
    KHALA_RUNTIME_DIR=$END_HOME/runtime-root KHALA_TEST_BOOT_ID=plugin-test-boot \
    KHALA_CLAUDE_SESSION_ID=end-session-test CLAUDE_PROJECT_DIR=$END_PROJECT \
    PATH=$SHIM:/usr/bin:/bin "$END" >"$RIG/end.out" 2>"$RIG/end.err" || fail 9 "SessionEnd failed"
[ -z "$(find "$END_HOME/runtime-root/sessions" -name '*.json' -print -quit)" ] || \
    fail 9 "SessionEnd left its registration"
grep -q '"state":"released"' "$END_HOME/runtime-root/identities/end-session.lease" || \
    fail 9 "SessionEnd did not release the lease"
pass 9 "SessionEnd removes registration and releases its lease"

COLLIDE_HOME=$RIG/collide-home
COLLIDE_PROJECT=$RIG/collide-session
init_home "$COLLIDE_HOME"
make_project "$COLLIDE_PROJECT" collide
HOME=$FAKE_HOME KHALA_HOME=$COLLIDE_HOME KHALA_RUNTIME_DIR=$COLLIDE_HOME/runtime-root \
    KHALA_TEST_BOOT_ID=plugin-test-boot KHALA_CLAUDE_SESSION_ID=owner-session KHALA_SESSION_PID=$$ \
    KHALA_SESSION_KIND=interactive \
    CLAUDE_PROJECT_DIR=$COLLIDE_PROJECT PATH=$SHIM:/usr/bin:/bin "$START" </dev/null \
    >"$RIG/collide-owner.out" 2>"$RIG/collide-owner.err" || fail 10 "owner hook failed"
stage_letter "$COLLIDE_HOME" collide collision-body
HOME=$FAKE_HOME KHALA_HOME=$COLLIDE_HOME KHALA_RUNTIME_DIR=$COLLIDE_HOME/runtime-root \
    KHALA_TEST_BOOT_ID=plugin-test-boot KHALA_CLAUDE_SESSION_ID=other-session KHALA_SESSION_PID=$$ \
    KHALA_SESSION_KIND=interactive \
    CLAUDE_PROJECT_DIR=$COLLIDE_PROJECT PATH=$SHIM:/usr/bin:/bin "$START" \
    <<<'{"session_id":"other-session"}' >"$RIG/collide-other.out" 2>"$RIG/collide-other.err" || \
    fail 10 "second hook failed"
grep -q 'you are not the receiver of collide' "$RIG/collide-other.out" || \
    fail 10 "non-receiver warning missing"
[ "$(count_files "$COLLIDE_HOME/inbox/collide/new")" -eq 1 ] || \
    fail 10 "non-owner hook read a message"
pass 10 "duplicate identity warns loudly and non-owner inbox read moves nothing"

for audit_script in "$ROOT/plugin/hooks/lib.sh" "$START" "$STOP" "$END"; do
    bash -n "$audit_script" || fail 11 "bash syntax failed: $audit_script"
done
if grep -En '^[[:space:]]*tmux([[:space:]]|$)|signal-send' "$ROOT"/plugin/hooks/*.sh \
    > "$RIG/r13-audit.out"; then
    fail 11 "R13-forbidden command found: $(tr '\n' ' ' < "$RIG/r13-audit.out")"
fi
if grep -En 'declare[[:space:]]+-A|mapfile|readarray|\$\{[^}]*,,|\$\{![^}]*\[@\]' \
    "$ROOT"/plugin/hooks/*.sh > "$RIG/bash4-audit.out"; then
    fail 11 "bash-4-only construct found: $(tr '\n' ' ' < "$RIG/bash4-audit.out")"
fi
# Audit scope is the plugin's own runtime (hooks/skill/manifests); the bundled
# CLI is a byte copy of bin/khala with its own suites (and its $KHALA_ROOT/tmp
# usage is not the forbidden system /tmp).
grep -R -En '(^|[=[:space:]"])/tmp(/|[[:space:]"]|$)' \
    "$ROOT/plugin/hooks" "$ROOT/plugin/skills" "$ROOT/plugin/.claude-plugin" \
    > "$RIG/tmp-audit.out" && \
    fail 11 "plugin references /tmp: $(tr '\n' ' ' < "$RIG/tmp-audit.out")"
grep -R -n 'jq' "$ROOT/plugin/hooks" "$ROOT/plugin/skills" "$ROOT/plugin/.claude-plugin" \
    > "$RIG/jq-audit.out" && \
    fail 11 "plugin runtime references jq: $(tr '\n' ' ' < "$RIG/jq-audit.out")"
pass 11 "R13, bash 3.2, no-jq, no-/tmp, and bash -n audits pass"

# Property 13 — CLI self-install ownership rules. Each case gets its own HOME.
run_start_home() {
    run_fake_home=$1
    run_output=$2
    (
        unset KHALA_SESSION
        HOME=$run_fake_home KHALA_HOME=$run_fake_home/absent-khala \
            CLAUDE_PROJECT_DIR=$RIG/cli-project PATH=$SHIM:/usr/bin:/bin \
            "$START" < /dev/null
    ) > "$run_output" 2> "$run_output.err"
}
make_project "$RIG/cli-project" cli-session
RECEIPT_REL=.local/bin/.khala.plugin-receipt

CLI_FRESH=$RIG/cli-fresh
mkdir -p "$CLI_FRESH"
run_start_home "$CLI_FRESH" "$RIG/cli-fresh.out" || fail 13 "fresh-home run failed"
cmp -s "$ROOT/plugin/bin/khala" "$CLI_FRESH/.local/bin/khala" || \
    fail 13 "fresh home did not receive the bundled CLI"
[ -f "$CLI_FRESH/$RECEIPT_REL" ] || fail 13 "fresh install left no receipt"
grep -q 'CLI 설치됨' "$RIG/cli-fresh.out" || fail 13 "fresh install was silent"
run_start_home "$CLI_FRESH" "$RIG/cli-again.out" || fail 13 "second run failed"
grep -q 'CLI' "$RIG/cli-again.out" && fail 13 "idempotent rerun still talked about the CLI"

CLI_UPDATE=$RIG/cli-update
mkdir -p "$CLI_UPDATE/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$CLI_UPDATE/.local/bin/khala"
chmod 755 "$CLI_UPDATE/.local/bin/khala"
printf 'khala-plugin\n' > "$CLI_UPDATE/$RECEIPT_REL"
run_start_home "$CLI_UPDATE" "$RIG/cli-update.out" || fail 13 "receipted update run failed"
cmp -s "$ROOT/plugin/bin/khala" "$CLI_UPDATE/.local/bin/khala" || \
    fail 13 "receipted stale copy was not updated"
grep -q 'CLI 갱신됨' "$RIG/cli-update.out" || fail 13 "receipted update was silent"

# Receipted copies move forward only. Derive the three variants from the real
# bundled CLI so the version line is the only thing that differs.
BUNDLED_VERSION=$(sed -n 's/^KHALA_VERSION=\([0-9][0-9.]*\)$/\1/p' "$ROOT/plugin/bin/khala" | head -n 1)
[ -n "$BUNDLED_VERSION" ] || fail 13 "bundled CLI carries no KHALA_VERSION line"
BUNDLED_MAJOR=${BUNDLED_VERSION%%.*}
NEWER_VERSION=$((BUNDLED_MAJOR + 1)).0.0

CLI_NEWER=$RIG/cli-newer
mkdir -p "$CLI_NEWER/.local/bin"
sed "s/^KHALA_VERSION=.*/KHALA_VERSION=$NEWER_VERSION/" "$ROOT/plugin/bin/khala" > "$CLI_NEWER/.local/bin/khala"
chmod 755 "$CLI_NEWER/.local/bin/khala"
printf 'khala-plugin\n' > "$CLI_NEWER/$RECEIPT_REL"
run_start_home "$CLI_NEWER" "$RIG/cli-newer.out" || fail 13 "newer-install run failed"
grep -q "^KHALA_VERSION=$NEWER_VERSION\$" "$CLI_NEWER/.local/bin/khala" || \
    fail 13 "receipted newer install was rolled back to the bundled version"
grep -q '되돌리지 않습니다' "$RIG/cli-newer.out" || fail 13 "refused rollback was silent"

CLI_SAME=$RIG/cli-same-version
mkdir -p "$CLI_SAME/.local/bin"
{ cat "$ROOT/plugin/bin/khala"; printf '# local patch\n'; } > "$CLI_SAME/.local/bin/khala"
chmod 755 "$CLI_SAME/.local/bin/khala"
printf 'khala-plugin\n' > "$CLI_SAME/$RECEIPT_REL"
run_start_home "$CLI_SAME" "$RIG/cli-same.out" || fail 13 "same-version run failed"
grep -q '^# local patch$' "$CLI_SAME/.local/bin/khala" || \
    fail 13 "receipted same-version copy with different bytes was overwritten"
grep -q '바이트가 다릅니다' "$RIG/cli-same.out" || fail 13 "same-version divergence was silent"

CLI_OLDER=$RIG/cli-older
mkdir -p "$CLI_OLDER/.local/bin"
sed "s/^KHALA_VERSION=.*/KHALA_VERSION=0.0.1/" "$ROOT/plugin/bin/khala" > "$CLI_OLDER/.local/bin/khala"
chmod 755 "$CLI_OLDER/.local/bin/khala"
printf 'khala-plugin\n' > "$CLI_OLDER/$RECEIPT_REL"
run_start_home "$CLI_OLDER" "$RIG/cli-older.out" || fail 13 "older-install run failed"
cmp -s "$ROOT/plugin/bin/khala" "$CLI_OLDER/.local/bin/khala" || \
    fail 13 "receipted older install was not upgraded"
grep -q 'CLI 갱신됨' "$RIG/cli-older.out" || fail 13 "older-install upgrade was silent"

CLI_MANUAL=$RIG/cli-manual
mkdir -p "$CLI_MANUAL/.local/bin"
printf '#!/bin/sh\nexit 7\n' > "$CLI_MANUAL/.local/bin/khala"
chmod 755 "$CLI_MANUAL/.local/bin/khala"
run_start_home "$CLI_MANUAL" "$RIG/cli-manual.out" || fail 13 "manual-copy run failed"
printf '#!/bin/sh\nexit 7\n' | cmp -s - "$CLI_MANUAL/.local/bin/khala" || \
    fail 13 "unreceipted manual copy was overwritten"
grep -q '수동 설치본으로 보고 건드리지 않습니다' "$RIG/cli-manual.out" || \
    fail 13 "manual copy was not announced"

CLI_LINK=$RIG/cli-symlink
mkdir -p "$CLI_LINK/.local/bin"
printf '#!/bin/sh\nexit 9\n' > "$CLI_LINK/elsewhere"
ln -s "$CLI_LINK/elsewhere" "$CLI_LINK/.local/bin/khala"
run_start_home "$CLI_LINK" "$RIG/cli-symlink.out" || fail 13 "symlink run failed"
[ -L "$CLI_LINK/.local/bin/khala" ] || fail 13 "symlink was replaced"
printf '#!/bin/sh\nexit 9\n' | cmp -s - "$CLI_LINK/elsewhere" || \
    fail 13 "symlink target was rewritten"
grep -q '심링크(수동 관리)' "$RIG/cli-symlink.out" || fail 13 "divergent symlink was silent"
rm -f "$CLI_LINK/elsewhere"
cp "$ROOT/plugin/bin/khala" "$CLI_LINK/elsewhere"
run_start_home "$CLI_LINK" "$RIG/cli-symlink-same.out" || fail 13 "identical-symlink run failed"
grep -q 'CLI' "$RIG/cli-symlink-same.out" && fail 13 "identical symlink still warned"
pass 13 "CLI self-install: fresh installs, receipted forward updates only, manual copies and symlinks stay untouched"

# An outer driver (minds.sh T1) that has already run every legacy suite once can
# skip this recursive re-run; nested duplicate load flaked three distinct
# suites on loaded hosts without ever reproducing standalone.
if [ "${PLUGIN_SKIP_REGRESSION-}" = 1 ]; then
    printf 'SKIP 12 — outer driver owns legacy coverage\n'
    printf 'RESULT: PASS\n'
    printf 'Claude Code plugin conduit hooks and lease lifecycle passed (regressions skipped by driver)\n'
    exit 0
fi
for regression_suite in local-roundtrip exchange-roundtrip hardening concurrency watch; do
    if ! bash "$ROOT/test/$regression_suite.sh" > "$RIG/$regression_suite.out" 2>&1; then
        cat "$RIG/$regression_suite.out"
        fail 12 "$regression_suite failed"
    fi
    cat "$RIG/$regression_suite.out"
    grep -q '^RESULT: PASS$' "$RIG/$regression_suite.out" || \
        fail 12 "$regression_suite omitted RESULT: PASS"
done
if [ -x "$GO" ]; then
    if ! GO_BINARY=$GO bash "$ROOT/test/link.sh" > "$RIG/link.out" 2>&1; then
        cat "$RIG/link.out"
        fail 12 "link.sh failed"
    fi
    cat "$RIG/link.out"
    grep -q '^RESULT: PASS$' "$RIG/link.out" || fail 12 "link.sh omitted RESULT: PASS"
else
    printf 'SKIP link — Go toolchain is not an executable path: %s\n' "$GO"
fi
pass 12 "all available existing suites pass unchanged"


printf 'RESULT: PASS\n'
printf 'Claude Code plugin conduit hooks, lease lifecycle, and regressions passed\n'
