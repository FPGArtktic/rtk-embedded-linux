#!/bin/bash
# Replay the Buildroot captures through an rtk binary's built-in `make` filter (no project
# filters: empty HOME, scratch tracking DB, a working directory without .rtk/filters.toml) and
# report what reaches the agent: bytes, and whether a failing build still shows its compiler error
# and its `make: ***` line. Tee stays on, as in a default install.
#
#   scripts/verify-upstream-make.sh <path/to/rtk>
#
# Exits 1 if a failing build loses its error or its `make: ***` line.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
R=$(realpath "${1:?usage: ${0##*/} <path/to/rtk>}")
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S/home" "$S/run"; cd "$S/run" || exit 1

"$R" --version
status=0
printf '%-34s %8s %8s %8s %6s %6s\n' sample raw shown reduct error '***'
while read -r name code cmd; do
    # shellcheck disable=SC2086
    env -i HOME="$S/home" PATH="$ROOT/scripts/shim:/usr/bin:/bin" RTK_DB_PATH="$S/home/rtk.db" \
        RTK_SAMPLE="$ROOT/samples/buildroot/$name.log" RTK_SAMPLE_EXIT="$code" "$R" $cmd > "$S/out.txt" 2>&1
    raw=$(wc -c < "$ROOT/samples/buildroot/$name.log"); out=$(wc -c < "$S/out.txt")
    err=$(rg -q 'error:' "$S/out.txt" && echo yes || echo no)
    stars=$(rg -q '^make: \*\*\*' "$S/out.txt" && echo yes || echo no)
    printf '%-34s %8d %8d %7.2f%% %6s %6s\n' "$name" "$raw" "$out" \
        "$(echo "100-100*$out/$raw" | bc -l)" "$err" "$stars"
    if [ "$code" -ne 0 ] && { [ "$err" = no ] || [ "$stars" = no ]; }; then status=1; fi
done <<'EOF'
buildroot-make-ok 0 make
buildroot-make-rebuild 0 make
buildroot-make-defconfig 0 make raspberrypi4_64_defconfig
buildroot-make-fail-compile 2 make
buildroot-make-fail-compile-long 2 make
EOF
exit $status
