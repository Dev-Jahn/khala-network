#!/bin/sh
# Khala one-click node installer (POSIX sh; macOS and Linux).
# Test-only: KHALA_LINK_RELEASE_BASE replaces the GitHub release base URL.
set -u

umask 077

KHALA_MIN_CLAUDE_VERSION=2.1.229
KHALA_MARKETPLACE=Dev-Jahn/jahns-cc-marketplace
KHALA_PLUGIN=khala@jahns-cc-marketplace
KHALA_NAME=
KHALA_MAILBOX_NAME=
KHALA_MAILBOX_COORD=
KHALA_BOOTSTRAP=0
KHALA_FIX_PATH=0

khala_install_say() {
    printf 'khala install: %s\n' "$*"
}

khala_install_fail() {
    printf 'khala install: ERROR: %s\n' "$*" >&2
    exit 1
}

khala_install_usage() {
    cat >&2 <<'EOF'
usage:
  install.sh --name <node> --mailbox <mailbox-name> <mailbox-coordinate> [--fix-path]
  install.sh --name <node> --bootstrap [--fix-path]
EOF
}

khala_install_valid_name() {
    printf '%s\n' "$1" | grep -q '^[a-z0-9][a-z0-9-]*$'
}

khala_install_version_at_least() {
    awk -v have="$1" -v need="$2" 'BEGIN {
        have_n = split(have, have_parts, ".")
        need_n = split(need, need_parts, ".")
        count = have_n > need_n ? have_n : need_n
        for (i = 1; i <= count; i++) {
            have_part = i <= have_n ? have_parts[i] + 0 : 0
            need_part = i <= need_n ? need_parts[i] + 0 : 0
            if (have_part > need_part) exit 0
            if (have_part < need_part) exit 1
        }
        exit 0
    }'
}

khala_install_version_newer() {
    [ "$1" != "$2" ] && khala_install_version_at_least "$1" "$2"
}

khala_install_show_config_conflict() {
    printf '%s\n' 'khala install: ERROR: existing ~/.khala/config differs; refusing to overwrite it' >&2
    printf '%s\n' '--- ~/.khala/config (existing)' '+++ requested config' >&2
    sed 's/^/- /' "$KHALA_CONFIG" >&2
    sed 's/^/+ /' "$KHALA_DESIRED_CONFIG" >&2
    exit 1
}

khala_install_cross_session_state() {
    awk '
        function scan(text, i, character) {
            for (i = 1; i <= length(text); i++) {
                character = substr(text, i, 1)
                if (in_string) {
                    if (escaped) escaped = 0
                    else if (character == "\\") escaped = 1
                    else if (character == "\"") in_string = 0
                } else if (character == "\"") in_string = 1
                else if (character == "{" || character == "[") depth++
                else if (character == "}" || character == "]") depth--
                if (depth < 0) invalid = 1
            }
        }
        {
            if (depth == 1 && $0 ~ /^[[:space:]]*"crossSessionInbound"[[:space:]]*:/) {
                count++
                if ($0 ~ /^[[:space:]]*"crossSessionInbound"[[:space:]]*:[[:space:]]*"accept"[[:space:]]*,?[[:space:]]*$/) accepted++
            }
            scan($0)
        }
        END {
            valid = !invalid && !in_string && depth == 0
            printf "%d %d %d\n", count, accepted, valid
        }
    ' "$1"
}

khala_install_replace_cross_session() {
    awk '
        function scan(text, i, character) {
            for (i = 1; i <= length(text); i++) {
                character = substr(text, i, 1)
                if (in_string) {
                    if (escaped) escaped = 0
                    else if (character == "\\") escaped = 1
                    else if (character == "\"") in_string = 0
                } else if (character == "\"") in_string = 1
                else if (character == "{" || character == "[") depth++
                else if (character == "}" || character == "]") depth--
            }
        }
        {
            if (depth == 1 && $0 ~ /^[[:space:]]*"crossSessionInbound"[[:space:]]*:/) {
                if ($0 !~ /^[[:space:]]*"crossSessionInbound"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) exit 2
                sub(/"crossSessionInbound"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"crossSessionInbound\": \"accept\"")
                replaced++
            }
            print
            scan($0)
        }
        END { if (replaced != 1) exit 3 }
    ' "$1"
}

khala_install_set_cross_session() {
    khala_settings_dir=$HOME/.claude
    khala_settings=$khala_settings_dir/settings.json
    khala_settings_tmp=$khala_settings_dir/.settings.json.khala.$$
    if [ -f "$khala_settings" ]; then
        set -- $(khala_install_cross_session_state "$khala_settings")
        khala_cross_count=${1-0}
        khala_cross_accepted=${2-0}
        khala_settings_valid=${3-0}
        if [ "$khala_settings_valid" -ne 1 ]; then
            khala_install_fail 'settings.json is not a balanced JSON object; refusing to edit it'
        fi
        if [ "$khala_cross_count" -eq 1 ] && [ "$khala_cross_accepted" -eq 1 ]; then
            khala_install_say 'crossSessionInbound already accepts cross-session messages'
            return 0
        fi
    fi
    mkdir -p "$khala_settings_dir" || \
        khala_install_fail "cannot create $khala_settings_dir"

    if [ ! -e "$khala_settings" ]; then
        if ! printf '%s\n' '{' '  "crossSessionInbound": "accept"' '}' > "$khala_settings_tmp" || \
            ! mv "$khala_settings_tmp" "$khala_settings"; then
            rm -f "$khala_settings_tmp"
            khala_install_fail "cannot create $khala_settings"
        fi
        set -- $(khala_install_cross_session_state "$khala_settings")
        if [ "${1-0}" -ne 1 ] || [ "${2-0}" -ne 1 ] || [ "${3-0}" -ne 1 ]; then
            khala_install_fail 'crossSessionInbound verification failed after creating settings.json'
        fi
        khala_install_say 'set crossSessionInbound=accept in new ~/.claude/settings.json and verified it'
        return 0
    fi
    [ -f "$khala_settings" ] || khala_install_fail "$khala_settings is not a regular file"

    khala_settings_backup=$khala_settings.khala-backup.$$
    cp "$khala_settings" "$khala_settings_backup" || \
        khala_install_fail "cannot back up settings.json to $khala_settings_backup"

    if [ "$khala_cross_count" -gt 0 ]; then
        if [ "$khala_cross_count" -ne 1 ]; then
            khala_install_fail 'settings.json has a crossSessionInbound shape that cannot be edited safely without jq; backup was kept'
        fi
        if ! khala_install_replace_cross_session "$khala_settings" > "$khala_settings_tmp" || \
            ! mv "$khala_settings_tmp" "$khala_settings"; then
            rm -f "$khala_settings_tmp"
            khala_install_fail 'could not update crossSessionInbound; backup was kept'
        fi
    else
        khala_compact_settings=$(tr -d '[:space:]' < "$khala_settings")
        if [ "$khala_compact_settings" = '{}' ]; then
            if ! printf '%s\n' '{' '  "crossSessionInbound": "accept"' '}' > "$khala_settings_tmp" || \
                ! mv "$khala_settings_tmp" "$khala_settings"; then
                rm -f "$khala_settings_tmp"
                khala_install_fail 'could not update empty settings.json; backup was kept'
            fi
        else
            if ! awk '
                { line[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
                END {
                    if (line[last] !~ /^[[:space:]]*}[[:space:]]*$/) exit 2
                    previous = last - 1
                    while (previous > 0 && line[previous] !~ /[^[:space:]]/) previous--
                    for (i = 1; i < last; i++) {
                        if (i == previous && line[i] !~ /,[[:space:]]*$/ && line[i] !~ /{[[:space:]]*$/) {
                            print line[i] ","
                        } else {
                            print line[i]
                        }
                    }
                    print "  \"crossSessionInbound\": \"accept\""
                    print line[last]
                    for (i = last + 1; i <= NR; i++) print line[i]
                }
            ' "$khala_settings" > "$khala_settings_tmp"; then
                rm -f "$khala_settings_tmp"
                khala_install_fail 'settings.json is not a safely editable top-level JSON object; backup was kept'
            fi
            if ! mv "$khala_settings_tmp" "$khala_settings"; then
                rm -f "$khala_settings_tmp"
                khala_install_fail 'could not install updated settings.json; backup was kept'
            fi
        fi
    fi

    set -- $(khala_install_cross_session_state "$khala_settings")
    if [ "${1-0}" -ne 1 ] || [ "${2-0}" -ne 1 ] || [ "${3-0}" -ne 1 ]; then
        khala_install_fail 'crossSessionInbound verification failed; restore the reported backup'
    fi
    khala_install_say "set crossSessionInbound=accept, verified it, and backed up settings.json to $khala_settings_backup"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            [ "$#" -ge 2 ] || { khala_install_usage; khala_install_fail '--name needs a value'; }
            KHALA_NAME=$2
            shift 2
            ;;
        --mailbox)
            [ "$#" -ge 3 ] || { khala_install_usage; khala_install_fail '--mailbox needs a name and coordinate'; }
            KHALA_MAILBOX_NAME=$2
            KHALA_MAILBOX_COORD=$3
            shift 3
            ;;
        --bootstrap)
            KHALA_BOOTSTRAP=1
            shift
            ;;
        --fix-path)
            KHALA_FIX_PATH=1
            shift
            ;;
        -h|--help)
            khala_install_usage
            exit 0
            ;;
        *)
            khala_install_usage
            khala_install_fail "unknown argument: $1"
            ;;
    esac
done

[ -n "${HOME-}" ] || khala_install_fail 'HOME is not set'
[ -n "$KHALA_NAME" ] || { khala_install_usage; khala_install_fail '--name is required'; }
khala_install_valid_name "$KHALA_NAME" || khala_install_fail "invalid node name: $KHALA_NAME"
if [ "$KHALA_BOOTSTRAP" -eq 1 ]; then
    [ -z "$KHALA_MAILBOX_NAME" ] && [ -z "$KHALA_MAILBOX_COORD" ] || \
        khala_install_fail '--bootstrap and --mailbox cannot be used together'
else
    [ -n "$KHALA_MAILBOX_NAME" ] && [ -n "$KHALA_MAILBOX_COORD" ] || {
        khala_install_usage
        khala_install_fail 'choose --bootstrap or provide --mailbox <name> <coordinate>'
    }
    khala_install_valid_name "$KHALA_MAILBOX_NAME" || \
        khala_install_fail "invalid mailbox name: $KHALA_MAILBOX_NAME"
    case "$KHALA_MAILBOX_COORD" in
        *[[:space:]]*) khala_install_fail 'mailbox coordinate must be one whitespace-free config token' ;;
    esac
fi

command -v claude >/dev/null 2>&1 || \
    khala_install_fail "Claude Code $KHALA_MIN_CLAUDE_VERSION or newer is required; install or update Claude Code, then retry"
khala_claude_output=$(claude --version 2>&1) || \
    khala_install_fail 'could not read the Claude Code version'
khala_claude_version=$(printf '%s\n' "$khala_claude_output" | \
    sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$khala_claude_version" ] || \
    khala_install_fail "could not parse Claude Code version from: $khala_claude_output"
khala_install_version_at_least "$khala_claude_version" "$KHALA_MIN_CLAUDE_VERSION" || \
    khala_install_fail "Claude Code $khala_claude_version is too old; install $KHALA_MIN_CLAUDE_VERSION or newer, then retry"
khala_install_say "Claude Code $khala_claude_version satisfies the $KHALA_MIN_CLAUDE_VERSION minimum"

if command -v curl >/dev/null 2>&1; then
    KHALA_DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then
    KHALA_DOWNLOADER=wget
else
    khala_install_fail 'curl or wget is required to download khala-link'
fi
khala_install_say "using $KHALA_DOWNLOADER for release downloads"

if [ "$KHALA_BOOTSTRAP" -eq 0 ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$KHALA_MAILBOX_COORD" true </dev/null >/dev/null 2>&1; then
        khala_install_say "mailbox $KHALA_MAILBOX_COORD is reachable over batch SSH"
    else
        printf 'khala install: WARNING: mailbox %s is unreachable right now; installation continues and sync will retry\n' \
            "$KHALA_MAILBOX_COORD" >&2
    fi
fi

KHALA_INSTALL_TMP=$HOME/.khala/tmp
mkdir -p "$KHALA_INSTALL_TMP" || khala_install_fail "cannot create $KHALA_INSTALL_TMP"
KHALA_CLAUDE_LOG=$KHALA_INSTALL_TMP/claude-plugin.$$
khala_install_cleanup() {
    rm -f "$KHALA_CLAUDE_LOG" "$KHALA_INSTALL_TMP/config.requested.$$"
}
trap khala_install_cleanup 0
trap 'exit 1' HUP INT TERM

if claude plugin marketplace add "$KHALA_MARKETPLACE" > "$KHALA_CLAUDE_LOG" 2>&1; then
    if grep -Eqi 'already (exists|added)' "$KHALA_CLAUDE_LOG"; then
        khala_install_say 'Claude plugin marketplace already added'
    else
        khala_install_say 'added the Khala Claude plugin marketplace'
    fi
elif grep -Eqi 'already (exists|added)' "$KHALA_CLAUDE_LOG"; then
    khala_install_say 'Claude plugin marketplace already added'
else
    khala_install_fail 'Claude plugin marketplace add failed'
fi

khala_plugin_was_installed=0
if claude plugin install "$KHALA_PLUGIN" > "$KHALA_CLAUDE_LOG" 2>&1; then
    if grep -Eqi 'already installed' "$KHALA_CLAUDE_LOG"; then
        khala_plugin_was_installed=1
    else
        khala_install_say 'installed the Khala Claude plugin'
    fi
elif grep -Eqi 'already installed' "$KHALA_CLAUDE_LOG"; then
    khala_plugin_was_installed=1
else
    khala_install_fail 'Khala Claude plugin install failed'
fi
if [ "$khala_plugin_was_installed" -eq 1 ]; then
    if ! claude plugin update "$KHALA_PLUGIN" > "$KHALA_CLAUDE_LOG" 2>&1; then
        khala_install_fail 'Khala Claude plugin update failed'
    fi
    khala_install_say 'updated the already installed Khala Claude plugin'
fi

KHALA_CACHE_ROOT=$HOME/.claude/plugins/cache/jahns-cc-marketplace/khala
KHALA_PLUGIN_VERSION=
KHALA_PLUGIN_CLI=
for khala_cache_cli in "$KHALA_CACHE_ROOT"/*/bin/khala; do
    [ -f "$khala_cache_cli" ] || continue
    khala_cache_version=$(basename "$(dirname "$(dirname "$khala_cache_cli")")")
    printf '%s\n' "$khala_cache_version" | grep -Eq '^[0-9][0-9.]*$' || continue
    if [ -z "$KHALA_PLUGIN_VERSION" ] || \
        khala_install_version_newer "$khala_cache_version" "$KHALA_PLUGIN_VERSION"; then
        KHALA_PLUGIN_VERSION=$khala_cache_version
        KHALA_PLUGIN_CLI=$khala_cache_cli
    fi
done
[ -n "$KHALA_PLUGIN_CLI" ] || \
    khala_install_fail "no installed Khala CLI found under $KHALA_CACHE_ROOT"

KHALA_LOCAL_BIN=$HOME/.local/bin
KHALA_CLI=$KHALA_LOCAL_BIN/khala
mkdir -p "$KHALA_LOCAL_BIN" || khala_install_fail "cannot create $KHALA_LOCAL_BIN"
if [ -f "$KHALA_CLI" ] && cmp -s "$KHALA_PLUGIN_CLI" "$KHALA_CLI"; then
    khala_install_say "Khala CLI already installed at $KHALA_CLI"
else
    KHALA_CLI_TMP=$KHALA_LOCAL_BIN/.khala.install.$$
    if ! cp "$KHALA_PLUGIN_CLI" "$KHALA_CLI_TMP" || ! chmod 755 "$KHALA_CLI_TMP" || \
        ! mv "$KHALA_CLI_TMP" "$KHALA_CLI"; then
        rm -f "$KHALA_CLI_TMP"
        khala_install_fail "cannot install $KHALA_CLI"
    fi
    khala_install_say "installed Khala CLI $KHALA_PLUGIN_VERSION at $KHALA_CLI"
fi

case ":${PATH-}:" in
    *":$KHALA_LOCAL_BIN:"*) khala_install_say '~/.local/bin is already on PATH' ;;
    *)
        if [ "$KHALA_FIX_PATH" -eq 1 ]; then
            case "${SHELL-}" in
                */zsh) KHALA_PATH_FILE=$HOME/.zshenv ;;
                *) KHALA_PATH_FILE=$HOME/.profile ;;
            esac
            KHALA_PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
            if [ -f "$KHALA_PATH_FILE" ] && grep -Fqx "$KHALA_PATH_LINE" "$KHALA_PATH_FILE"; then
                khala_install_say "PATH export already present in $KHALA_PATH_FILE"
            elif printf '\n%s\n' "$KHALA_PATH_LINE" >> "$KHALA_PATH_FILE"; then
                khala_install_say "appended ~/.local/bin PATH export to $KHALA_PATH_FILE"
            else
                khala_install_fail "cannot append PATH export to $KHALA_PATH_FILE"
            fi
        else
            printf '%s\n' 'khala install: WARNING: ~/.local/bin is not on PATH; rerun with --fix-path to update your shell startup file' >&2
        fi
        ;;
esac

KHALA_CONFIG=$HOME/.khala/config
KHALA_DESIRED_CONFIG=$KHALA_INSTALL_TMP/config.requested.$$
if [ "$KHALA_BOOTSTRAP" -eq 1 ]; then
    printf 'self %s\nmailbox %s\nttl 120\n' "$KHALA_NAME" "$KHALA_NAME" > "$KHALA_DESIRED_CONFIG" || \
        khala_install_fail 'cannot prepare bootstrap config'
else
    printf 'self %s\npeer %s %s\nmailbox %s\nttl 120\n' \
        "$KHALA_NAME" "$KHALA_MAILBOX_NAME" "$KHALA_MAILBOX_COORD" "$KHALA_MAILBOX_NAME" \
        > "$KHALA_DESIRED_CONFIG" || khala_install_fail 'cannot prepare join config'
fi

KHALA_CONFIG_CREATED=0
if [ -f "$KHALA_CONFIG" ]; then
    KHALA_EXISTING_SELF=$(sed -n 's/^self //p' "$KHALA_CONFIG")
    if [ "$KHALA_EXISTING_SELF" = "$KHALA_NAME" ]; then
        khala_install_say "node $KHALA_NAME already initialized at ~/.khala"
    else
        khala_install_show_config_conflict
    fi
elif [ -e "$KHALA_CONFIG" ]; then
    khala_install_fail '~/.khala/config exists but is not a regular file'
else
    if ! "$KHALA_CLI" init "$KHALA_NAME" >/dev/null; then
        khala_install_fail "khala init $KHALA_NAME failed"
    fi
    KHALA_CONFIG_CREATED=1
    khala_install_say "initialized node $KHALA_NAME at ~/.khala"
fi

if cmp -s "$KHALA_DESIRED_CONFIG" "$KHALA_CONFIG"; then
    khala_install_say 'fleet config already matches the requested topology'
elif [ "$KHALA_CONFIG_CREATED" -eq 1 ]; then
    if ! mv "$KHALA_DESIRED_CONFIG" "$KHALA_CONFIG"; then
        khala_install_fail 'cannot install the requested fleet config'
    fi
    khala_install_say 'wrote the requested fleet config atomically'
else
    khala_install_show_config_conflict
fi

KHALA_VERSION_OUTPUT=$("$KHALA_CLI" version 2>&1) || \
    khala_install_fail 'installed khala CLI could not report its version'
KHALA_VERSION=$(printf '%s\n' "$KHALA_VERSION_OUTPUT" | sed -n 's/^khala \([0-9][0-9.]*\)$/\1/p')
[ -n "$KHALA_VERSION" ] || khala_install_fail "unexpected khala version output: $KHALA_VERSION_OUTPUT"

case "$(uname -s 2>/dev/null)" in
    Linux) KHALA_RELEASE_OS=linux ;;
    Darwin) KHALA_RELEASE_OS=darwin ;;
    *) khala_install_fail "unsupported operating system: $(uname -s 2>/dev/null)" ;;
esac
case "$(uname -m 2>/dev/null)" in
    x86_64) KHALA_RELEASE_ARCH=amd64 ;;
    aarch64|arm64) KHALA_RELEASE_ARCH=arm64 ;;
    *) khala_install_fail "unsupported architecture: $(uname -m 2>/dev/null)" ;;
esac
KHALA_LINK_DIR=$HOME/.khala/bin
KHALA_LINK=$KHALA_LINK_DIR/khala-link
mkdir -p "$KHALA_LINK_DIR" || khala_install_fail "cannot create $KHALA_LINK_DIR"
if [ -x "$KHALA_LINK" ]; then
    khala_install_say "khala-link already installed at $KHALA_LINK"
else
    KHALA_ASSET=khala-link-$KHALA_RELEASE_OS-$KHALA_RELEASE_ARCH
    KHALA_RELEASE_BASE=${KHALA_LINK_RELEASE_BASE-https://github.com/Dev-Jahn/khala-network/releases/download/v$KHALA_VERSION}
    KHALA_LINK_URL=${KHALA_RELEASE_BASE%/}/$KHALA_ASSET
    KHALA_LINK_TMP=$KHALA_LINK_DIR/.khala-link.$$
    if [ "$KHALA_DOWNLOADER" = curl ]; then
        curl -fsSL "$KHALA_LINK_URL" -o "$KHALA_LINK_TMP" || {
            rm -f "$KHALA_LINK_TMP"
            khala_install_fail "could not download $KHALA_LINK_URL"
        }
    else
        wget -q -O "$KHALA_LINK_TMP" "$KHALA_LINK_URL" || {
            rm -f "$KHALA_LINK_TMP"
            khala_install_fail "could not download $KHALA_LINK_URL"
        }
    fi
    if ! chmod 755 "$KHALA_LINK_TMP" || ! mv "$KHALA_LINK_TMP" "$KHALA_LINK"; then
        rm -f "$KHALA_LINK_TMP"
        khala_install_fail "cannot install $KHALA_LINK"
    fi
    khala_install_say "downloaded $KHALA_ASSET from Khala release v$KHALA_VERSION"
fi

if ! "$KHALA_CLI" node ensure; then
    khala_install_fail 'khala node ensure failed'
fi
khala_install_say 'ensured the node conduit and fleet link services'

khala_install_set_cross_session

KHALA_STATUS=$("$KHALA_CLI" status 2>&1) || khala_install_fail 'khala status failed'
KHALA_STATUS_FIRST=$(printf '%s\n' "$KHALA_STATUS" | sed -n '1p')
case "$KHALA_STATUS_FIRST" in
    runtime:*) khala_install_say "verified $KHALA_STATUS_FIRST" ;;
    *) khala_install_fail "khala status did not report a runtime first line: $KHALA_STATUS_FIRST" ;;
esac

printf '%s\n' \
    '' \
    'Khala installation complete:' \
    "  CLI: $KHALA_CLI (v$KHALA_VERSION)" \
    "  link: $KHALA_LINK" \
    "  config: $KHALA_CONFIG" \
    '' \
    'Next steps:' \
    '  1. In each project, put a session name in .khala-session.' \
    '  2. Open a Claude Code session, then run: khala presence' \
    '  3. Invite another node: khala invite <ssh-target> --name <alias>'
