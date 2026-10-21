# Sourced by every suite before it runs anything; the suite's exit trap then
# removes the isolation along with its own rig:
#
#     . "$ROOT/test/lib/isolate.sh"
#     ...
#     trap 'cleanup; isolate_cleanup' EXIT HUP INT TERM
#
# The machine running a suite may itself be a live khala node — launchd or
# systemd services, ~/.khala, a runtime plane, a Claude Code session whose
# variables every child inherits. This keeps the suite and everything it
# starts away from all of it:
#
#   - inherited CLAUDE_* and KHALA_* variables and CODEX_THREAD_ID are
#     dropped (bar the suites' own knobs below), so no session id, socket or
#     identity leaks in;
#   - HOME and the runtime plane move to a fresh directory of their own, so
#     ~/.khala, ~/.claude, ~/.local/bin and the live runtime are out of
#     reach, and a defaulted KHALA_HOME lands there too;
#   - `khala node ensure` starts its daemons detached, never through
#     launchctl or systemctl;
#   - Go and uv keep the caller's module, build and Python caches, which
#     would otherwise be refetched (Go leaves its module cache read-only).
#
# That directory sits directly in the caller's home, not in the suite's rig:
# the Go tests bind unix sockets under $HOME, socket paths are capped near
# 104 bytes, and a rig under the worktree is already about 100. Nested suites
# make theirs beside it (KHALA_TEST_ISOLATION_BASE), never inside.
#
# It refuses to go on if HOME, KHALA_HOME or KHALA_RUNTIME_DIR would still
# resolve to a live path. Path variables a suite sets before sourcing still
# see the caller's HOME; exported KHALA_* variables must be set after
# sourcing, or they are dropped too.

isolate_fail() {
    printf 'FAIL isolate — %s\n' "$*" >&2
    exit 1
}

isolate_cleanup() {
    [ -z "${isolate_root-}" ] || rm -rf -- "$isolate_root"
}

# The physical path, resolving symlinks through the nearest existing ancestor.
isolate_physical() {
    if [ -d "$1" ]; then
        (cd -P -- "$1" && pwd -P)
    else
        isolate_parent=$(isolate_physical "$(dirname -- "$1")")
        printf '%s/%s\n' "${isolate_parent%/}" "$(basename -- "$1")"
    fi
}

# isolate_within PATH BASE (both physical): PATH is BASE or lies beneath it.
isolate_within() {
    case "$1/" in
        "$2/"*) return 0 ;;
    esac
    return 1
}

# Live paths, taken before anything moves: the account's home and the
# caller's, their node state, and every runtime plane the node may use
# (link/runtime.go runtimeRoot; launchd's TMPDIR is the per-user temp dir).
isolate_uid=$(id -u)
isolate_user=$(id -un)
isolate_account_home=
case "$isolate_user" in
    '' | *[!A-Za-z0-9._-]*) ;;
    *) eval "isolate_account_home=~$isolate_user" ;;
esac
isolate_tmp=${TMPDIR:-/tmp}
isolate_live_homes=("$isolate_account_home" "${HOME-}")
isolate_live_khala=("${KHALA_HOME-}" "$isolate_account_home/.khala" "${HOME-}/.khala")
isolate_live_runtime=("${KHALA_RUNTIME_DIR-}" "/run/user/$isolate_uid/khala"
    "/tmp/khala-$isolate_uid" "${isolate_tmp%/}/khala-$isolate_uid")
if isolate_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null); then
    isolate_live_runtime+=("${isolate_tmp%/}/khala-$isolate_uid")
fi

isolate_go=${GO_BINARY:-${GO:-$(command -v go 2>/dev/null)}}
if [ -n "$isolate_go" ] &&
    isolate_go_env=$("$isolate_go" env GOPATH GOMODCACHE GOCACHE GOENV 2>/dev/null); then
    { read -r GOPATH; read -r GOMODCACHE; read -r GOCACHE; read -r GOENV; } <<EOF
$isolate_go_env
EOF
    export GOPATH GOMODCACHE GOCACHE GOENV
fi
if command -v uv >/dev/null 2>&1 &&
    isolate_uv_cache=$(uv cache dir 2>/dev/null) &&
    isolate_uv_python=$(uv python dir 2>/dev/null); then
    export UV_CACHE_DIR=$isolate_uv_cache UV_PYTHON_INSTALL_DIR=$isolate_uv_python
fi

for isolate_name in $(compgen -e); do
    case "$isolate_name" in
        # Suite knobs a caller sets on purpose; no product code reads them.
        KHALA_TEST_ISOLATION_BASE | KHALA_TEST_ROOT | KHALA_UNDER_TEST | \
            KHALA_CHANNEL_SERVER | KHALA_LINK_TEST_KEEP_RIG) ;;
        CLAUDE_* | KHALA_*) unset "$isolate_name" ;;
        # A codex lane running the suites is not the session under test: with
        # it set, every Claude-path bind would be refused as a codex session.
        CODEX_THREAD_ID) unset "$isolate_name" ;;
    esac
done

# isolate_refuse WHAT PATH at|within LIVE...: refuse when PATH is one of the
# live paths (at), or is one or lies beneath one (within).
isolate_refuse() {
    isolate_what=$1
    isolate_path=$(isolate_physical "$2")
    isolate_rule=$3
    shift 3
    for isolate_live in "$@"; do
        case "$isolate_live" in /*) ;; *) continue ;; esac
        isolate_live_path=$(isolate_physical "$isolate_live")
        case "$isolate_rule" in
            at) [ "$isolate_path" != "$isolate_live_path" ] ;;
            within) ! isolate_within "$isolate_path" "$isolate_live_path" ;;
        esac || isolate_fail "refusing to run: $isolate_what resolves into the live path $isolate_live"
    done
}

export KHALA_TEST_ISOLATION_BASE=${KHALA_TEST_ISOLATION_BASE:-${HOME-}}
case "$KHALA_TEST_ISOLATION_BASE" in
    /*) ;;
    *) isolate_fail "the isolation base must be an absolute path, got '$KHALA_TEST_ISOLATION_BASE'" ;;
esac
# Nothing is created inside live node state, not even to refuse it afterwards.
isolate_refuse "the isolation base" "$KHALA_TEST_ISOLATION_BASE" within \
    "${isolate_live_khala[@]}" "${isolate_live_runtime[@]}"
trap isolate_cleanup EXIT HUP INT TERM
isolate_root=$(mktemp -d "$KHALA_TEST_ISOLATION_BASE/.khala-iso.XXXXXX") ||
    isolate_fail "could not create an isolation directory in $KHALA_TEST_ISOLATION_BASE"
export HOME=$isolate_root
export KHALA_RUNTIME_DIR=$isolate_root/khala-runtime
export KHALA_SERVICE_MANAGER=detached
mkdir -m 700 "$KHALA_RUNTIME_DIR" || isolate_fail "could not create $KHALA_RUNTIME_DIR"

isolate_refuse HOME "$HOME" at "${isolate_live_homes[@]}"
isolate_refuse KHALA_HOME "${KHALA_HOME:-$HOME/.khala}" within "${isolate_live_khala[@]}"
isolate_refuse KHALA_RUNTIME_DIR "$KHALA_RUNTIME_DIR" within "${isolate_live_runtime[@]}"
