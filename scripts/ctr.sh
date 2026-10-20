#!/bin/bash
# Run a command in repository B's build container, whatever runtime this machine has.
#
#   scripts/ctr.sh <yocto|br> <command...>
#
# A thin wrapper over examples/rpi/scripts/run.sh (repository B), which picks the runtime
# (CTR_RUNTIME=podman|apptainer|singularity|docker, else the first found in that order), pulls or
# builds a missing image or .sif, and mounts B read-only at /ref. This checkout is mounted at /work,
# so build trees, caches (downloads/, sstate-cache/, dl/) and yocto.sif / buildroot.sif live here,
# all git-ignored. Image names and other knobs: examples/rpi/scripts/common.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUN="$ROOT/examples/rpi/scripts/run.sh"
[ -x "$RUN" ] || { echo "ctr.sh: $RUN missing - run: git submodule update --init --recursive" >&2; exit 1; }

case "${1:-}" in
    yocto) flavour=yocto ;;
    br)    flavour=buildroot ;;
    *)     echo "usage: ${0##*/} <yocto|br> <command...>" >&2; exit 2 ;;
esac
shift

export RPI_REF_WORK="$ROOT"
exec "$RUN" "$flavour" "$@"
