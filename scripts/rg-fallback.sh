#!/bin/bash
# Last resort when rtk cannot see the command (e.g. bare `docker run … bitbake …`): apply one
# filter's line rules from .rtk/filters.toml with ripgrep, which uses the same regex engine as rtk.
#
#   <command> 2>&1 | scripts/rg-fallback.sh <filter-name>
#   scripts/rg-fallback.sh <filter-name> <log-file>
#
# Applies strip_ansi, strip_lines_matching and keep_lines_matching only. There is no replace,
# match_output, truncation, on_empty or rtk gain tracking (CLAUDE.md §9).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOML=${RTK_FILTERS:-$ROOT/.rtk/filters.toml}

# ripgrep ships as `rg`; some systems install or link it as `ripgrep`. Shell aliases are not
# visible to scripts, so an alias-only setup sets RG=/path/to/binary instead.
RG=${RG:-$(command -v rg || command -v ripgrep || true)}
[ -n "$RG" ] || { echo "rg-fallback.sh: ripgrep not found (looked for rg and ripgrep; set RG=)" >&2; exit 127; }

[ $# -ge 1 ] || { echo "usage: ${0##*/} <filter-name> [log-file]" >&2; exit 2; }
name=$1
input=${2:-/dev/stdin}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# tomllib decodes TOML escapes, so the patterns reach rg exactly as rtk compiles them.
python3 - "$TOML" "$name" "$tmp" <<'EOF'
import sys, tomllib, pathlib
toml, name, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
with open(toml, "rb") as f:
    flt = tomllib.load(f).get("filters", {}).get(name)
if flt is None:
    sys.exit(f"rg-fallback.sh: no [filters.{name}] in {toml}")
(out / "strip").write_text("".join(p + "\n" for p in flt.get("strip_lines_matching", [])))
(out / "keep").write_text("".join(p + "\n" for p in flt.get("keep_lines_matching", [])))
(out / "ansi").write_text("1" if flt.get("strip_ansi") else "")
EOF

stage() { cat "$input"; }
if [ -s "$tmp/ansi" ]; then
    # LC_ALL=C: bracket ranges like [@-~] are byte ranges only in the C locale.
    stage() { LC_ALL=C sed -E 's/\x1b\[[0-9;?]*[ -/]*[@-~]//g; s/\x1b\][^\x07]*\x07//g' "$input"; }
fi

# rg exits 1 when no line survives; that is a valid (empty) result here.
stage \
    | { if [ -s "$tmp/strip" ]; then "$RG" --no-config -v -f "$tmp/strip" || [ $? -eq 1 ]; else cat; fi; } \
    | { if [ -s "$tmp/keep" ];  then "$RG" --no-config    -f "$tmp/keep"  || [ $? -eq 1 ]; else cat; fi; }
