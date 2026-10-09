#!/bin/bash
set -e  # Exit on first error

# sbt shim: forward 'sbt <command>' to a resident sbt server through the thin client.
#
# Installed by the Dockerfile in place of SDKMAN's launcher (the original is kept next
# to it as 'sbt.real'), so it wins whatever order PATH has. Every call of a plain
# 'sbt <task>' would otherwise boot a JVM and load the build from scratch, which takes
# longer than most compile + test runs. With setting.sbt_server_support on
# (SBT_SERVER_SUPPORT=true in the container):
#
#   sbt "testOnly *MyTests*"   ->  sbt.real --client "testOnly *MyTests*"
#   sbt clean test             ->  sbt.real --client "; clean ; test"
#   sbt testOnly *MyTests*     ->  sbt.real --client "testOnly *MyTests*"
#
# The server is started on the first call (or at container start, see entrypoint.sh)
# and then stays up for the life of the container. Output and exit code of the command
# come back through the client.
#
# Passed straight to the real sbt instead: no arguments (interactive shell), any
# option (-J-Xmx.., -Dkey=val, --version, ... a running server cannot take JVM or
# launcher flags), 'new', 'shell', 'console*', directories that are not an sbt build,
# sbt older than 1.4 (no thin client) and everything when SBT_NO_CLIENT is set.

REAL_SBT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sbt.real"

passthrough() {
    exec "$REAL_SBT" "$@"
}

# Succeeds when the working directory is the base directory of an sbt build. Only the
# working directory counts: that is the base directory sbt itself would use.
is_sbt_build() {
    local sbt_file
    [ -f "project/build.properties" ] && return 0
    for sbt_file in ./*.sbt; do
        [ -f "$sbt_file" ] && return 0
    done
    return 1
}

# Succeeds when the project's sbt version has the thin client (1.4+).
has_thin_client() {
    local version
    version=$(sed -n 's/^[[:space:]]*sbt\.version[[:space:]]*=[[:space:]]*//p' \
        project/build.properties 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
    case "$version" in
        0.* | 1.[0-3].*) return 1 ;;
        *) return 0 ;;
    esac
}

# Make sure a server is running. The first caller starts it; anyone arriving meanwhile
# waits on the lock, because two clients starting a server at once make the second one
# fail. The marker lives in the container's /tmp and records "this container has
# started the server" (a fresh container has no server, whatever a previous one left in
# project/target/active.json).
# Usage: ensure_server MARKER LOCK LOG
ensure_server() {
    local marker="$1" lock="$2" log="$3"
    local -a detach=()

    [ -e "$marker" ] && return 0

    exec 9>"$lock"
    flock 9
    if [ -e "$marker" ]; then
        exec 9>&-
        return 0
    fi

    echo "sbt: starting the sbt server (first call only, log: $log)..." >&2
    # Own session, so the server survives the shell call that happened to start it
    if command -v setsid >/dev/null 2>&1; then detach=(setsid --wait); fi

    # Cheapest command that still needs the build loaded. The client forks the server
    # and leaves it running; stdin/stdout/stderr and the lock (fd 9) must not leak into
    # it, or the caller's pipes and the lock would stay open for as long as it lives.
    if "${detach[@]}" "$REAL_SBT" --client sbtVersion </dev/null >"$log" 2>&1 9>&-; then
        touch "$marker"
        exec 9>&-
        return 0
    fi

    exec 9>&-
    echo "sbt: the server did not start, last lines of the log:" >&2
    tail -n 20 "$log" >&2 || true
    return 1
}

main() {
    local warmup=false
    if [ "${1:-}" = "--ocd-warmup" ]; then
        warmup=true
        shift
    fi

    # Anything that cannot or should not go through a resident server
    if [ "${SBT_SERVER_SUPPORT:-false}" != true ] || [ -n "${SBT_NO_CLIENT:-}" ]; then
        passthrough "$@"
    fi
    if ! is_sbt_build || ! has_thin_client; then
        if [ "$warmup" = true ]; then exit 0; fi
        passthrough "$@"
    fi

    local key marker lock log
    key=$(printf '%s' "$PWD" | cksum | cut -d ' ' -f 1)
    marker="${TMPDIR:-/tmp}/ocd-sbt-server-$key.up"
    lock="${TMPDIR:-/tmp}/ocd-sbt-server-$key.lock"
    log="${TMPDIR:-/tmp}/ocd-sbt-server-$key.log"

    # Start the server without running anything: used at container start
    if [ "$warmup" = true ]; then
        ensure_server "$marker" "$lock" "$log" || exit 1
        exit 0
    fi

    if [ $# -eq 0 ]; then passthrough; fi
    case "$1" in
        -* | new | shell | console | consoleQuick | consoleProject) passthrough "$@" ;;
    esac
    local arg
    for arg in "$@"; do
        if [ "$arg" = "--client" ]; then passthrough "$@"; fi
    done

    # A failed start is not fatal here: the client forks a server by itself when it
    # finds none, so the real command below reports whatever is actually wrong
    ensure_server "$marker" "$lock" "$log" || true

    # One argument is one sbt command, as is. Several arguments are either the words of
    # one command ('testOnly *MyTests*', which sbt itself would split up) or several
    # commands to run one after the other ('clean test').
    local command
    if [ $# -eq 1 ]; then
        command="$1"
    else
        case "$1" in
            testOnly | testQuick | runMain | run | show | inspect | set | project | last | print \
                | */testOnly | */testQuick | */runMain | */run | *:testOnly | *:testQuick)
                command="$*"
                ;;
            *)
                command=""
                for arg in "$@"; do
                    command="$command ; $arg"
                done
                ;;
        esac
    fi

    case "$command" in
        shutdown | shutdown\ *)
            local rc=0
            "$REAL_SBT" --client "$command" || rc=$?
            rm -f "$marker"
            exit "$rc"
            ;;
    esac

    exec "$REAL_SBT" --client "$command"
}

main "$@"
