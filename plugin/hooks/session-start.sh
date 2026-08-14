#!/usr/bin/env bash
# R13 boundary: read/write only KHALA_HOME and emit hook output. No tmux,
# kill, signal, or input-lane injection; the detached link is a new child.
set -u

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
. "$HOOK_DIR/lib.sh"

khala_start_input=$(cat 2>/dev/null) || khala_start_input=

khala_ensure_cli "$HOOK_DIR/.."

if ! khala_discover; then
    printf '%s\n' 'khala: 노드 미초기화 — 이 노드는 칼라 밖입니다 (참여하려면: khala init <노드별칭> 후 ~/.khala/config에 함대 선언)'
    exit 0
fi

if ! khala_resolve_session 1 1; then
    exit 0
fi
if ! khala_self_node; then
    printf '%s\n' 'khala: config의 self 항목이 없거나 잘못되었습니다 — 드레인을 건너뜁니다'
    exit 0
fi

if ! "$KHALA_BIN" reconcile; then
    printf '%s\n' 'khala: 로컬 reconcile 실패 — 상세는 위 오류를 확인하세요' >&2
fi

# SessionStart input carries the selected model, but no effort field. Declare
# only facts supplied by the harness; effort remains an explicit self-report.
khala_start_model=$(printf '%s\n' "$khala_start_input" | tr '\n' ' ' | \
    sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')
if [ -n "$khala_start_model" ]; then
    if ! KHALA_SESSION="$KHALA_RESOLVED_SESSION" \
        "$KHALA_BIN" profile --model "$khala_start_model" >/dev/null; then
        printf '%s\n' 'khala: SessionStart model profile 선언 실패 — 상세는 위 오류를 확인하세요' >&2
    fi
fi

khala_commons_state=$KHALA_ROOT/join/$KHALA_RESOLVED_SESSION/khala
if [ ! -f "$khala_commons_state" ]; then
    if ! KHALA_SESSION="$KHALA_RESOLVED_SESSION" "$KHALA_BIN" join khala >/dev/null; then
        printf '%s\n' 'khala: commons 자동 합류 실패 — 상세는 위 오류를 확인하세요' >&2
    fi
fi

khala_new_dir=$KHALA_ROOT/inbox/$KHALA_RESOLVED_SESSION/new
khala_before=$(khala_count_files "$khala_new_dir")
if KHALA_SESSION="$KHALA_RESOLVED_SESSION" "$KHALA_BIN" inbox --drain; then
    :
else
    printf '%s\n' 'khala: inbox drain 실패 — 상세는 위 오류를 확인하세요' >&2
fi
khala_after=$(khala_count_files "$khala_new_dir")
khala_drained=$((khala_before - khala_after))
if [ "$khala_drained" -lt 0 ]; then
    khala_drained=0
fi

if khala_find_link_binary; then
    if khala_link_is_fresh; then
        :
    else
        if mkdir -p "$KHALA_ROOT/log"; then
            nohup "$KHALA_BIN" link </dev/null >> "$KHALA_ROOT/log/link.log" 2>&1 &
            printf 'khala: link ensure 시작 — 거부/오류는 %s/log/link.log에 남습니다\n' "$KHALA_ROOT"
        else
            printf 'khala: link ensure를 시작하지 못했습니다 — %s/log/link.log를 확인하세요\n' "$KHALA_ROOT"
        fi
    fi
else
    printf '%s\n' 'khala: khala-link 없음 — interval cadence로 동작합니다'
fi

khala_arm_command="KHALA_SESSION=$KHALA_RESOLVED_SESSION khala watch --session $KHALA_RESOLVED_SESSION --interval 30"
if khala_watch_is_fresh "$KHALA_RESOLVED_SESSION"; then
    printf 'khala: %s@%s — 편지 %s건 드레인, watch 무장됨 (pid %s)\n' \
        "$KHALA_RESOLVED_SESSION" "$KHALA_NODE" "$khala_drained" "$KHALA_WATCH_PID"
else
    printf 'khala: %s@%s — 편지 %s건 드레인, watch 미무장 — 다음으로 arm하라: (run_in_background) %s\n' \
        "$KHALA_RESOLVED_SESSION" "$KHALA_NODE" "$khala_drained" "$khala_arm_command"
fi
exit 0
