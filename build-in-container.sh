#!/usr/bin/env bash
# build-in-container.sh -- run build.sh inside a throw-away container, so the
# bundle is built against an older glibc (wider compatibility) and nothing is
# installed on the host.  Works with docker or podman.
#
#   ./build-in-container.sh            # -> ./dist/frama-c-<ver>-offline-x86_64.tar
#
# Environment:
#   ENGINE=docker|podman        (default: whichever is found)
#   BASE_IMAGE=ubuntu:20.04     glibc of the image = minimum glibc on targets
#                               (20.04 -> glibc 2.31: RHEL 9 (2.34), Debian 11+,
#                               Ubuntu 20.04+; 22.04 -> 2.35 is too new for
#                               RHEL 9).  build.sh enforces GLIBC_MAX (2.34).
#   FCAI_VOLUME=fcai-build      named volume keeping the opam root / sources
#                               between runs (incremental rebuilds); remove it
#                               with: docker volume rm fcai-build
#   IVETTE_PREBUILT=FILE|DIR    use this Ivette (AppImage / unpacked Electron
#                               app) instead of building it from source
#   Any build.sh setting (FRAMAC_VERSION, ALTERGO_PKG, WITH_CVC5, WITH_IVETTE,
#   FORCE, ...) is passed through.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ENGINE=${ENGINE:-$(command -v docker || command -v podman || true)}
[ -n "$ENGINE" ] || { echo "neither docker nor podman found" >&2; exit 1; }
BASE_IMAGE=${BASE_IMAGE:-ubuntu:20.04}
VOLUME=${FCAI_VOLUME:-fcai-build-${BASE_IMAGE//[:\/]/-}}
mkdir -p "$HERE/dist"

PASS=()
for v in FRAMAC_VERSION OCAML_VERSION OCAML_FLAMBDA ALTERGO_PKG WITH_CVC5 EXCLUDE_PLUGINS \
         Z3_VERSION Z3_URL Z3_SHA256 CVC4_URL CVC4_SHA256 CVC5_URL CVC5_SHA256 \
         OPAM_VERSION OPAM_SHA256 OPAM_REPO JOBS SKIP_SELFTEST FORCE WITH_IVETTE NODE_VERSION KEEP_LOGS GLIBC_MAX WITH_PYTHON; do
    if [ -n "${!v+x}" ]; then PASS+=(-e "$v=${!v}"); fi
done
# a prebuilt Ivette (AppImage or unpacked directory) on the host is mounted in
PREBUILT=()
if [ -n "${IVETTE_PREBUILT:-}" ]; then
    p=$(readlink -f "$IVETTE_PREBUILT")
    PREBUILT=(-v "$(dirname "$p"):/fcai-prebuilt:ro" -e "IVETTE_PREBUILT=/fcai-prebuilt/$(basename "$p")")
fi
TTY=(); [ -t 0 ] && TTY=(-t)
# docker runs as root: hand the output back to the caller.  Rootless podman
# already maps container root to the caller, so no chown there.
OWNER=()
case "$(basename "$ENGINE")" in podman*) ;; *) OWNER=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)") ;; esac

set -x
exec "$ENGINE" run --rm -i "${TTY[@]}" \
    --cap-add SYS_PTRACE \
    -e FCAI_IN_CONTAINER=1 "${OWNER[@]}" "${PASS[@]}" "${PREBUILT[@]}" \
    -v "$HERE:/fcai-src:ro" \
    -v "$HERE/dist:/fcai-out" \
    -v "$VOLUME:/fcai-build" \
    "$BASE_IMAGE" bash /fcai-src/build.sh
