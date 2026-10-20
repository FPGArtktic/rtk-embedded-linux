#!/bin/bash
# Run a build command and keep its raw output (stdout+stderr, ANSI intact) as a sample.
#
#   scripts/capture.sh <yocto|buildroot> <row-id>[-<scenario>] <command...>
#
# Writes samples/<dir>/<name>.log (exactly what the command printed) and samples/<dir>/<name>.cmd
# (the command line and its exit status). Exits with the command's exit status.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

[ $# -ge 3 ] || { echo "usage: ${0##*/} <yocto|buildroot> <name> <command...>" >&2; exit 2; }
case "$1" in
    yocto|buildroot) dir="$ROOT/samples/$1" ;;
    *) echo "capture.sh: first argument must be yocto or buildroot" >&2; exit 2 ;;
esac
name=$2
shift 2

mkdir -p "$dir"
log="$dir/$name.log"

"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

{
    printf '%q ' "$@" | sed 's/ $//'
    printf '\n# exit=%s bytes=%s lines=%s runtime=%s\n' \
        "$status" "$(wc -c <"$log")" "$(wc -l <"$log")" "${CTR_RUNTIME:-auto}"
} >"$dir/$name.cmd"

echo "capture.sh: $log (exit $status)" >&2
exit "$status"
