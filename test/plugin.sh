#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
STOP=$ROOT/plugin/hooks/stop.sh
END=$ROOT/plugin/hooks/session-end.sh
GO=${GO:-/NHNHOME/jahn/go-toolchain/bin/go}
RIG=$ROOT/.plugin-test-$$
SHIM=$RIG/shim
LINK_BIN=$RIG/khala-link

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

init_home() {
    init_target=$1
    KHALA_HOME=$init_target "$KHALA" init alpha >/dev/null 2>"$RIG/init.err" || \
        fail setup "khala init failed: $(tr '\n' ' ' < "$RIG/init.err")"
    mkdir -p "$init_target/bin" || fail setup "could not create fixture bin"
    cp "$LINK_BIN" "$init_target/bin/khala-link" || fail setup "could not install fixture link"
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
trap cleanup EXIT HUP INT TERM

# Python is a test-rig-only JSON parser; the plugin runtime has no Python dependency.
uv run --no-project python -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$ROOT/plugin/.claude-plugin/plugin.json" || fail 1 "plugin.json is invalid"
uv run --no-project python -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$ROOT/plugin/hooks/hooks.json" || fail 1 "hooks.json is invalid"
cmp -s "$ROOT/bin/khala" "$ROOT/plugin/bin/khala" || \
    fail 1 "plugin/bin/khala drifted from bin/khala"
# CC auto-loads hooks/hooks.json; a manifest "hooks" key naming it again is a
# duplicate that fails the whole plugin load (fleet-observed, 2026-08-13).
grep -q '"hooks"' "$ROOT/plugin/.claude-plugin/plugin.json" && \
    fail 1 "plugin.json references hooks (auto-loaded path must not be repeated)"
pass 1 "plugin manifests are valid JSON, no duplicate hooks ref, bundled CLI matches bin/khala"

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
    fail 3 "drain SessionStart exited nonzero"
grep -q 'first-body' "$RIG/drain.out" || fail 3 "first body missing"
grep -q 'second-body' "$RIG/drain.out" || fail 3 "second body missing"
[ "$(count_files "$DRAIN_HOME/inbox/drain-session/new")" -eq 0 ] || \
    fail 3 "new inbox is not empty after drain"
[ "$(count_files "$DRAIN_HOME/inbox/drain-session/cur")" -eq 2 ] || \
    fail 3 "two letters did not reach cur"
pass 3 "SessionStart reconciles and drains two staged letters"

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
[ "$(grep -c '^--- .* ---$' "$RIG/cap.out")" -eq 20 ] || fail 4 "drain did not stop at 20"
grep -q '^5건 더 (' "$RIG/cap.out" || fail 4 "remaining-letter summary did not reach stdout"
[ "$(count_files "$CAP_HOME/inbox/cap-session/new")" -eq 5 ] || \
    fail 4 "cap did not leave five letters new"
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
grep -q 'node ensure started conduit,link' "$RIG/node-first.out" || fail 7 "conduit/link start line missing"
grep -q 'crossSessionInbound.*accept' "$RIG/node-first.out.err" || fail 7 "accept setting instruction missing"
[ ! -e "$FAKE_HOME/.claude/settings.json" ] || fail 7 "hook edited user settings"
node_wait=0
while ! KHALA_RUNTIME_DIR=$LINK_HOME/runtime-root KHALA_TEST_BOOT_ID=plugin-test-boot \
    KHALA_HOME=$LINK_HOME "$LINK_HOME/bin/khala-link" runtime daemon-status >/dev/null 2>&1 && \
    [ "$node_wait" -lt 40 ]; do
    sleep 0.05
    node_wait=$((node_wait + 1))
done
[ "$node_wait" -lt 40 ] || fail 7 "conduit did not outlive SessionStart"
node_wait=0
while [ ! -f "$LINK_HOME/run/link.status" ] && [ "$node_wait" -lt 40 ]; do
    sleep 0.05
    node_wait=$((node_wait + 1))
done
[ "$node_wait" -lt 40 ] || fail 7 "link did not outlive SessionStart"
node_link_pid=$(sed -n 's/^pid \([0-9][0-9]*\)$/\1/p' "$LINK_HOME/run/link.status")
kill -0 "$node_link_pid" 2>/dev/null || fail 7 "link status pid is not live"
run_start_without_env "$LINK_HOME" "$LINK_PROJECT" "$RIG/node-second.out" || fail 7 "second node ensure failed"
grep -q 'node ensure started' "$RIG/node-second.out" && fail 7 "idempotent ensure started a duplicate"
pass 7 "node ensure starts detached conduit/link processes and is idempotent"

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
run_stop_without_env "$STOP_HOME" "$NO_ID_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-no-id.out" || \
    fail 8 "no-identity Stop exited nonzero"
[ ! -s "$RIG/stop-no-id.out" ] && [ ! -s "$RIG/stop-no-id.out.err" ] || \
    fail 8 "basename-only Stop was not silent"
mkdir -p "$STOP_HOME/run/watch.stop-session.lock.d"
stop_now=$(date +%s) || fail 8 "could not read Stop epoch"
printf '%s\npid 5252 watch\n30\n' "$stop_now" > "$STOP_HOME/run/watch.stop-session.lock.d/owner"
run_stop_without_env "$STOP_HOME" "$STOP_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-fresh.out" || \
    fail 8 "fresh-lock Stop exited nonzero"
[ ! -s "$RIG/stop-fresh.out" ] && [ ! -s "$RIG/stop-fresh.out.err" ] || \
    fail 8 "fresh-lock Stop was not silent"
pass 8 "Stop is a silent no-op regardless of recursion, identity, or legacy watch state"

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
    fail 10 "non-owner hook drained a letter"
pass 10 "duplicate identity warns loudly and non-owner drain moves nothing"

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

# An outer driver (minds T1) that has already run every legacy suite once can
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
if [ -x "$HOME/go-toolchain/bin/go" ]; then
    if ! bash "$ROOT/test/link.sh" > "$RIG/link.out" 2>&1; then
        cat "$RIG/link.out"
        fail 12 "link failed"
    fi
    cat "$RIG/link.out"
    grep -q '^RESULT: PASS$' "$RIG/link.out" || fail 12 "link omitted RESULT: PASS"
else
    printf 'SKIP link — Go toolchain missing at %s/go-toolchain/bin/go\n' "$HOME"
fi
pass 12 "all available existing suites pass unchanged"


printf 'RESULT: PASS\n'
printf 'Claude Code plugin conduit hooks, lease lifecycle, and regressions passed\n'
