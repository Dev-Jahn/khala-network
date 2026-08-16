#!/usr/bin/env bash

# Shared last-mile helpers. Runtime code stays within the bash 3.2 subset.

khala_valid_name() {
    printf '%s\n' "$1" | grep -q '^[a-z0-9][a-z0-9-]*$'
}

khala_nonnegative_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

khala_positive_integer() {
    khala_nonnegative_integer "$1" || return 1
    [ "$1" -gt 0 ] 2>/dev/null
}

khala_normalize_integer() {
    khala_normalized=$(printf '%s\n' "$1" | sed 's/^0*//')
    if [ -z "$khala_normalized" ]; then
        khala_normalized=0
    fi
    printf '%s\n' "$khala_normalized"
}

khala_file_mtime() {
    khala_mtime=$(stat -c %Y "$1" 2>/dev/null) || khala_mtime=
    if khala_nonnegative_integer "$khala_mtime"; then
        printf '%s\n' "$khala_mtime"
        return 0
    fi
    khala_mtime=$(stat -f %m "$1" 2>/dev/null) || khala_mtime=
    if khala_nonnegative_integer "$khala_mtime"; then
        printf '%s\n' "$khala_mtime"
        return 0
    fi
    return 1
}

# Ensure the bundled CLI lives at ~/.local/bin/khala. Ownership rules: a fresh
# slot is installed with a receipt; a byte-identical copy is adopted; a
# receipted copy that diverged is updated loudly; a symlink or an unreceipted
# divergent copy is never touched — one honest line instead. $1: plugin root.
# Prints the KHALA_VERSION a khala CLI file declares (dotted digits), or
# nothing when the file carries no readable version line.
khala_cli_version() {
    sed -n 's/^KHALA_VERSION=\([0-9][0-9.]*\)$/\1/p' "$1" 2>/dev/null | head -n 1
}

# 0 when dotted version $1 is strictly newer than $2, 1 otherwise
# (missing components count as 0: 0.4 == 0.4.0).
khala_version_newer() {
    khala_vn_a=$1.
    khala_vn_b=$2.
    while [ -n "$khala_vn_a" ] || [ -n "$khala_vn_b" ]; do
        khala_vn_x=${khala_vn_a%%.*}
        khala_vn_a=${khala_vn_a#*.}
        khala_vn_y=${khala_vn_b%%.*}
        khala_vn_b=${khala_vn_b#*.}
        [ -n "$khala_vn_x" ] || khala_vn_x=0
        [ -n "$khala_vn_y" ] || khala_vn_y=0
        [ "$khala_vn_x" -gt "$khala_vn_y" ] && return 0
        [ "$khala_vn_x" -lt "$khala_vn_y" ] && return 1
    done
    return 1
}

khala_ensure_cli() {
    khala_bundled=$1/bin/khala
    [ -f "$khala_bundled" ] || return 0
    [ -n "${HOME-}" ] || return 0
    khala_cli_dir=$HOME/.local/bin
    khala_cli_target=$khala_cli_dir/khala
    khala_cli_receipt=$khala_cli_dir/.khala.plugin-receipt

    if [ -L "$khala_cli_target" ]; then
        if ! cmp -s "$khala_bundled" "$khala_cli_target"; then
            printf '%s\n' 'khala: ~/.local/bin/khala는 심링크(수동 관리) — 플러그인 동봉본과 내용이 다릅니다. 갱신은 손으로.'
        fi
        return 0
    fi
    if [ -f "$khala_cli_target" ]; then
        if cmp -s "$khala_bundled" "$khala_cli_target"; then
            if [ ! -f "$khala_cli_receipt" ]; then
                printf 'khala-plugin\n' > "$khala_cli_receipt" 2>/dev/null || :
            fi
            return 0
        fi
        if [ ! -f "$khala_cli_receipt" ]; then
            printf '%s\n' 'khala: ~/.local/bin/khala가 플러그인 동봉본과 다릅니다 — 수동 설치본으로 보고 건드리지 않습니다. 플러그인 관리로 넘기려면 그 파일을 지우세요.'
            return 0
        fi
        # A receipted copy is ours to update, but only forward: a session still
        # holding an older plugin root must not roll a newer install back.
        khala_cli_bundled_version=$(khala_cli_version "$khala_bundled")
        khala_cli_installed_version=$(khala_cli_version "$khala_cli_target")
        if [ -n "$khala_cli_bundled_version" ] && [ -n "$khala_cli_installed_version" ] && \
            ! khala_version_newer "$khala_cli_bundled_version" "$khala_cli_installed_version"; then
            if [ "$khala_cli_bundled_version" = "$khala_cli_installed_version" ]; then
                printf 'khala: ~/.local/bin/khala(%s)가 같은 버전의 동봉본과 바이트가 다릅니다 — 건드리지 않습니다\n' \
                    "$khala_cli_installed_version"
            else
                printf 'khala: ~/.local/bin/khala(%s)가 이 플러그인의 동봉본(%s)보다 새롭습니다 — 되돌리지 않습니다\n' \
                    "$khala_cli_installed_version" "$khala_cli_bundled_version"
            fi
            return 0
        fi
        khala_cli_update=1
    else
        khala_cli_update=0
    fi
    if ! mkdir -p "$khala_cli_dir" 2>/dev/null; then
        printf 'khala: CLI 설치 실패 — %s를 만들 수 없습니다\n' "$khala_cli_dir"
        return 0
    fi
    khala_cli_tmp=$khala_cli_dir/.khala.install.$$
    if cp "$khala_bundled" "$khala_cli_tmp" 2>/dev/null && \
        chmod 755 "$khala_cli_tmp" 2>/dev/null && \
        mv -f "$khala_cli_tmp" "$khala_cli_target" 2>/dev/null; then
        printf 'khala-plugin\n' > "$khala_cli_receipt" 2>/dev/null || :
        if [ "$khala_cli_update" -eq 1 ]; then
            printf '%s\n' 'khala: CLI 갱신됨 — ~/.local/bin/khala ← 플러그인 동봉본'
        else
            printf '%s\n' 'khala: CLI 설치됨 — ~/.local/bin/khala (플러그인 동봉본)'
        fi
    else
        rm -f "$khala_cli_tmp" 2>/dev/null
        printf 'khala: CLI 설치 실패 — %s에 쓸 수 없습니다\n' "$khala_cli_dir"
    fi
    return 0
}

khala_discover() {
    if [ "${KHALA_HOME+x}" = x ]; then
        KHALA_ROOT=$KHALA_HOME
    elif [ -n "${HOME-}" ]; then
        KHALA_ROOT=$HOME/.khala
    else
        KHALA_ROOT=
    fi

    KHALA_BIN=$(command -v khala 2>/dev/null) || KHALA_BIN=
    if [ -z "$KHALA_BIN" ] && [ -n "${HOME-}" ] && [ -x "$HOME/.local/bin/khala" ]; then
        KHALA_BIN=$HOME/.local/bin/khala
    fi
    if [ -z "$KHALA_BIN" ] && [ -n "${CLAUDE_PROJECT_DIR-}" ] && \
        [ -x "$CLAUDE_PROJECT_DIR/bin/khala" ]; then
        KHALA_BIN=$CLAUDE_PROJECT_DIR/bin/khala
    fi

    [ -n "$KHALA_ROOT" ] && [ -n "$KHALA_BIN" ] && [ -f "$KHALA_ROOT/config" ]
}

khala_read_session_file() {
    khala_session_path=$1
    KHALA_SESSION_FILE_VALUE=
    khala_session_line_count=0
    while IFS= read -r khala_session_line || [ -n "$khala_session_line" ]; do
        khala_session_line_count=$((khala_session_line_count + 1))
        if [ "$khala_session_line_count" -eq 1 ]; then
            KHALA_SESSION_FILE_VALUE=$khala_session_line
        fi
    done < "$khala_session_path"
    [ "$khala_session_line_count" -eq 1 ] && khala_valid_name "$KHALA_SESSION_FILE_VALUE"
}

# $1 is retained for hook-call compatibility; basename inference is forbidden.
# $2: emit resolution warnings (1/0)
khala_resolve_session() {
    khala_allow_basename=$1
    khala_emit_warning=$2
    KHALA_RESOLVED_SESSION=
    KHALA_SESSION_SOURCE=
    KHALA_EXPLICIT_IDENTITY=0

    if [ "${KHALA_SESSION+x}" = x ]; then
        KHALA_EXPLICIT_IDENTITY=1
        if khala_valid_name "$KHALA_SESSION"; then
            KHALA_RESOLVED_SESSION=$KHALA_SESSION
            KHALA_SESSION_SOURCE=environment
            return 0
        fi
        if [ "$khala_emit_warning" -eq 1 ]; then
            printf 'khala: KHALA_SESSION이 유효한 세션 이름이 아닙니다: %s (허용: [a-z0-9][a-z0-9-]*)\n' \
                "$KHALA_SESSION"
        fi
        return 1
    fi

    khala_session_path=${CLAUDE_PROJECT_DIR-}/.khala-session
    if [ -n "${CLAUDE_PROJECT_DIR-}" ] && [ -f "$khala_session_path" ]; then
        if khala_read_session_file "$khala_session_path"; then
            KHALA_RESOLVED_SESSION=$KHALA_SESSION_FILE_VALUE
            KHALA_SESSION_SOURCE=file
            KHALA_EXPLICIT_IDENTITY=1
            return 0
        fi
        if [ "$khala_emit_warning" -eq 1 ]; then
            printf '%s\n' 'khala: .khala-session이 한 줄의 유효한 세션 이름이 아닙니다 — 무시합니다'
        fi
    fi

    if [ "$khala_emit_warning" -eq 1 ]; then
        printf '%s\n' 'khala: 세션 신원이 없습니다 — KHALA_SESSION=<name>을 설정하거나 프로젝트에 한 줄짜리 .khala-session을 만드세요'
    fi
    return 1
}

khala_self_node() {
    KHALA_NODE=$(sed -n 's/^self //p' "$KHALA_ROOT/config")
    khala_valid_name "$KHALA_NODE"
}

khala_count_files() {
    khala_count_dir=$1
    khala_count=0
    if [ -d "$khala_count_dir" ]; then
        for khala_count_path in "$khala_count_dir"/*; do
            [ -f "$khala_count_path" ] || continue
            khala_count=$((khala_count + 1))
        done
    fi
    printf '%s\n' "$khala_count"
}

# Sets KHALA_WATCH_PID and returns true only for a fresh, well-formed owner.
khala_watch_is_fresh() {
    khala_watch_session=$1
    khala_owner=$KHALA_ROOT/run/watch.$khala_watch_session.lock.d/owner
    [ -f "$khala_owner" ] || return 1

    khala_owner_epoch=$(sed -n '1p' "$khala_owner")
    khala_owner_line=$(sed -n '2p' "$khala_owner")
    khala_owner_interval=$(sed -n '3p' "$khala_owner")
    KHALA_WATCH_PID=$(printf '%s\n' "$khala_owner_line" | \
        sed -n 's/^pid \([0-9][0-9]*\) watch$/\1/p')
    khala_nonnegative_integer "$khala_owner_epoch" || return 1
    khala_nonnegative_integer "$KHALA_WATCH_PID" || return 1
    khala_positive_integer "$khala_owner_interval" || return 1

    khala_owner_epoch=$(khala_normalize_integer "$khala_owner_epoch")
    khala_owner_interval=$(khala_normalize_integer "$khala_owner_interval")
    khala_now=$(date +%s) || return 1
    [ "$khala_now" -ge "$khala_owner_epoch" ] || return 1
    khala_age=$((khala_now - khala_owner_epoch))
    khala_fresh_for=$((2 * (khala_owner_interval + 120)))
    [ "$khala_age" -lt "$khala_fresh_for" ]
}

khala_find_link_binary() {
    KHALA_LINK_BINARY=
    if [ -x "$KHALA_ROOT/bin/khala-link" ]; then
        KHALA_LINK_BINARY=$KHALA_ROOT/bin/khala-link
        return 0
    fi
    khala_binary_dir=$(CDPATH= cd -- "$(dirname "$KHALA_BIN")" 2>/dev/null && pwd) || return 1
    if [ -x "$khala_binary_dir/khala-link" ]; then
        KHALA_LINK_BINARY=$khala_binary_dir/khala-link
        return 0
    fi
    return 1
}

khala_link_is_fresh() {
    khala_link_marker=$KHALA_ROOT/run/link.fresh
    [ -f "$khala_link_marker" ] || return 1
    khala_link_mtime=$(khala_file_mtime "$khala_link_marker") || return 1
    khala_now=$(date +%s) || return 1
    [ "$khala_now" -ge "$khala_link_mtime" ] || return 1
    [ "$((khala_now - khala_link_mtime))" -le 60 ]
}

# Run only a hook-owned child for at most $1 seconds. Output paths are explicit
# so a killed drain can still expose any complete letters it printed first.
khala_run_with_deadline() {
    khala_deadline_seconds=$1
    khala_deadline_stdout=$2
    khala_deadline_stderr=$3
    shift 3
    mkdir -p "$KHALA_ROOT/tmp" || return 1
    khala_deadline_marker=$KHALA_ROOT/tmp/hook-timeout.$$.${RANDOM-0}
    rm -f "$khala_deadline_marker"
    "$@" > "$khala_deadline_stdout" 2> "$khala_deadline_stderr" &
    khala_deadline_pid=$!
    (
        sleep "$khala_deadline_seconds"
        if kill "$khala_deadline_pid" 2>/dev/null; then
            printf '%s\n' timeout > "$khala_deadline_marker"
        fi
    ) &
    khala_deadline_watchdog=$!
    wait "$khala_deadline_pid"
    khala_deadline_status=$?
    kill "$khala_deadline_watchdog" 2>/dev/null || :
    wait "$khala_deadline_watchdog" 2>/dev/null || :
    if [ -f "$khala_deadline_marker" ]; then
        rm -f "$khala_deadline_marker"
        return 124
    fi
    return "$khala_deadline_status"
}
