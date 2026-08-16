#!/usr/bin/env bash
# SessionEnd cleanup is an optimization; conduit pid/start/socket validation is authoritative.
set -u

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
. "$HOOK_DIR/lib.sh"

khala_end_input=$(cat 2>/dev/null) || khala_end_input=
khala_discover || exit 0
khala_end_session_id=$(printf '%s\n' "$khala_end_input" | tr '\n' ' ' | \
    sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')
khala_resolve_session 0 0 || KHALA_RESOLVED_SESSION=
KHALA_SESSION="$KHALA_RESOLVED_SESSION" "$KHALA_BIN" bind --release \
    --session-id "$khala_end_session_id" >/dev/null 2>&1 || :
exit 0
