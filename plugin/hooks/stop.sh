#!/usr/bin/env bash
# Record only that the resolved session completed a turn. The node conduit owns
# delivery; this hook never drains mail, calls the CLI, or signals a process.
set -u

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
. "$HOOK_DIR/lib.sh"

khala_stop_input=$(cat 2>/dev/null) || khala_stop_input=
khala_stop_active=$(printf '%s\n' "$khala_stop_input" | tr '\n' ' ' | \
    sed -n 's/.*"stop_hook_active"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
[ "$khala_stop_active" != true ] || exit 0

khala_discover || exit 0
khala_resolve_session 0 0 || exit 0
khala_turn_epoch=$(date +%s 2>/dev/null) || exit 0

umask 077
mkdir -p "$KHALA_ROOT/run" "$KHALA_ROOT/run/turns" "$KHALA_ROOT/tmp" 2>/dev/null || exit 0
chmod 700 "$KHALA_ROOT/run" "$KHALA_ROOT/run/turns" 2>/dev/null || exit 0
khala_turn_tmp=$KHALA_ROOT/tmp/turn.$$.${RANDOM-0}
if printf 'turn 1 %s\n' "$khala_turn_epoch" > "$khala_turn_tmp" 2>/dev/null && \
    chmod 600 "$khala_turn_tmp" 2>/dev/null && \
    mv -f "$khala_turn_tmp" "$KHALA_ROOT/run/turns/$KHALA_RESOLVED_SESSION" 2>/dev/null; then
    exit 0
fi
rm -f "$khala_turn_tmp" 2>/dev/null
exit 0
