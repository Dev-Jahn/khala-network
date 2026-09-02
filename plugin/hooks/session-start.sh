#!/usr/bin/env bash
# R13 boundary: this hook signals only child commands it started itself to
# enforce the SessionStart deadline. It never signals a Claude/session process.
set -u

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
. "$HOOK_DIR/lib.sh"

khala_launch_link_autofetch() {
    khala_autofetch_target=$KHALA_ROOT/bin/khala-link
    [ ! -e "$khala_autofetch_target" ] && [ ! -L "$khala_autofetch_target" ] || return 0

    khala_autofetch_version=$(khala_cli_version "$KHALA_BIN")
    if [ -z "$khala_autofetch_version" ]; then
        printf '%s\n' 'khala: khala-link autofetch 실패 — 설치된 CLI 버전을 읽을 수 없습니다'
        return 0
    fi
    case "$(uname -s 2>/dev/null)" in
        Linux) khala_autofetch_os=linux ;;
        Darwin) khala_autofetch_os=darwin ;;
        *)
            printf 'khala: khala-link autofetch 실패 — 지원하지 않는 OS: %s\n' "$(uname -s 2>/dev/null)"
            return 0
            ;;
    esac
    case "$(uname -m 2>/dev/null)" in
        x86_64) khala_autofetch_arch=amd64 ;;
        aarch64|arm64) khala_autofetch_arch=arm64 ;;
        *)
            printf 'khala: khala-link autofetch 실패 — 지원하지 않는 architecture: %s\n' "$(uname -m 2>/dev/null)"
            return 0
            ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        khala_autofetch_downloader=curl
    elif command -v wget >/dev/null 2>&1; then
        khala_autofetch_downloader=wget
    else
        printf '%s\n' 'khala: khala-link autofetch 실패 — curl 또는 wget이 필요합니다'
        return 0
    fi

    khala_autofetch_asset=khala-link-$khala_autofetch_os-$khala_autofetch_arch
    khala_autofetch_base=${KHALA_LINK_RELEASE_BASE-https://github.com/Dev-Jahn/khala-network/releases/download/v$khala_autofetch_version}
    khala_autofetch_url=${khala_autofetch_base%/}/$khala_autofetch_asset
    khala_autofetch_log=$KHALA_ROOT/log/link-autofetch.log
    khala_autofetch_tmp=$KHALA_ROOT/bin/.khala-link.$$
    if ! mkdir -p "$KHALA_ROOT/bin" "$KHALA_ROOT/log" 2>/dev/null; then
        printf '%s\n' 'khala: khala-link autofetch 실패 — ~/.khala/bin 또는 log를 만들 수 없습니다'
        return 0
    fi

    (
        khala_autofetch_ok=0
        if [ "$khala_autofetch_downloader" = curl ]; then
            curl -fsSL "$khala_autofetch_url" -o "$khala_autofetch_tmp" 2>/dev/null && \
                khala_autofetch_ok=1
        else
            wget -q -O "$khala_autofetch_tmp" "$khala_autofetch_url" 2>/dev/null && \
                khala_autofetch_ok=1
        fi
        if [ "$khala_autofetch_ok" -eq 1 ] && chmod 755 "$khala_autofetch_tmp" 2>/dev/null; then
            if [ ! -e "$khala_autofetch_target" ] && [ ! -L "$khala_autofetch_target" ] && \
                mv "$khala_autofetch_tmp" "$khala_autofetch_target" 2>/dev/null; then
                printf 'khala: khala-link autofetch 완료 — %s\n' "$khala_autofetch_asset"
            else
                rm -f "$khala_autofetch_tmp" 2>/dev/null
                printf '%s\n' 'khala: khala-link autofetch 종료 — 기존 binary는 건드리지 않았습니다'
            fi
        else
            rm -f "$khala_autofetch_tmp" 2>/dev/null
            printf 'khala: khala-link autofetch 실패 — %s 다운로드 또는 설치 실패\n' \
                "$khala_autofetch_url"
        fi
    ) </dev/null >> "$khala_autofetch_log" 2>&1 &
    khala_autofetch_pid=$!
    printf 'khala: khala-link autofetch launched (pid %s) — 완료/실패는 %s; 이번 SessionStart는 기다리지 않습니다\n' \
        "$khala_autofetch_pid" "$khala_autofetch_log"
}

khala_start_input=$(cat 2>/dev/null) || khala_start_input=
khala_ensure_cli "$HOOK_DIR/.."

if ! khala_discover; then
    printf '%s\n' 'khala: 노드 미초기화 — 이 노드는 칼라 밖입니다 (참여하려면: khala init <노드별칭> 후 ~/.khala/config에 함대 선언)'
    exit 0
fi
khala_launch_link_autofetch
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
khala_before_snapshot=$KHALA_ROOT/tmp/session-before.$$
: > "$khala_before_snapshot"
for khala_before_path in "$khala_new_dir"/*; do
    [ -f "$khala_before_path" ] || continue
    khala_before_type=$(sed -n '/^$/q; s/^Type: //p' "$khala_before_path")
    printf '%s\t%s\n' "$khala_before_type" "$khala_before_path" >> "$khala_before_snapshot"
done
khala_drained_letters=0
khala_drained_notices=0
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
    while IFS="$(printf '\t')" read -r khala_before_type khala_before_path; do
        [ -n "${khala_before_path-}" ] || continue
        [ ! -e "$khala_before_path" ] || continue
        if [ "$khala_before_type" = notice ]; then
            khala_drained_notices=$((khala_drained_notices + 1))
        else
            khala_drained_letters=$((khala_drained_letters + 1))
        fi
    done < "$khala_before_snapshot"
else
    printf 'khala: you are not the receiver of %s — set KHALA_SESSION=<other> or `khala bind --takeover` (pending %s)\n' \
        "$KHALA_RESOLVED_SESSION" "$khala_before"
fi
rm -f "$khala_before_snapshot"

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

printf 'khala: %s@%s — registration ready, lease %s, 편지 %s건·알림 %s건 드레인\n' \
    "$KHALA_RESOLVED_SESSION" "$KHALA_NODE" "$khala_hook_owner" \
    "$khala_drained_letters" "$khala_drained_notices"
exit 0
