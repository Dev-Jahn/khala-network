# PostToolUse fast path for Claude Code subagents with a khala mailbox (see
# subagent.sh). It runs after every tool call of every session, so it uses
# shell builtins only: unless a subagent of this Claude Code process
# (CLAUDE_PID) waits to be bound or has mail to deliver, it exits 0 without
# output, without reading its input, and bash never starts. hooks.json sources
# it (`. tool-boundary.sh`) into the shell Claude Code starts for the hook, so
# that shell is the only process; `sh tool-boundary.sh` behaves the same.
p=${CLAUDE_PID-}
case $p in '' | *[!0-9]*) exit 0 ;; esac
h=${KHALA_HOME-${HOME-}/.khala}
d=$h/run/cc-subagents/$p
[ -d "$d" ] || exit 0
w=0 # a declaration waits for its subagent's first tool call
m=0 # a bound subagent has mail not yet found undeliverable (h.<agent> newer than the inbox)
for e in "$d"/*; do
  case ${e##*/} in
    p.*) w=1 ;;
    b.*)
      e=${e##*/b.}
      for f in "$h/inbox/${e#*.}/new"/*; do
        [ -e "$f" ] && ! [ "$d/h.${e%%.*}" -nt "$h/inbox/${e#*.}/new" ] && m=1
        break
      done
      ;;
  esac
done
[ "$w$m" != 00 ] || exit 0
# Claude Code writes the hook input as one JSON line; a subagent's tool call
# carries agent_id among the fields before tool_input.
IFS= read -r j || [ -n "$j" ] || exit 0
j=${j%%\"tool_input\":*}
case $j in *\"agent_id\":\"*) ;; *) exit 0 ;; esac
a=${j#*\"agent_id\":\"}
a=${a%%\"*}
case $a in '' | *[!0-9a-z]*) exit 0 ;; esac
for e in "$d/b.$a".*; do
  [ -e "$e" ] || break
  for f in "$h/inbox/${e##*/b.$a.}/new"/*; do
    [ -e "$f" ] && ! [ "$d/h.$a" -nt "$h/inbox/${e##*/b.$a.}/new" ] &&
      exec bash "${CLAUDE_PLUGIN_ROOT:-${0%/*}/..}/hooks/subagent.sh" PostToolUse "$j"
    break
  done
  exit 0
done
[ "$w" = 1 ] && ! [ -e "$d/n.$a" ] && exec bash "${CLAUDE_PLUGIN_ROOT:-${0%/*}/..}/hooks/subagent.sh" PostToolUse "$j"
exit 0
