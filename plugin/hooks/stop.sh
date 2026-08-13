#!/usr/bin/env bash
# R13 boundary: read/write only KHALA_HOME and emit hook output. No tmux,
# kill, signal, or input-lane injection; this hook never controls a peer.
set -u

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
. "$HOOK_DIR/lib.sh"

khala_stop_input=$(cat 2>/dev/null) || khala_stop_input=
if printf '%s\n' "$khala_stop_input" | tr '\n' ' ' | \
    grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    exit 0
fi

khala_discover || exit 0
khala_resolve_session 0 0 || exit 0
khala_watch_is_fresh "$KHALA_RESOLVED_SESSION" && exit 0

printf '{"decision": "block", "reason": "khala 귀가 내려가 있다 (%s). run_in_background로 재무장 후 종료하라: KHALA_SESSION=%s khala watch --session %s --interval 30 — 재무장 불가 사유가 있으면 그 사유를 한 줄 남기고 종료해도 된다."}\n' \
    "$KHALA_RESOLVED_SESSION" "$KHALA_RESOLVED_SESSION" "$KHALA_RESOLVED_SESSION"
exit 0
