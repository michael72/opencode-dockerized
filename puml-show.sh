#!/bin/bash
set -e  # Exit on first error

# puml-show — render a PlantUML diagram directly in the terminal.
# Installed in the image as /usr/local/bin/puml-show.
#
# Renders through pumlcli (local pumlsrv, started by entrypoint.sh) as PNG and
# converts it to Sixel graphics with img2sixel. Without Sixel support (e.g. a
# tmux client whose terminal does not report it) it falls back to the ASCII-art
# 'txt' rendering of pumlcli.

usage() {
    cat <<EOF
Usage: puml-show [-w WIDTH] [-H HEIGHT] [-s|-a] [file.puml]

Render a PlantUML diagram in the terminal as Sixel graphics.
Reads PlantUML source from file.puml or, if omitted, from STDIN.

  -w WIDTH    scale the image to WIDTH pixels (keeps the aspect ratio)
  -H HEIGHT   scale the image to HEIGHT pixels (keeps the aspect ratio)
  -s          force Sixel output, skip the terminal support check
  -a          force ASCII-art output (pumlcli -t txt)
  -h          show this help

Sixel needs a capable terminal. Inside tmux the outer terminal must report
Sixel support; check with: tmux display -p '#{client_termfeatures}'

Examples:
  puml-show docs/architecture.puml
  puml-show -w 1200 docs/architecture.puml
  echo '@startuml
Bob -> Alice : hello
@enduml' | puml-show
EOF
}

# Best-effort check whether Sixel graphics will reach the screen.
# Inside tmux the tmux client knows the outer terminal's features; outside of
# tmux there is no cheap, reliable query, so Sixel is assumed.
sixel_supported() {
    if [ -n "$TMUX" ]; then
        local features
        features=$(tmux display -p '#{client_termfeatures}' 2>/dev/null || true)
        [[ ",$features," == *",sixel,"* ]]
        return
    fi
    return 0
}

main() {
    local mode=auto
    local -a scale_args=()
    local opt
    while getopts ":w:H:sah" opt; do
        case "$opt" in
            w) scale_args+=(-w "$OPTARG") ;;
            H) scale_args+=(-h "$OPTARG") ;;
            s) mode=sixel ;;
            a) mode=ascii ;;
            h) usage; exit 0 ;;
            :) echo "puml-show: option -$OPTARG needs a value" >&2; usage >&2; exit 1 ;;
            *) echo "puml-show: unknown option -$OPTARG" >&2; usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ $# -gt 1 ]; then
        usage >&2
        exit 1
    fi

    local -a input_args=()
    if [ $# -eq 1 ]; then
        if [ ! -f "$1" ]; then
            echo "puml-show: file not found: $1" >&2
            exit 1
        fi
        input_args=(-f "$1")
    fi

    if [ "$mode" = auto ]; then
        if sixel_supported; then
            mode=sixel
        else
            echo "puml-show: terminal does not report Sixel support, showing ASCII art (-s forces Sixel)" >&2
            mode=ascii
        fi
    fi

    if [ "$mode" = ascii ]; then
        pumlcli "${input_args[@]}" -t txt
        return
    fi

    # Render to a temp file first, so a pumlcli error is reported as such
    # instead of feeding garbage to img2sixel
    # (global, not local: the EXIT trap runs after main has returned)
    PNG_FILE=$(mktemp --suffix=.png)
    trap 'rm -f "$PNG_FILE"' EXIT
    pumlcli "${input_args[@]}" -o "$PNG_FILE" -t png
    if [ ! -s "$PNG_FILE" ]; then
        echo "puml-show: pumlcli produced no image (is pumlsrv running?)" >&2
        exit 1
    fi
    img2sixel "${scale_args[@]}" "$PNG_FILE"
}

main "$@"
