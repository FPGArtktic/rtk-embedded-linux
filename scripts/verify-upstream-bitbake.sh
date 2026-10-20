#!/bin/bash
# Replay the Yocto captures through an rtk binary that ships the built-in `bitbake` filter
# (upstream rtk-ai/rtk, src/filters/bitbake.toml) and check that no ERROR/WARNING/failure-location
# line is lost. Only built-in filters apply: the run uses an empty HOME, a scratch tracking DB,
# no tee, and a working directory without .rtk/filters.toml.
#
#   scripts/verify-upstream-bitbake.sh <path/to/rtk>
#
# Prints raw bytes, filtered bytes, reduction, the number of must-keep lines and how many of them
# are missing from the filtered output (must be 0), plus every line removed from -e, -s and
# -c listtasks. Exits 1 if any must-keep line is missing.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
R=$(realpath "${1:?usage: ${0##*/} <path/to/rtk>}")
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S/home" "$S/run"; cd "$S/run" || exit 1

run() {
    env -i HOME="$S/home" PATH="$ROOT/scripts/shim:/usr/bin:/bin" RTK_TEE=0 RTK_DB_PATH="$S/home/rtk.db" \
        RTK_SAMPLE="$ROOT/samples/yocto/$1.log" RTK_SAMPLE_EXIT="$2" "$R" "${@:3}" 2>&1
}
noansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
# Lines an agent needs to locate and understand a failure (CLAUDE.md §10).
KEEP='^(ERROR|WARNING|Summary|NOTE: Tasks Summary|NOTE: recipe .*: Failed|Log data follows|\| |  +/|    log: )'

"$R" --version
status=0
printf '%-28s %10s %9s %8s %9s %8s\n' sample raw filtered reduct must-keep missing
while read -r name code cmd; do
    noansi < "$ROOT/samples/yocto/$name.log" > "$S/raw.txt"
    # shellcheck disable=SC2086
    run "$name" "$code" $cmd > "$S/out.raw"
    noansi < "$S/out.raw" > "$S/out.txt"
    raw=$(wc -c < "$ROOT/samples/yocto/$name.log"); out=$(wc -c < "$S/out.raw")
    rg "$KEEP" "$S/raw.txt" | sort -u > "$S/must.txt"
    missing=$(comm -23 "$S/must.txt" <(sort -u "$S/out.txt") | wc -l)
    [ "$missing" -eq 0 ] || status=1
    printf '%-28s %10d %9d %7.2f%% %9d %8d\n' "$name" "$raw" "$out" \
        "$(echo "100-100*$out/$raw" | bc -l)" "$(wc -l < "$S/must.txt")" "$missing"
    case $name in
        bitbake-e|bitbake-s|bitbake-listtasks)
            comm -23 <(sort -u "$S/raw.txt") <(sort -u "$S/out.txt") | rg -v '^\s*$' | sed 's/^/    removed: /' ;;
    esac
done <<'EOF'
bitbake-build-ok 0 bitbake core-image-minimal
bitbake-build-sstate-hit 0 bitbake core-image-minimal
bitbake-build-fail-compile 1 bitbake rtk-fail-compile
bitbake-build-fetch-fail 1 bitbake rtk-fetch-fail
bitbake-e 0 bitbake -e core-image-minimal
bitbake-s 0 bitbake -s
bitbake-listtasks 0 bitbake -c listtasks busybox
bitbake-g 0 bitbake -g core-image-minimal
EOF
exit $status
