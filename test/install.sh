#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL=$ROOT/install.sh
KHALA=$ROOT/bin/khala
START=$ROOT/plugin/hooks/session-start.sh
RIG=$ROOT/.install-test-$$
SHIM=$RIG/shim
RELEASE=$RIG/release
REAL_CURL=$(command -v curl)

cleanup() {
    rm -rf -- "$RIG"
}

fail() {
    printf 'FAIL %s — %s\n' "$1" "$2" >&2
    [ ! -d "$RIG" ] || find "$RIG" -maxdepth 4 -print | sort >&2
    exit 1
}

pass() {
    printf 'ok %s — %s\n' "$1" "$2"
}

file_mode() {
    install_mode=$(stat -c %a "$1" 2>/dev/null) || install_mode=
    if [ -n "$install_mode" ]; then
        printf '%s\n' "$install_mode"
        return 0
    fi
    stat -f %Lp "$1" 2>/dev/null
}

file_mtime() {
    install_mtime=$(stat -c %Y "$1" 2>/dev/null) || install_mtime=
    if [ -n "$install_mtime" ]; then
        printf '%s\n' "$install_mtime"
        return 0
    fi
    stat -f %m "$1" 2>/dev/null
}

line_count() {
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d ' '
    else
        printf '%s\n' 0
    fi
}

make_home() {
    install_home=$1
    mkdir -p "$install_home/.claude" || return 1
    printf '%s\n' \
        '{' \
        '  "theme": "dark",' \
        '  "nested": {' \
        '    "crossSessionInbound": "accept"' \
        '  },' \
        '  "crossSessionInbound": "prompt"' \
        '}' > "$install_home/.claude/settings.json"
}

run_install() {
    install_home=$1
    shift
    (
        unset KHALA_HOME KHALA_SESSION CLAUDE_PROJECT_DIR
        HOME=$install_home \
        PATH=$SHIM:/usr/bin:/bin \
        SHELL=/bin/sh \
        KHALA_TEST_ROOT=$ROOT \
        KHALA_TEST_CLAUDE_LOG=$install_home/claude.argv \
        KHALA_TEST_SSH_LOG=$install_home/ssh.argv \
        KHALA_TEST_SSH_STDIN=$install_home/ssh.stdin \
        KHALA_TEST_CURL_LOG=$install_home/curl.argv \
        KHALA_TEST_LINK_LOG=$install_home/link.argv \
        KHALA_LINK_RELEASE_BASE=file://$RELEASE \
        sh "$INSTALL" "$@"
    )
}

mkdir -p "$RIG" "$SHIM" "$RELEASE" || fail setup 'could not create rig directories'
trap cleanup EXIT HUP INT TERM

cat > "$SHIM/claude" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "$KHALA_TEST_CLAUDE_LOG"
if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
    printf '%s (Claude Code)\n' "${KHALA_TEST_CLAUDE_VERSION:-2.1.235}"
    exit 0
fi
if [ "$#" -ge 3 ] && [ "$1 $2" = 'plugin marketplace' ] && [ "$3" = add ]; then
    printf '%s\n' 'marketplace added'
    exit 0
fi
if [ "$#" -ge 3 ] && [ "$1 $2" = 'plugin install' ]; then
    cache=$HOME/.claude/plugins/cache/jahns-cc-marketplace/khala/0.7.0
    mkdir -p "$cache/bin"
    cp "$KHALA_TEST_ROOT/bin/khala" "$cache/bin/khala"
    cp "$KHALA_TEST_ROOT/plugin/install.sh" "$cache/install.sh"
    chmod 755 "$cache/bin/khala" "$cache/install.sh"
    if [ -f "$HOME/.claude/khala-installed" ]; then
        printf '%s\n' 'already installed' >&2
        exit 1
    fi
    : > "$HOME/.claude/khala-installed"
    printf '%s\n' 'plugin installed'
    exit 0
fi
if [ "$#" -ge 3 ] && [ "$1 $2" = 'plugin update' ]; then
    cache=$HOME/.claude/plugins/cache/jahns-cc-marketplace/khala/0.7.0
    mkdir -p "$cache/bin"
    cp "$KHALA_TEST_ROOT/bin/khala" "$cache/bin/khala"
    cp "$KHALA_TEST_ROOT/plugin/install.sh" "$cache/install.sh"
    chmod 755 "$cache/bin/khala" "$cache/install.sh"
    printf '%s\n' 'plugin updated'
    exit 0
fi
printf 'unexpected claude argv: %s\n' "$*" >&2
exit 64
EOF

cat > "$SHIM/ssh" <<'EOF'
#!/bin/sh
set -u
{
    printf 'ssh'
    for ssh_arg in "$@"; do
        printf '\t%s' "$ssh_arg"
    done
    printf '\n'
} >> "$KHALA_TEST_SSH_LOG"
case "$*" in
    *'sh -s -- --name'*)
        cat > "$KHALA_TEST_SSH_STDIN"
        printf '%s\n' 'remote installer complete'
        ;;
    *'khala status | head -1'*) printf '%s\n' 'runtime: remote-ready' ;;
    *'khala sync'*) printf '%s\n' 'sync complete' ;;
esac
exit 0
EOF

cat > "$SHIM/curl" <<EOF
#!/bin/sh
set -u
printf '%s\n' "\$*" >> "\$KHALA_TEST_CURL_LOG"
exec "$REAL_CURL" "\$@"
EOF

cat > "$RELEASE/khala-link-linux-amd64" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${KHALA_TEST_LINK_LOG:-/dev/null}"
if [ "${1-} ${2-}" = 'runtime daemon-status' ]; then
    link_root=${KHALA_HOME:-$HOME/.khala}
    mkdir -p "$link_root/run"
    printf 'pid %s\n' "$PPID" > "$link_root/run/link.status"
    exit 0
fi
if [ "${1-} ${2-}" = 'runtime status' ]; then
    printf '%s\n' 'runtime: ready'
    exit 0
fi
exit 0
EOF
chmod 755 "$SHIM/claude" "$SHIM/ssh" "$SHIM/curl" "$RELEASE/khala-link-linux-amd64"

cmp -s "$INSTALL" "$ROOT/plugin/install.sh" || fail setup 'plugin install.sh differs from root payload'
cmp -s "$KHALA" "$ROOT/plugin/bin/khala" || fail setup 'plugin CLI differs from root CLI'
sh -n "$INSTALL" || fail setup 'install.sh is not valid POSIX shell syntax'
bash -n "$KHALA" || fail setup 'bin/khala has invalid shell syntax'
bash -n "$START" || fail setup 'SessionStart hook has invalid shell syntax'

# 1. Bootstrap install.
BOOT_HOME=$RIG/bootstrap-home
make_home "$BOOT_HOME" || fail 1 'could not create bootstrap HOME'
run_install "$BOOT_HOME" --name hub --bootstrap > "$RIG/bootstrap.out" 2> "$RIG/bootstrap.err" || \
    fail 1 "bootstrap failed: $(tr '\n' ' ' < "$RIG/bootstrap.err")"
printf '%s\n' 'self hub' 'mailbox hub' 'ttl 120' > "$RIG/bootstrap.expected"
cmp -s "$RIG/bootstrap.expected" "$BOOT_HOME/.khala/config" || fail 1 'bootstrap config bytes differ'
[ -x "$BOOT_HOME/.khala/bin/khala-link" ] || fail 1 'khala-link was not installed executable'
[ "$(file_mode "$BOOT_HOME/.khala/bin/khala-link")" = 755 ] || fail 1 'khala-link mode is not 755'
grep -q '^runtime daemon-status$' "$BOOT_HOME/link.argv" || fail 1 'node ensure did not consult khala-link'
grep -q '^runtime status$' "$BOOT_HOME/link.argv" || fail 1 'verification did not run khala status'
grep -Eq '"crossSessionInbound"[[:space:]]*:[[:space:]]*"accept"' \
    "$BOOT_HOME/.claude/settings.json" || fail 1 'crossSessionInbound was not set to accept'
printf '%s\n' \
    '{' \
    '  "theme": "dark",' \
    '  "nested": {' \
    '    "crossSessionInbound": "accept"' \
    '  },' \
    '  "crossSessionInbound": "accept"' \
    '}' \
    > "$RIG/settings.expected"
cmp -s "$RIG/settings.expected" "$BOOT_HOME/.claude/settings.json" || \
    fail 1 'settings.json edit did not preserve the existing top-level setting'
BOOT_SETTINGS_BACKUP=
for install_backup in "$BOOT_HOME/.claude"/settings.json.khala-backup.*; do
    [ -f "$install_backup" ] || continue
    BOOT_SETTINGS_BACKUP=$install_backup
done
[ -n "$BOOT_SETTINGS_BACKUP" ] || fail 1 'settings.json backup was not created'
printf '%s\n' \
    '{' \
    '  "theme": "dark",' \
    '  "nested": {' \
    '    "crossSessionInbound": "accept"' \
    '  },' \
    '  "crossSessionInbound": "prompt"' \
    '}' > "$RIG/settings.original"
cmp -s "$RIG/settings.original" "$BOOT_SETTINGS_BACKUP" || fail 1 'settings.json backup bytes differ'
grep -q '^Khala installation complete:$' "$RIG/bootstrap.out" || fail 1 'summary block is missing'
grep -q 'put a session name in .khala-session' "$RIG/bootstrap.out" || fail 1 'session next step is missing'
pass 1 'bootstrap writes exact config, installs mode-755 link, ensures node, sets accept, and summarizes'

# 2. Join install.
JOIN_HOME=$RIG/join-home
make_home "$JOIN_HOME" || fail 2 'could not create join HOME'
run_install "$JOIN_HOME" --name laptop --mailbox hub user@hub \
    > "$RIG/join.out" 2> "$RIG/join.err" || \
    fail 2 "join failed: $(tr '\n' ' ' < "$RIG/join.err")"
printf '%s\n' 'self laptop' 'peer hub user@hub' 'mailbox hub' 'ttl 120' > "$RIG/join.expected"
cmp -s "$RIG/join.expected" "$JOIN_HOME/.khala/config" || fail 2 'join config bytes differ'
grep -F $'ssh\t-o\tBatchMode=yes\t-o\tConnectTimeout=8\tuser@hub\ttrue' \
    "$JOIN_HOME/ssh.argv" >/dev/null || fail 2 'join reachability probe argv differ'
pass 2 'join writes exact peer/mailbox config and probes the mailbox without blocking install'

# 3. Idempotent rerun.
BOOT_CONFIG_SUM=$(cksum "$BOOT_HOME/.khala/config")
BOOT_CONFIG_MTIME=$(file_mtime "$BOOT_HOME/.khala/config")
BOOT_CURL_COUNT=$(line_count "$BOOT_HOME/curl.argv")
run_install "$BOOT_HOME" --name hub --bootstrap > "$RIG/rerun.out" 2> "$RIG/rerun.err" || \
    fail 3 "idempotent rerun failed: $(tr '\n' ' ' < "$RIG/rerun.err")"
[ "$(cksum "$BOOT_HOME/.khala/config")" = "$BOOT_CONFIG_SUM" ] || fail 3 'rerun changed config content'
[ "$(file_mtime "$BOOT_HOME/.khala/config")" = "$BOOT_CONFIG_MTIME" ] || fail 3 'rerun changed config mtime'
[ "$(line_count "$BOOT_HOME/curl.argv")" = "$BOOT_CURL_COUNT" ] || fail 3 'rerun downloaded khala-link again'
grep -q 'already initialized' "$RIG/rerun.out" || fail 3 'rerun omitted initialized notice'
grep -q 'config already matches' "$RIG/rerun.out" || fail 3 'rerun omitted matching config notice'
grep -q 'khala-link already installed' "$RIG/rerun.out" || fail 3 'rerun omitted link notice'
pass 3 'rerun is idempotent, leaves config bytes/mtime untouched, and does not refetch'

run_install "$BOOT_HOME" --name hub --bootstrap --fix-path \
    > "$RIG/fix-path.out" 2> "$RIG/fix-path.err" || fail 3 'explicit --fix-path rerun failed'
grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$BOOT_HOME/.profile" || \
    fail 3 '--fix-path did not append the exact PATH export'
pass 3b '--fix-path alone opts into a shell startup edit'

# 4. Existing config conflict.
CONFLICT_HOME=$RIG/conflict-home
make_home "$CONFLICT_HOME" || fail 4 'could not create conflict HOME'
mkdir -p "$CONFLICT_HOME/.khala"
printf '%s\n' 'self other' 'mailbox other' 'ttl 999' > "$CONFLICT_HOME/.khala/config"
CONFLICT_SUM=$(cksum "$CONFLICT_HOME/.khala/config")
if run_install "$CONFLICT_HOME" --name hub --bootstrap \
    > "$RIG/conflict.out" 2> "$RIG/conflict.err"; then
    fail 4 'conflicting config unexpectedly succeeded'
fi
[ "$(cksum "$CONFLICT_HOME/.khala/config")" = "$CONFLICT_SUM" ] || fail 4 'conflicting config was modified'
grep -q '^--- ~/.khala/config (existing)$' "$RIG/conflict.err" || fail 4 'conflict omitted diff-style notice'
grep -q 'refusing to overwrite' "$RIG/conflict.err" || fail 4 'conflict omitted refusal reason'
pass 4 'conflicting config fails with a diff-style notice and remains byte-identical'

# 5. Claude Code preflight.
MISSING_HOME=$RIG/missing-claude-home
mkdir -p "$MISSING_HOME"
if HOME=$MISSING_HOME PATH=/usr/bin:/bin sh "$INSTALL" --name hub --bootstrap \
    > "$RIG/missing.out" 2> "$RIG/missing.err"; then
    fail 5 'missing Claude Code unexpectedly succeeded'
fi
grep -q 'Claude Code 2.1.229 or newer is required' "$RIG/missing.err" || \
    fail 5 'missing Claude Code error lacks install/update pointer'
pass 5 'missing Claude Code fails before touching node state with a concise version pointer'

OLD_HOME=$RIG/old-claude-home
mkdir -p "$OLD_HOME"
if HOME=$OLD_HOME PATH=$SHIM:/usr/bin:/bin KHALA_TEST_CLAUDE_VERSION=2.1.228 \
    KHALA_TEST_CLAUDE_LOG=$OLD_HOME/claude.argv sh "$INSTALL" --name hub --bootstrap \
    > "$RIG/old.out" 2> "$RIG/old.err"; then
    fail 5 'old Claude Code unexpectedly succeeded'
fi
grep -q 'Claude Code 2.1.228 is too old' "$RIG/old.err" || fail 5 'old-version error lacks detected version'
grep -q '2.1.229 or newer' "$RIG/old.err" || fail 5 'old-version error lacks required version'
pass 5a 'Claude Code below 2.1.229 fails with detected and required versions'

# Preflight also refuses a host with neither downloader.
NODL_SHIM=$RIG/no-downloader-shim
mkdir -p "$NODL_SHIM"
ln -s "$SHIM/claude" "$NODL_SHIM/claude"
for install_tool in awk grep head sed; do
    ln -s "$(command -v "$install_tool")" "$NODL_SHIM/$install_tool"
done
NODL_HOME=$RIG/no-downloader-home
mkdir -p "$NODL_HOME"
if HOME=$NODL_HOME PATH=$NODL_SHIM KHALA_TEST_CLAUDE_LOG=$NODL_HOME/claude.argv \
    /bin/sh "$INSTALL" --name hub --bootstrap > "$RIG/nodl.out" 2> "$RIG/nodl.err"; then
    fail 5 'missing curl/wget unexpectedly succeeded'
fi
grep -q 'curl or wget is required' "$RIG/nodl.err" || fail 5 'missing downloader reason is unclear'
pass 5b 'missing curl and wget fails explicitly'

# 6. Unsupported architecture.
BAD_SHIM=$RIG/bad-arch-shim
mkdir -p "$BAD_SHIM"
cat > "$BAD_SHIM/uname" <<'EOF'
#!/bin/sh
case "${1-}" in
    -s) printf '%s\n' Linux ;;
    -m) printf '%s\n' mips64 ;;
    *) printf '%s\n' Linux ;;
esac
EOF
chmod 755 "$BAD_SHIM/uname"
BAD_HOME=$RIG/bad-arch-home
make_home "$BAD_HOME" || fail 6 'could not create unsupported-arch HOME'
if (
    unset KHALA_HOME
    HOME=$BAD_HOME PATH=$BAD_SHIM:$SHIM:/usr/bin:/bin SHELL=/bin/sh \
        KHALA_TEST_ROOT=$ROOT KHALA_TEST_CLAUDE_LOG=$BAD_HOME/claude.argv \
        KHALA_TEST_SSH_LOG=$BAD_HOME/ssh.argv KHALA_TEST_SSH_STDIN=$BAD_HOME/ssh.stdin \
        KHALA_TEST_CURL_LOG=$BAD_HOME/curl.argv KHALA_TEST_LINK_LOG=$BAD_HOME/link.argv \
        KHALA_LINK_RELEASE_BASE=file://$RELEASE sh "$INSTALL" --name hub --bootstrap
) > "$RIG/bad-arch.out" 2> "$RIG/bad-arch.err"; then
    fail 6 'unsupported architecture unexpectedly succeeded'
fi
grep -q 'unsupported architecture: mips64' "$RIG/bad-arch.err" || fail 6 'architecture error is unclear'
pass 6 'unsupported architecture fails loudly before a release request'

# 7. Invite streams the bundled installer, checks status/sync, and refuses aliases.
INVITE_HOME=$RIG/invite-home
INVITE_KHALA_HOME=$INVITE_HOME/.khala
mkdir -p "$INVITE_KHALA_HOME/tmp" "$INVITE_HOME/.claude/plugins/cache/jahns-cc-marketplace/khala/0.7.0"
printf '%s\n' 'self alpha' 'peer hub user@hub' 'mailbox hub' 'ttl 120' > "$INVITE_KHALA_HOME/config"
cp "$ROOT/plugin/install.sh" "$INVITE_HOME/.claude/plugins/cache/jahns-cc-marketplace/khala/0.7.0/install.sh"
: > "$INVITE_HOME/ssh.argv"
HOME=$INVITE_HOME KHALA_HOME=$INVITE_KHALA_HOME PATH=$SHIM:/usr/bin:/bin \
    KHALA_TEST_SSH_LOG=$INVITE_HOME/ssh.argv KHALA_TEST_SSH_STDIN=$INVITE_HOME/ssh.stdin \
    "$KHALA" invite new@node --name beta > "$RIG/invite.out" 2> "$RIG/invite.err" || \
    fail 7 "portable invite failed: $(tr '\n' ' ' < "$RIG/invite.err")"
[ "$(line_count "$INVITE_HOME/ssh.argv")" -eq 3 ] || fail 7 'invite did not make install/status/sync SSH calls'
grep -F $'ssh\tnew@node\tsh -s -- --name '\''beta'\'' --mailbox '\''hub'\'' '\''user@hub'\''' \
    "$INVITE_HOME/ssh.argv" >/dev/null || fail 7 'remote install SSH argv differ'
grep -F $'ssh\tnew@node\t~/.local/bin/khala status | head -1' "$INVITE_HOME/ssh.argv" >/dev/null || \
    fail 7 'remote status call is missing'
grep -F $'ssh\tnew@node\t~/.local/bin/khala sync' "$INVITE_HOME/ssh.argv" >/dev/null || \
    fail 7 'remote sync call is missing'
cmp -s "$INSTALL" "$INVITE_HOME/ssh.stdin" || fail 7 'piped invite stdin differs from install.sh'
grep -q 'presence 행은 그 노드에서 세션을 연 뒤' "$RIG/invite.out" || \
    fail 7 'invite overclaimed membership or omitted the presence caveat'

printf '%s\n' 'self alpha' 'peer hub mini-t' 'mailbox hub' 'ttl 120' > "$INVITE_KHALA_HOME/config"
: > "$INVITE_HOME/ssh.argv"
if HOME=$INVITE_HOME KHALA_HOME=$INVITE_KHALA_HOME PATH=$SHIM:/usr/bin:/bin \
    KHALA_TEST_SSH_LOG=$INVITE_HOME/ssh.argv KHALA_TEST_SSH_STDIN=$INVITE_HOME/ssh.stdin \
    "$KHALA" invite new@node --name gamma > "$RIG/invite-alias.out" 2> "$RIG/invite-alias.err"; then
    fail 7 'non-portable mailbox alias unexpectedly succeeded'
fi
[ ! -s "$INVITE_HOME/ssh.argv" ] || fail 7 'non-portable alias attempted SSH'
grep -q -- '--mailbox-coord <user@host>' "$RIG/invite-alias.err" || \
    fail 7 'non-portable alias refusal omitted the explicit override'
if HOME=$INVITE_HOME KHALA_HOME=$INVITE_KHALA_HOME "$KHALA" invite \
    > "$RIG/invite-usage.out" 2> "$RIG/invite-usage.err"; then
    fail 7 'argument-free invite unexpectedly succeeded'
fi
grep -q '^usage: khala invite ' "$RIG/invite-usage.out" || fail 7 'argument-free invite omitted usage'
pass 7 'invite streams exact payload, runs status/sync, states presence limit, and rejects local aliases'

# 8. SessionStart detached autofetch.
HOOK_HOME=$RIG/hook-home
HOOK_KHALA_HOME=$HOOK_HOME/.khala
HOOK_PROJECT=$RIG/hook-project
mkdir -p "$HOOK_HOME" "$HOOK_PROJECT"
KHALA_HOME=$HOOK_KHALA_HOME "$KHALA" init hooknode >/dev/null || fail 8 'could not init hook fixture'
: > "$HOOK_HOME/curl.argv"
HOME=$HOOK_HOME KHALA_HOME=$HOOK_KHALA_HOME CLAUDE_PROJECT_DIR=$HOOK_PROJECT \
    PATH=$SHIM:$ROOT/bin:/usr/bin:/bin KHALA_TEST_CURL_LOG=$HOOK_HOME/curl.argv \
    KHALA_LINK_RELEASE_BASE=file://$RELEASE "$START" < /dev/null \
    > "$RIG/hook-fetch.out" 2> "$RIG/hook-fetch.err" || fail 8 'autofetch hook invocation failed'
[ "$(grep -c 'khala-link autofetch launched' "$RIG/hook-fetch.out")" -eq 1 ] || \
    fail 8 'missing binary did not emit exactly one launch line'
hook_wait=0
while [ ! -x "$HOOK_KHALA_HOME/bin/khala-link" ] && [ "$hook_wait" -lt 50 ]; do
    sleep 0.1
    hook_wait=$((hook_wait + 1))
done
[ -x "$HOOK_KHALA_HOME/bin/khala-link" ] || fail 8 'detached autofetch did not finish within five seconds'
cmp -s "$RELEASE/khala-link-linux-amd64" "$HOOK_KHALA_HOME/bin/khala-link" || \
    fail 8 'autofetched binary bytes differ from release asset'
HOOK_CURL_COUNT=$(line_count "$HOOK_HOME/curl.argv")
HOME=$HOOK_HOME KHALA_HOME=$HOOK_KHALA_HOME CLAUDE_PROJECT_DIR=$HOOK_PROJECT \
    PATH=$SHIM:$ROOT/bin:/usr/bin:/bin KHALA_TEST_CURL_LOG=$HOOK_HOME/curl.argv \
    KHALA_LINK_RELEASE_BASE=file://$RIG/does-not-exist "$START" < /dev/null \
    > "$RIG/hook-present.out" 2> "$RIG/hook-present.err" || fail 8 'present-binary hook invocation failed'
[ "$(line_count "$HOOK_HOME/curl.argv")" = "$HOOK_CURL_COUNT" ] || fail 8 'present binary triggered a release request'
grep -q 'khala-link autofetch' "$RIG/hook-present.out" && fail 8 'present binary emitted an autofetch line'
pass 8 'SessionStart launches detached autofetch once, installs it promptly, and never touches an existing binary'

printf '%s\n' 'RESULT: PASS'
