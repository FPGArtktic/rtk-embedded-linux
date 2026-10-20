#!/bin/bash
# Run a command in repository B's build container, whatever runtime this machine has.
#
#   scripts/ctr.sh <yocto|br> <command...>
#
#   CTR_RUNTIME  podman | apptainer | singularity | docker   (default: first found, in that order)
#   IMAGE_YOCTO  default rpi-ref-yocto:scarthgap      SIF_YOCTO  default <repo>/yocto.sif
#   IMAGE_BR     default rpi-ref-buildroot:2026.02    SIF_BR     default <repo>/buildroot.sif
#
# B (examples/rpi) is mounted read-only at /ref and this checkout at /work, in every runtime, so
# build trees, caches (downloads/, sstate-cache/, dl/) and log paths are identical across runtimes.
# Podman and Docker images are built from B's Containerfiles on first use; Apptainer needs a .sif.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REF="$ROOT/examples/rpi"

case "${1:-}" in
    yocto) image=${IMAGE_YOCTO:-rpi-ref-yocto:scarthgap}  sif=${SIF_YOCTO:-$ROOT/yocto.sif}     ctx=yocto ;;
    br)    image=${IMAGE_BR:-rpi-ref-buildroot:2026.02}   sif=${SIF_BR:-$ROOT/buildroot.sif}    ctx=buildroot ;;
    *)     echo "usage: ${0##*/} <yocto|br> <command...>" >&2; exit 2 ;;
esac
shift
[ -f "$REF/containers/$ctx/Containerfile" ] || {
    echo "ctr.sh: $REF is empty — run: git submodule update --init --recursive" >&2; exit 1; }

runtime=${CTR_RUNTIME:-}
if [ -z "$runtime" ]; then
    for r in podman apptainer singularity docker; do
        if command -v "$r" >/dev/null 2>&1; then runtime=$r; break; fi
    done
fi
[ -n "$runtime" ] || { echo "ctr.sh: no container runtime found (podman, apptainer, singularity, docker)" >&2; exit 127; }

# A terminal gets a terminal (BitBake then draws progress bars); a pipe gets plain output.
tty=()
[ -t 1 ] && tty+=(-t)
[ -t 0 ] && tty+=(-i)

build_image() {   # <runtime>
    "$1" image inspect "$image" >/dev/null 2>&1 && return
    echo "ctr.sh: building $image with $1 (first use)" >&2
    "$1" build -t "$image" -f "$REF/containers/$ctx/Containerfile" "$REF/containers/$ctx" >&2
}

case "$runtime" in
    podman)
        build_image podman
        exec podman run --rm "${tty[@]}" --userns=keep-id --security-opt label=disable \
            -v "$REF:/ref:ro" -v "$ROOT:/work" "$image" "$@" ;;
    docker)
        build_image docker
        exec docker run --rm "${tty[@]}" --user "$(id -u):$(id -g)" --security-opt label=disable \
            -v "$REF:/ref:ro" -v "$ROOT:/work" "$image" "$@" ;;
    apptainer|singularity)
        [ -f "$sif" ] || {
            echo "ctr.sh: $sif not found. Build it from the same Containerfile, e.g.:" >&2
            echo "  podman build -t $image $REF/containers/$ctx" >&2
            echo "  podman save --format oci-archive -o /tmp/$ctx.tar $image && $runtime build $sif oci-archive:///tmp/$ctx.tar" >&2
            exit 1; }
        # `run` goes through the image's entrypoint, which sets up the build environment.
        exec "$runtime" run --cleanenv --bind "$REF:/ref:ro,$ROOT:/work" "$sif" "$@" ;;
    *)
        echo "ctr.sh: unsupported CTR_RUNTIME=$runtime" >&2; exit 2 ;;
esac
