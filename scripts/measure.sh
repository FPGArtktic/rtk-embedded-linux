#!/bin/bash
# Replay every captured sample through the real rtk and the PATH shim, and measure what reaches
# the agent (filtered output + any rtk hint line) against the raw capture (CLAUDE.md §9 step 5-6).
#
#   scripts/measure.sh [--markdown] [samples/<dir>/<name>.log ...]     (default: all samples)
#
# --markdown prints the table for README.md / EVALUATION.md, so both always carry the same numbers.
#
# The command comes from <name>.cmd with the ctr.sh/run.sh wrapper dropped, so rtk looks up the
# same tool command it would see inside a container; the sample's exit status is replayed too.
# Prints: sample, filter, exit, raw bytes, shown bytes, reduction, est. tokens saved (bytes/4).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
md=
if [ "${1:-}" = --markdown ]; then md=1; shift; fi
[ $# -gt 0 ] || set -- samples/*/*.log

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "$md" ]; then
    echo '| Sample | Command (as the agent ran it, minus the wrapper) | Filter | Exit | Raw bytes | Agent sees | Reduction | ~Tokens saved |'
    echo '|---|---|---|---|---:|---:|---:|---:|'
else
    printf '%-46s %-22s %4s %10s %9s %8s %10s\n' sample filter exit raw shown reduction "~tok saved"
fi
total_raw=0 total_shown=0
for log in "$@"; do
    cmd_file=${log%.log}.cmd
    [ -f "$cmd_file" ] || { echo "skip $log (no .cmd)" >&2; continue; }
    status=$(sed -n 's/^# exit=\([0-9]*\).*/\1/p' "$cmd_file")
    # drop the wrapper: "./scripts/ctr.sh yocto bitbake -e x" -> "bitbake -e x"
    tool_cmd=$(head -1 "$cmd_file" | sed -E 's#^\S*(ctr|run)\.sh (yocto|br|buildroot) ##')
    # stdout is what the agent gets (rtk prints its hints there too); stderr names the filter
    PATH="$ROOT/scripts/shim:$PATH" RTK_TOML_DEBUG=1 RTK_SAMPLE="$log" RTK_SAMPLE_EXIT="${status:-0}" \
        bash -c "rtk $tool_cmd" >"$tmp/out" 2>"$tmp/err"
    filter=$(sed -n "s/.*matched filter: '\(.*\)'.*/\1/p" "$tmp/err")
    shown=$(wc -c <"$tmp/out")
    # raw = what the command printed (from .cmd); a sample trimmed for the repository (CLAUDE.md §11)
    # is marked with a dagger. Its replay differs from the full capture only in rtk's line counts.
    raw=$(sed -n 's/^# exit=[0-9]* bytes=\([0-9]*\).*/\1/p' "$cmd_file")
    mark=
    if [ -z "$raw" ]; then raw=$(wc -c <"$log"); elif [ "$raw" != "$(wc -c <"$log")" ]; then mark=" †"; fi
    total_raw=$((total_raw + raw)) total_shown=$((total_shown + shown))
    awk -v md="$md" -v s="${log#samples/}$mark" -v c="$tool_cmd" -v f="${filter:--}" -v e="${status:-?}" \
        -v r="$raw" -v o="$shown" 'BEGIN {
        red = r ? int(10000 * (r - o) / r) / 100 : 0   # floor: never show 100% while bytes remain
        if (md) { gsub(/\|/, "\\|", c)
                  sub(/ †$/, "` †", s); if (s !~ /`/) s = s "`"
                  printf "| `%s | `%s` | `%s` | %s | %d | %d | %.2f%% | %d |\n", s, c, f, e, r, o, red, (r - o) / 4 }
        else      printf "%-46s %-22s %4s %10d %9d %7.2f%% %10d\n", s, f, e, r, o, red, (r - o) / 4 }'
done
awk -v md="$md" -v r="$total_raw" -v o="$total_shown" 'BEGIN {
    red = r ? int(10000 * (r - o) / r) / 100 : 0   # floor: never show 100% while bytes remain
    if (md) printf "| **all samples** | | | | **%d** | **%d** | **%.2f%%** | **%d** |\n", r, o, red, (r - o) / 4
    else    printf "%-46s %-22s %4s %10d %9d %7.2f%% %10d\n", "TOTAL", "", "", r, o, red, (r - o) / 4 }'
