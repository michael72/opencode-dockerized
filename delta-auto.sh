#!/bin/bash
set -e  # Exit on first error

# delta-auto — git pager that runs delta side-by-side only when that helps.
# Installed in the image as /usr/local/bin/delta-auto and set as core.pager in
# /etc/gitconfig (a core.pager in your own ~/.gitconfig takes precedence).
#
# The whole diff is read first and its changed lines counted. Side-by-side is
# used only if all of these hold, otherwise the unified view:
#   - both sides have a fair share of the changes: the smaller of added/removed
#     lines is at least DELTA_AUTO_MIN_SHARE percent of all changed lines
#     (pure additions or deletions, or "mostly new code", stay unified)
#   - the terminal is at least DELTA_AUTO_MIN_COLUMNS wide
#   - at most DELTA_AUTO_MAX_LINES lines changed (long outputs such as a big
#     'git log -p' read better unified)
# The decision covers the whole output of one git command, not each file.
#
# Environment:
#   DELTA_SIDE_BY_SIDE=1|0      force side-by-side / unified, skip the heuristic
#   DELTA_AUTO_MIN_SHARE=25     percent, see above
#   DELTA_AUTO_MIN_COLUMNS=160  terminal columns, see above
#   DELTA_AUTO_MAX_LINES=2000   changed lines, see above
# Any arguments are passed on to delta. A delta.side-by-side=true in your own
# git config keeps side-by-side on, as delta has no flag to turn it off.

min_share="${DELTA_AUTO_MIN_SHARE:-25}"
min_columns="${DELTA_AUTO_MIN_COLUMNS:-160}"
max_lines="${DELTA_AUTO_MAX_LINES:-2000}"

# Width of the terminal the pager will draw on. stdout is usually a pipe or
# the terminal; /dev/tty works in both cases. COLUMNS is rarely exported.
terminal_columns() {
    local size
    if size=$( { stty size </dev/tty; } 2>/dev/null ) && [ -n "$size" ]; then
        echo "${size#* }"
    else
        echo "${COLUMNS:-80}"
    fi
}

# Prints "added removed" for a diff on stdin. Colors are stripped first (git
# colors its output for a pager); the ---/+++ file headers are not counted.
count_changes() {
    sed 's/\x1b\[[0-9;]*m//g' | awk '
        /^\+\+\+ / || /^--- / { next }
        /^\+/ { added++ ; next }
        /^-/  { removed++ }
        END   { printf "%d %d\n", added, removed }
    '
}

# Exit status 0 if the diff in "$1" should be shown side-by-side
want_side_by_side() {
    case "${DELTA_SIDE_BY_SIDE:-}" in
        1|true)  return 0 ;;
        0|false) return 1 ;;
    esac

    local added removed total smaller
    read -r added removed < <(count_changes <"$1")
    total=$((added + removed))
    [ "$total" -gt 0 ] || return 1
    [ "$total" -le "$max_lines" ] || return 1
    [ "$(terminal_columns)" -ge "$min_columns" ] || return 1

    smaller=$(( added < removed ? added : removed ))
    [ $((smaller * 100)) -ge $((min_share * total)) ]
}

main() {
    local diff_file
    diff_file=$(mktemp)
    # Delete the file while keeping it open on fd 3, so nothing is left behind
    # after the exec below
    cat >"$diff_file"

    local -a delta_args=()
    if want_side_by_side "$diff_file"; then
        delta_args+=(--side-by-side)
    fi

    exec 3<"$diff_file"
    rm -f "$diff_file"
    exec delta "${delta_args[@]}" "$@" <&3
}

main "$@"
