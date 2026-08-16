#!/usr/bin/env bash
# R13 boundary: this hook signals only child commands it started itself to
# enforce the SessionStart deadline. It never signals a Claude/session process.
set -u

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
. "$HOOK_DIR/lib.sh"

khala_start_input=$(cat 2>/dev/null) || khala_start_input=
khala_ensure_cli "$HOOK_DIR/.."

if ! khala_discover; then
    printf '%s\n' 'khala: 노드 미초기화 — 이 노드는 칼라 밖입니다 (참여하려면: khala init <노드별칭> 후 ~/.khala/config에 함대 선언)'
    exit 0
fi
if ! khala_resolve_session 0 1; then
    exit 0
fi
if ! khala_self_node; then
    printf '%s\n' 'khala: config의 self 항목이 없거나 잘못되었습니다 — 등록과 드레인을 건너뜁니다'
    exit 0
fi

khala_hook_session_id=$(printf '%s\n' "$khala_start_input" | tr '\n' ' ' | \
    sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')
[ -n "$khala_hook_session_id" ] || khala_hook_session_id=${KHALA_CLAUDE_SESSION_ID-hook-$PPID}
khala_hook_socket=${CLAUDE_CODE_MESSAGING_SOCKET-}
khala_hook_pid=${KHALA_SESSION_PID-0}
khala_hook_kind=${KHALA_SESSION_KIND-auto}
khala_hook_version=${CLAUDE_CODE_VERSION-}
khala_hook_bind=$KHALA_ROOT/tmp/session-bind.$$
khala_hook_bind_err=$KHALA_ROOT/tmp/session-bind.$$.err
mkdir -p "$KHALA_ROOT/tmp" || exit 0

if ! KHALA_SESSION="$KHALA_RESOLVED_SESSION" KHALA_CLAUDE_SESSION_ID="$khala_hook_session_id" \
    "$KHALA_BIN" bind --register starting --session-id "$khala_hook_session_id" \
    --pid "$khala_hook_pid" --socket "$khala_hook_socket" --kind "$khala_hook_kind" \
    --cc-version "$khala_hook_version" > "$khala_hook_bind" 2> "$khala_hook_bind_err"; then
    printf 'khala: session registration 거부 — %s\n' "$(tr '\n' ' ' < "$khala_hook_bind_err")"
    rm -f "$khala_hook_bind" "$khala_hook_bind_err"
    exit 0
fi
khala_hook_instance=$(sed -n 's/^instance //p' "$khala_hook_bind")
if [ -z "$khala_hook_instance" ]; then
    printf '%s\n' 'khala: session registration이 instance를 반환하지 않았습니다 — 드레인을 건너뜁니다'
    rm -f "$khala_hook_bind" "$khala_hook_bind_err"
    exit 0
fi
if ! KHALA_SESSION="$KHALA_RESOLVED_SESSION" KHALA_SESSION_INSTANCE="$khala_hook_instance" \
    KHALA_CLAUDE_SESSION_ID="$khala_hook_session_id" \
    "$KHALA_BIN" bind --register ready --instance "$khala_hook_instance" \
    --session-id "$khala_hook_session_id" --pid "$khala_hook_pid" \
    --socket "$khala_hook_socket" --kind "$khala_hook_kind" --cc-version "$khala_hook_version" \
    > "$khala_hook_bind" 2> "$khala_hook_bind_err"; then
    printf 'khala: session ready registration 거부 — %s\n' "$(tr '\n' ' ' < "$khala_hook_bind_err")"
    rm -f "$khala_hook_bind" "$khala_hook_bind_err"
    exit 0
fi
khala_hook_owner=$(sed -n 's/^owner //p' "$khala_hook_bind")
rm -f "$khala_hook_bind" "$khala_hook_bind_err"
khala_native_warning=$(KHALA_SESSION="$KHALA_RESOLVED_SESSION" \
    "$KHALA_BIN" bind --native-warning --instance "$khala_hook_instance" 2>/dev/null) || \
    khala_native_warning=
if [ "$khala_native_warning" = native-degraded ]; then
    printf 'khala: %s native-degraded — socket doorbell failures; khala status를 확인하세요\n' \
        "$KHALA_RESOLVED_SESSION"
fi

# Model declaration is independent of inbox consumption, but it shares the
# brain lock with drain and join. Finish its bounded attempt before starting
# those jobs so the hook cannot starve its own authoritative model update.
khala_join_job=
khala_start_model=$(printf '%s\n' "$khala_start_input" | tr '\n' ' ' | \
    sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')
khala_profile_out=$KHALA_ROOT/tmp/session-profile.$$
khala_profile_err=$KHALA_ROOT/tmp/session-profile.$$.err
if [ -n "$khala_start_model" ]; then
    if ! khala_run_with_deadline 1 "$khala_profile_out" "$khala_profile_err" env \
        KHALA_SESSION="$KHALA_RESOLVED_SESSION" "$KHALA_BIN" profile --model "$khala_start_model"; then
        printf '%s\n' 'khala: SessionStart model profile 선언 실패 — 상세는 stderr를 확인하세요' >&2
        [ ! -s "$khala_profile_err" ] || cat "$khala_profile_err" >&2
    fi
fi
rm -f "$khala_profile_out" "$khala_profile_err"
khala_commons_state=$KHALA_ROOT/join/$KHALA_RESOLVED_SESSION/khala
khala_join_out=$KHALA_ROOT/tmp/session-join.$$
khala_join_err=$KHALA_ROOT/tmp/session-join.$$.err
if [ ! -f "$khala_commons_state" ]; then
    (khala_run_with_deadline 1 "$khala_join_out" "$khala_join_err" env \
        KHALA_SESSION="$KHALA_RESOLVED_SESSION" "$KHALA_BIN" join khala) &
    khala_join_job=$!
fi

khala_new_dir=$KHALA_ROOT/inbox/$KHALA_RESOLVED_SESSION/new
khala_before=$(khala_count_files "$khala_new_dir")
khala_drained=0
if [ "$khala_hook_owner" = yes ]; then
    khala_drain_out=$KHALA_ROOT/tmp/session-drain.$$
    khala_drain_err=$KHALA_ROOT/tmp/session-drain.$$.err
    if KHALA_SESSION="$KHALA_RESOLVED_SESSION" \
        khala_run_with_deadline 10 "$khala_drain_out" "$khala_drain_err" \
        "$KHALA_BIN" inbox --drain; then
        :
    else
        khala_drain_status=$?
        if [ "$khala_drain_status" -eq 124 ]; then
            printf '%s\n' 'khala: inbox drain 10s deadline — registration은 이미 ready입니다' >&2
        else
            printf '%s\n' 'khala: inbox drain 실패 — 상세는 stderr를 확인하세요' >&2
        fi
    fi
    [ ! -f "$khala_drain_out" ] || cat "$khala_drain_out"
    [ ! -s "$khala_drain_err" ] || cat "$khala_drain_err" >&2
    rm -f "$khala_drain_out" "$khala_drain_err"
    khala_after=$(khala_count_files "$khala_new_dir")
    khala_drained=$((khala_before - khala_after))
    [ "$khala_drained" -ge 0 ] || khala_drained=0
else
    printf 'khala: you are not the receiver of %s — set KHALA_SESSION=<other> or `khala bind --takeover` (pending %s)\n' \
        "$KHALA_RESOLVED_SESSION" "$khala_before"
fi

khala_aux_out=$KHALA_ROOT/tmp/session-aux.$$
khala_aux_err=$KHALA_ROOT/tmp/session-aux.$$.err
if ! khala_run_with_deadline 1 "$khala_aux_out" "$khala_aux_err" "$KHALA_BIN" node ensure; then
    printf '%s\n' 'khala: node ensure가 1s 안에 끝나지 않았습니다 — daemon singleton이 후속 호출을 보호합니다' >&2
fi
[ ! -s "$khala_aux_out" ] || cat "$khala_aux_out"
[ ! -s "$khala_aux_err" ] || cat "$khala_aux_err" >&2
rm -f "$khala_aux_out" "$khala_aux_err"

[ -z "$khala_join_job" ] || wait "$khala_join_job" 2>/dev/null || :
rm -f "$khala_join_out" "$khala_join_err"

printf 'khala: %s@%s — registration ready, lease %s, 편지 %s건 드레인\n' \
    "$KHALA_RESOLVED_SESSION" "$KHALA_NODE" "$khala_hook_owner" "$khala_drained"
exit 0
