#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
STOP=$ROOT/plugin/hooks/stop.sh
RIG=$ROOT/.plugin-test-$$
SHIM=$RIG/shim

cleanup() {
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
        KHALA_HOME=$run_home CLAUDE_PROJECT_DIR=$run_project PATH=$SHIM:/usr/bin:/bin \
            "$START"
    ) > "$run_output" 2> "$run_output.err"
}

run_stop_without_env() {
    run_home=$1
    run_project=$2
    run_input=$3
    run_output=$4
    (
        unset KHALA_SESSION
        printf '%s\n' "$run_input" | KHALA_HOME=$run_home CLAUDE_PROJECT_DIR=$run_project \
            PATH=$SHIM:/usr/bin:/bin "$STOP"
    ) > "$run_output" 2> "$run_output.err"
}

mkdir -p "$RIG" "$SHIM" || fail setup "could not create fixture root"
ln -s "$KHALA" "$SHIM/khala" || fail setup "could not create PATH shim"
trap cleanup EXIT HUP INT TERM

# Python is a test-rig-only JSON parser; the plugin runtime has no Python dependency.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$ROOT/plugin/.claude-plugin/plugin.json" || fail 1 "plugin.json is invalid"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$ROOT/plugin/hooks/hooks.json" || fail 1 "hooks.json is invalid"
pass 1 "plugin manifests are valid JSON (Python is test-only)"

UNINIT=$RIG/uninitialized
UNINIT_PROJECT=$RIG/uninit-session
make_project "$UNINIT_PROJECT" uninit-session
mkdir -p "$UNINIT"
run_start_without_env "$UNINIT" "$UNINIT_PROJECT" "$RIG/uninit-start.out"
[ "$?" -eq 0 ] || fail 2 "uninitialized SessionStart exited nonzero"
[ "$(wc -l < "$RIG/uninit-start.out" | tr -d ' ')" -eq 1 ] || \
    fail 2 "uninitialized SessionStart did not print exactly one line"
grep -Fqx 'khala: 미설치/미초기화 — 이 노드는 칼라 밖입니다' "$RIG/uninit-start.out" || \
    fail 2 "uninitialized SessionStart line differs"
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
KHALA_HOME=$PRE_HOME CLAUDE_PROJECT_DIR=$PRE_PROJECT KHALA_SESSION=env-session \
    PATH=$SHIM:/usr/bin:/bin "$START" > "$RIG/precedence-env.out" 2> "$RIG/precedence-env.err" || \
    fail 5 "environment precedence run failed"
grep -q 'env-wins' "$RIG/precedence-env.out" || fail 5 "environment identity did not win"
grep -q 'file-next' "$RIG/precedence-env.out" && fail 5 "file identity beat environment"
run_start_without_env "$PRE_HOME" "$PRE_PROJECT" "$RIG/precedence-file.out" || \
    fail 5 "file precedence run failed"
grep -q 'file-next' "$RIG/precedence-file.out" || fail 5 "file identity did not beat basename"
printf '%s\n' 'UpperCase' > "$PRE_PROJECT/.khala-session"
run_start_without_env "$PRE_HOME" "$PRE_PROJECT" "$RIG/precedence-fallback.out" || \
    fail 5 "malformed-file fallback run failed"
grep -q '.khala-session이 한 줄의 유효한 세션 이름이 아닙니다' "$RIG/precedence-fallback.out" || \
    fail 5 "malformed identity warning missing"
grep -q 'basename-last' "$RIG/precedence-fallback.out" || fail 5 "malformed file did not fall through"
UPPER_PROJECT=$RIG/UpperProject
make_project "$UPPER_PROJECT"
run_start_without_env "$PRE_HOME" "$UPPER_PROJECT" "$RIG/uppercase-basename.out" || \
    fail 5 "uppercase basename path exited nonzero"
grep -q '프로젝트 디렉터리명으로 세션을 정할 수 없습니다: UpperProject' \
    "$RIG/uppercase-basename.out" || fail 5 "uppercase basename explanation missing"
pass 5 "identity resolution order and non-mangling rules hold"

ARM_HOME=$RIG/arm-home
ARM_PROJECT=$RIG/arm-session
init_home "$ARM_HOME"
make_project "$ARM_PROJECT" arm-session
run_start_without_env "$ARM_HOME" "$ARM_PROJECT" "$RIG/unarmed.out" || fail 6 "unarmed run failed"
expected_arm='(run_in_background) KHALA_SESSION=arm-session khala watch --session arm-session --interval 30'
tail -n 1 "$RIG/unarmed.out" | grep -Fq "$expected_arm" || fail 6 "exact arm instruction missing"
mkdir -p "$ARM_HOME/run/watch.arm-session.lock.d"
arm_now=$(date +%s) || fail 6 "could not read epoch"
printf '%s\npid 4242 watch\n30\n' "$arm_now" > "$ARM_HOME/run/watch.arm-session.lock.d/owner"
run_start_without_env "$ARM_HOME" "$ARM_PROJECT" "$RIG/armed.out" || fail 6 "armed run failed"
grep -q 'watch 무장됨 (pid 4242)' "$RIG/armed.out" || fail 6 "armed status missing"
grep -q 'run_in_background' "$RIG/armed.out" && fail 6 "armed status retained instruction"
pass 6 "status ends with exact arm command or fresh-lock pid"

LINK_HOME=$RIG/link-home
LINK_PROJECT=$RIG/link-session
init_home "$LINK_HOME"
make_project "$LINK_PROJECT" link-session
mkdir -p "$LINK_HOME/bin" "$LINK_HOME/run"
cat > "$LINK_HOME/bin/khala-link" <<'FAKE_LINK'
#!/usr/bin/env bash
set -u
if ! mkdir "$KHALA_HOME/run/fake-link.lock.d" 2>/dev/null; then
    exit 0
fi
printf '%s\n' "$$" >> "$KHALA_HOME/run/link-proof"
sleep 2
touch "$KHALA_HOME/run/link.fresh"
rmdir "$KHALA_HOME/run/fake-link.lock.d"
FAKE_LINK
chmod +x "$LINK_HOME/bin/khala-link"
touch -t 200001010000 "$LINK_HOME/run/link.fresh"
run_start_without_env "$LINK_HOME" "$LINK_PROJECT" "$RIG/link-first.out" || fail 7 "first link ensure failed"
link_wait=0
while [ ! -s "$LINK_HOME/run/link-proof" ] && [ "$link_wait" -lt 5 ]; do
    sleep 1
    link_wait=$((link_wait + 1))
done
[ -s "$LINK_HOME/run/link-proof" ] || fail 7 "link shim did not start"
run_start_without_env "$LINK_HOME" "$LINK_PROJECT" "$RIG/link-second.out" || fail 7 "second link ensure failed"
link_wait=0
while [ "$link_wait" -lt 5 ]; do
    link_epoch=$(date +%s)
    link_mtime=$(stat -c %Y "$LINK_HOME/run/link.fresh" 2>/dev/null || stat -f %m "$LINK_HOME/run/link.fresh")
    if [ "$((link_epoch - link_mtime))" -le 1 ]; then
        break
    fi
    sleep 1
    link_wait=$((link_wait + 1))
done
[ "$(wc -l < "$LINK_HOME/run/link-proof" | tr -d ' ')" -eq 1 ] || \
    fail 7 "two stale-marker hook runs started link work twice"
rm -f "$LINK_HOME/run/link-proof"
run_start_without_env "$LINK_HOME" "$LINK_PROJECT" "$RIG/link-fresh.out" || fail 7 "fresh link run failed"
sleep 1
[ ! -e "$LINK_HOME/run/link-proof" ] || fail 7 "fresh link marker started the shim"
pass 7 "stale link ensure is singleton and fresh link is untouched"

STOP_HOME=$RIG/stop-home
STOP_PROJECT=$RIG/stop-session
NO_ID_PROJECT=$RIG/no-identity
init_home "$STOP_HOME"
make_project "$STOP_PROJECT" stop-session
make_project "$NO_ID_PROJECT"
KHALA_HOME=$STOP_HOME CLAUDE_PROJECT_DIR=$STOP_PROJECT KHALA_SESSION=stop-session \
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
pass 8 "Stop silently allows recursion, no identity, and fresh armament"

rm -rf -- "$STOP_HOME/run/watch.stop-session.lock.d"
run_stop_without_env "$STOP_HOME" "$STOP_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-block.out" || \
    fail 9 "missing-lock Stop exited nonzero"
[ "$(wc -l < "$RIG/stop-block.out" | tr -d ' ')" -eq 1 ] || fail 9 "block JSON is not one line"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["decision"] == "block"; assert "KHALA_SESSION=stop-session khala watch --session stop-session --interval 30" in d["reason"]' \
    "$RIG/stop-block.out" || fail 9 "block output is invalid or lacks arm command"
pass 9 "missing armament emits one valid block decision"

mkdir -p "$STOP_HOME/run/watch.stop-session.lock.d"
printf '%s\npid 6262 watch\n30\n' "$((stop_now - 301))" > "$STOP_HOME/run/watch.stop-session.lock.d/owner"
run_stop_without_env "$STOP_HOME" "$STOP_PROJECT" '{"stop_hook_active":false}' "$RIG/stop-stale.out" || \
    fail 10 "stale-lock Stop exited nonzero"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["decision"] == "block"' \
    "$RIG/stop-stale.out" || fail 10 "stale lock did not block"
pass 10 "owner older than 2*(interval+120) is stale"

for audit_script in "$ROOT/plugin/hooks/lib.sh" "$START" "$STOP"; do
    bash -n "$audit_script" || fail 11 "bash syntax failed: $audit_script"
done
if grep -En '^[[:space:]]*(kill|tmux)([[:space:]]|$)|signal-send' "$ROOT"/plugin/hooks/*.sh \
    > "$RIG/r13-audit.out"; then
    fail 11 "R13-forbidden command found: $(tr '\n' ' ' < "$RIG/r13-audit.out")"
fi
if grep -En 'declare[[:space:]]+-A|mapfile|readarray|\$\{[^}]*,,|\$\{![^}]*\[@\]' \
    "$ROOT"/plugin/hooks/*.sh > "$RIG/bash4-audit.out"; then
    fail 11 "bash-4-only construct found: $(tr '\n' ' ' < "$RIG/bash4-audit.out")"
fi
grep -R -n '/tmp' "$ROOT/plugin" > "$RIG/tmp-audit.out" && \
    fail 11 "plugin references /tmp: $(tr '\n' ' ' < "$RIG/tmp-audit.out")"
grep -R -n 'jq' "$ROOT/plugin" > "$RIG/jq-audit.out" && \
    fail 11 "plugin runtime references jq: $(tr '\n' ' ' < "$RIG/jq-audit.out")"
pass 11 "R13, bash 3.2, no-jq, no-/tmp, and bash -n audits pass"

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
printf 'Claude Code plugin hooks, skill, armament repair, and regressions passed\n'
