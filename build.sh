#!/usr/bin/env bash
# build.sh -- build a relocatable, fully offline Frama-C + Why3 + provers
# bundle (AppImage, with an extractable directory form) and its delivery
# archive.  Needs network access (opam, GitHub).  Runs either inside the
# container started by build-in-container.sh (recommended), or natively on a
# Debian/Ubuntu machine (it then needs the packages listed in APT_PACKAGES).
#
# Everything is built from source with a private opam root under BUILD_ROOT;
# nothing outside BUILD_ROOT / OUT_DIR is touched (except apt when root).
#
# Frama-C is linked as ONE executable with all its plug-ins statically linked
# ("option A"): no dynlink, no findlib, no OCAMLPATH at runtime.  Its data
# directories are found relative to the executable (dune-site relocatable
# install).  Why3 is linked into it as a library; its data dir and prover
# configuration are provided at runtime by AppRun (WHY3DATA / WHY3CONFIG).
#
# Re-running is incremental: completed steps are skipped (see STAMPS).
# Useful overrides (environment):
#   FRAMAC_VERSION=33.0   OCAML_VERSION=4.14.2   OCAML_FLAMBDA=0|1
#   ALTERGO_PKG=alt-ergo.2.6.2 (or alt-ergo-free.2.4.3, or "" to omit)
#   WITH_CVC5=1   WITH_IVETTE=1   IVETTE_PREBUILT=/path/to/ivette.AppImage
#   NODE_VERSION=22.22.2   EXTRA_PLUGINS="frama-c-metacsl.0.11"
#   EXCLUDE_PLUGINS=e-acsl,e_acsl
#   BUILD_ROOT=...  OUT_DIR=...  JOBS=N  SKIP_SELFTEST=1  FORCE=step1,step2
#   KEEP_LOGS=1 (old logs are deleted at the start of each build otherwise)
#   GLIBC_MAX=2.34  the build fails if any bundled ELF needs a newer glibc
#                   (2.34 = RHEL 9; the default image ubuntu:20.04 gives 2.31)
set -Eeuo pipefail

SRC_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# ----------------------------------------------------------------- settings
: "${FRAMAC_VERSION:=33.0}"
: "${OCAML_VERSION:=4.14.2}"
: "${OCAML_FLAMBDA:=0}"
: "${OPAM_VERSION:=2.3.0}"
: "${OPAM_SHA256:=324e78e3f33efeba279aacf9f9610cfec7b2df7d7e0e1640f75f09de85f96cc9}"
: "${OPAM_REPO:=https://opam.ocaml.org}"
: "${ALTERGO_PKG=alt-ergo.2.6.2}"
: "${WITH_CVC5:=1}"
# Ivette (Electron GUI; the GTK GUI is gone since Frama-C 33): built from the
# ivette/ directory of the Frama-C sources with Node.js, or taken from
# IVETTE_PREBUILT (an Ivette AppImage or an unpacked Electron app directory)
: "${WITH_IVETTE:=1}"
# third-party Frama-C plug-ins from opam, built inside the Frama-C source tree
# (so they are linked statically like the others); space-separated opam
# package.version list
: "${EXTRA_PLUGINS=frama-c-metacsl.0.11}"
: "${IVETTE_PREBUILT:=}"
: "${NODE_VERSION:=22.22.2}"
: "${EXCLUDE_PLUGINS:=e-acsl,e_acsl,eacsl}"
# provers: official static / portable release binaries
: "${Z3_VERSION:=4.13.0}"
: "${Z3_URL:=https://github.com/Z3Prover/z3/releases/download/z3-${Z3_VERSION}/z3-${Z3_VERSION}-x64-glibc-2.31.zip}"
: "${Z3_SHA256:=bc31ad12446d7db1bd9d0ac82dec9d7b5129b8b8dd6e44b571a83ac6010d2f9b}"
: "${CVC4_URL:=https://github.com/CVC4/CVC4-archived/releases/download/1.8/cvc4-1.8-x86_64-linux-opt}"
: "${CVC4_SHA256:=d38a79cf984592785eda41ec888d94ca107ac1f13058740238041e28c8472e51}"
: "${CVC5_URL:=https://github.com/cvc5/cvc5/releases/download/cvc5-1.2.1/cvc5-Linux-x86_64-static.zip}"
: "${CVC5_SHA256:=6d44abc233980a14d72cc5809287d27c3335b1d6ee863381d0b5ffcbd0d8de56}"
# AppImage tooling (pinned)
: "${APPIMAGETOOL_URL:=https://github.com/AppImage/appimagetool/releases/download/1.9.0/appimagetool-x86_64.AppImage}"
: "${APPIMAGETOOL_SHA256:=46fdd785094c7f6e545b61afcfb0f3d98d8eab243f644b4b17698c01d06083d1}"
: "${RUNTIME_URL:=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64}"
: "${RUNTIME_SHA256:=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d}"
# patchelf: the distro one is too old on ubuntu:20.04 (0.10, buggy RUNPATH
# rewriting); this static build is used by bundle_libs.py
: "${PATCHELF_URL:=https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz}"
: "${PATCHELF_SHA256:=ce84f2447fb7a8679e58bc54a20dc2b01b37b5802e12c57eece772a6f14bf3f0}"
# newest glibc the bundle may require (targets: RHEL 9 = 2.34)
: "${GLIBC_MAX:=2.34}"

if [ -f /.dockerenv ] || [ -n "${FCAI_IN_CONTAINER:-}" ]; then
    : "${BUILD_ROOT:=/fcai-build}"
    : "${OUT_DIR:=/fcai-out}"
else
    : "${BUILD_ROOT:=$SRC_DIR/_work}"
    : "${OUT_DIR:=$SRC_DIR/dist}"
fi
: "${JOBS:=$(nproc)}"

APT_PACKAGES="build-essential m4 pkg-config unzip curl ca-certificates git patchelf file
python3 binutils xz-utils bzip2 strace libgmp-dev zlib1g-dev libffi-dev graphviz autoconf time
desktop-file-utils"
# to run Ivette (Electron) in the self-test, under Xvfb
APT_PACKAGES_IVETTE="xvfb xauth libgtk-3-0 libnss3 libasound2 libgbm1 libxss1 libxtst6 libatk-bridge2.0-0
libdrm2 libxkbfile1 libsecret-1-0 libnotify4 libxshmfence1"

export OPAMROOT="$BUILD_ROOT/opam"
export OPAMYES=1 OPAMROOTISOK=1 OPAMCONFIRMLEVEL=unsafe-yes OPAMCOLOR=never
export OPAMJOBS="$JOBS" OPAMNOENVNOTICE=1 OPAMDOWNLOADJOBS=4
SWITCH=fcai
DL="$BUILD_ROOT/downloads"
FC_SRC="$BUILD_ROOT/src/frama-c-$FRAMAC_VERSION"
STAGE="$BUILD_ROOT/stage"
APPDIR="$BUILD_ROOT/AppDir"
STAMPS="$BUILD_ROOT/stamps"
LOGDIR="$BUILD_ROOT/logs"
mkdir -p "$BUILD_ROOT" "$DL" "$STAMPS" "$LOGDIR" "$OUT_DIR" "$BUILD_ROOT/bin"
export PATH="$BUILD_ROOT/bin:$PATH"

# start every build with clean logs (KEEP_LOGS=1 to keep the old ones)
if [ -z "${KEEP_LOGS:-}" ]; then
    rm -rf "${LOGDIR:?}"/* "$OUT_DIR/logs" "$OUT_DIR"/build-*.log "$OUT_DIR"/selftest-report.txt \
           "$OUT_DIR"/fcai-test-report-*.txt 2>/dev/null || true
fi
LOG="$LOGDIR/build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*"; }
export_logs() {
    mkdir -p "$OUT_DIR/logs" 2>/dev/null || return 0
    cp "$LOGDIR"/*.log "$LOGDIR"/*.txt "$OUT_DIR/logs/" 2>/dev/null || true
    if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT_DIR" 2>/dev/null || true; fi
}
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*"; trap - ERR; export_logs; echo "logs copied to $OUT_DIR/logs"; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND   (log: $LOG)"' ERR

# step NAME: returns 1 (skip) if already done and not forced
step() {
    local n=$1
    if [ -f "$STAMPS/$n" ] && [[ ",${FORCE:-}," != *",$n,"* ]] && [[ ",${FORCE:-}," != *",all,"* ]]; then
        say "[skip] $n (done; FORCE=$n to redo)"; return 1
    fi
    say "$n"; return 0
}
done_step() { touch "$STAMPS/$1"; }

fetch() { # URL SHA256 DEST
    local url=$1 sum=$2 dst=$3
    if [ ! -f "$dst" ] || ! echo "$sum  $dst" | sha256sum -c --status; then
        curl -fL --retry 3 -o "$dst.part" "$url"
        mv "$dst.part" "$dst"
    fi
    echo "$sum  $dst" | sha256sum -c - || die "checksum mismatch for $url"
}

oexec() { opam exec --switch="$SWITCH" -- "$@"; }

say "Frama-C $FRAMAC_VERSION bundle build   BUILD_ROOT=$BUILD_ROOT   OUT_DIR=$OUT_DIR   log=$LOG"

# ------------------------------------------------------------------ 0. system
if step system-packages; then
    if command -v apt-get >/dev/null && [ "$(id -u)" = 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        # shellcheck disable=SC2086
        apt-get install -y -q --no-install-recommends $APT_PACKAGES
        if [ "$WITH_IVETTE" = 1 ]; then
            # shellcheck disable=SC2086
            apt-get install -y -q --no-install-recommends $APT_PACKAGES_IVETTE \
                || warn "could not install the Electron runtime libraries: the self-test will skip launching Ivette"
        fi
    else
        missing=""
        for t in gcc make m4 pkg-config unzip curl git patchelf file python3 objdump strace dot; do
            command -v "$t" >/dev/null || missing="$missing $t"
        done
        [ -z "$missing" ] || die "missing tools:$missing -- install: $(echo $APT_PACKAGES)"
        warn "not root: assuming the system packages are installed ($(echo $APT_PACKAGES))"
    fi
    # the stamp is not kept in containers (fresh image every run)
    [ -f /.dockerenv ] || [ -n "${FCAI_IN_CONTAINER:-}" ] || done_step system-packages
fi

# -------------------------------------------------------------------- 1. opam
if [ ! -x "$BUILD_ROOT/bin/opam" ]; then
    say "fetch opam $OPAM_VERSION"
    fetch "https://github.com/ocaml/opam/releases/download/$OPAM_VERSION/opam-$OPAM_VERSION-x86_64-linux" \
          "$OPAM_SHA256" "$DL/opam-$OPAM_VERSION"
    install -m 755 "$DL/opam-$OPAM_VERSION" "$BUILD_ROOT/bin/opam"
fi

if step opam-init; then
    rm -rf "$OPAMROOT"
    opam init --bare --disable-sandboxing --no-setup -y default "$OPAM_REPO"
    done_step opam-init
fi

if step opam-switch; then
    opam switch remove -y "$SWITCH" 2>/dev/null || true
    if [ "$OCAML_FLAMBDA" = 1 ]; then
        opam switch create "$SWITCH" --packages="ocaml-variants.$OCAML_VERSION+options,ocaml-option-flambda"
    else
        opam switch create "$SWITCH" --packages="ocaml-base-compiler.$OCAML_VERSION"
    fi
    done_step opam-switch
fi

if step opam-deps; then
    opam update
    if [ -n "$ALTERGO_PKG" ]; then opam install --switch="$SWITCH" -y "$ALTERGO_PKG"; fi
    opam install --switch="$SWITCH" -y --deps-only "frama-c.$FRAMAC_VERSION"
    oexec why3 --version
    done_step opam-deps
fi

# ------------------------------------------------------- 2. Frama-C sources
if step framac-source; then
    rm -rf "$FC_SRC"; mkdir -p "$(dirname "$FC_SRC")"
    opam source --switch="$SWITCH" "frama-c.$FRAMAC_VERSION" --dir "$FC_SRC"
    done_step framac-source
fi

# -------------------------- 2b. third-party plug-ins, vendored in the tree
# Each one is a dune project of its own; dropped under src/plugins/ it becomes
# part of the Frama-C dune workspace, builds against the in-tree kernel and
# registers its dune-site plug-in like the bundled ones.
EXTRA_NAMES=""
for pkg in $EXTRA_PLUGINS; do
    name=${pkg%%.*}
    dst="$FC_SRC/src/plugins/fcai-extra-$name"
    EXTRA_NAMES="$EXTRA_NAMES $name"
    if [ ! -f "$dst/.fcai-$pkg" ]; then
        say "vendor $pkg into the Frama-C tree"
        rm -rf "$dst"
        opam source --switch="$SWITCH" "$pkg" --dir "$dst"
        touch "$dst/.fcai-$pkg"
        rm -f "$STAMPS/framac-build" "$STAMPS/framac-static"   # rebuild with it
    fi
done

# ----------------------- 3. regular build (discovers the plug-in libraries)
if step framac-build; then
    (cd "$FC_SRC" && oexec dune build -j "$JOBS" --release --promote-install-files=false @install)
    echo "plug-ins registered: $(ls "$FC_SRC/_build/install/default/lib/frama-c/plugins/" | tr '\n' ' ')"
    for name in $EXTRA_NAMES; do
        # its libraries are named <opam package>.*, so its plug-in META says so
        grep -qs "\"$name[.\"]" "$FC_SRC"/_build/install/default/lib/frama-c/plugins/*/META \
            || die "vendored $name built, but registered no Frama-C plug-in (see above)"
    done
    done_step framac-build
fi

# ------------------------- 4. single executable with plug-ins linked in
if step framac-static; then
    gen=$(cd "$FC_SRC" && oexec python3 "$SRC_DIR/lib/gen_static_exe.py" --src . \
            --public-name frama-c-static --exclude "$EXCLUDE_PLUGINS")
    STATIC_DIR=${gen% *}; STATIC_MAIN=${gen#* }
    (cd "$FC_SRC" && oexec dune build -j "$JOBS" --release --promote-install-files=false \
        "./$STATIC_DIR/$STATIC_MAIN.exe" @install)
    rm -rf "$STAGE"
    # relocatable install: dune rewrites the dune-site locations embedded in
    # the executable as paths relative to <exe>/../..
    if ! (cd "$FC_SRC" && oexec dune install --release --relocatable --prefix "$STAGE"); then
        warn "'dune install --release --relocatable' failed, retrying without --release"
        (cd "$FC_SRC" && oexec dune install --root . --relocatable --prefix "$STAGE")
    fi
    [ -x "$STAGE/bin/frama-c-static" ] || die "frama-c-static was not installed in $STAGE/bin"
    done_step framac-static
fi

# ---------------------------------------------------------- 5. prover files
say "provers"
fetch "$Z3_URL" "$Z3_SHA256" "$DL/$(basename "$Z3_URL")"
fetch "$CVC4_URL" "$CVC4_SHA256" "$DL/$(basename "$CVC4_URL")"
if [ "$WITH_CVC5" = 1 ]; then fetch "$CVC5_URL" "$CVC5_SHA256" "$DL/$(basename "$CVC5_URL")"; fi
fetch "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256" "$DL/appimagetool.AppImage"
fetch "$RUNTIME_URL" "$RUNTIME_SHA256" "$DL/runtime-x86_64"

# ----------------------------------------------------------- 6. the AppDir
say "assemble AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/fcai/licenses"
install -m 755 "$SRC_DIR/appdir/AppRun" "$APPDIR/AppRun"
install -D -m 755 "$SRC_DIR/appdir/fcai-wrappers/frama-c" "$APPDIR/usr/lib/fcai-wrappers/frama-c"
cp "$SRC_DIR/appdir/frama-c.desktop" "$SRC_DIR/appdir/frama-c.svg" "$APPDIR/"
ln -s frama-c.svg "$APPDIR/.DirIcon"

# Frama-C: the static executable + its data (share/); no OCaml libraries
install -m 755 "$STAGE/bin/frama-c-static" "$APPDIR/usr/bin/frama-c"
cp -a "$STAGE/share/." "$APPDIR/usr/share/"
# frama-c-script: bash front-end to share/analysis-scripts (python3 and make
# come from the host).  In the bundle, -print-share-path prints the env entry
# AND the baked one, so any "$(... -print-share-path)" keeps the first line only.
[ -f "$STAGE/bin/frama-c-script" ] || die "frama-c-script was not installed in $STAGE/bin"
cp "$STAGE/bin/frama-c-script" "$LOGDIR/frama-c-script.orig.txt"
python3 "$SRC_DIR/lib/patch_script.py" "$STAGE/bin/frama-c-script" "$APPDIR/usr/bin/frama-c-script" \
    | tee "$LOGDIR/frama-c-script-patch.txt"
chmod 755 "$APPDIR/usr/bin/frama-c-script"
# empty plug-in site directories (nothing to autoload, but the dirs exist)
for d in "$STAGE"/lib/*/plugins*; do
    if [ -d "$d" ]; then mkdir -p "$APPDIR/usr/lib/${d#"$STAGE/lib/"}"; fi
done
mkdir -p "$APPDIR/usr/share/fcai/licenses/frama-c"
cp -r "$FC_SRC"/LICENSE* "$FC_SRC"/licenses "$APPDIR/usr/share/fcai/licenses/frama-c/" 2>/dev/null || true

# Why3 data directory (drivers, stdlib, prover detection data)
WHY3_BIN=$(oexec sh -c 'command -v why3')
WHY3_DATADIR=$(oexec why3 --print-datadir)
WHY3_VERSION=$(oexec why3 --version | awk '{print $NF}')
mkdir -p "$APPDIR/usr/share/why3" && cp -a "$WHY3_DATADIR/." "$APPDIR/usr/share/why3/"
mkdir -p "$APPDIR/usr/lib/why3/plugins" "$APPDIR/usr/lib/why3/commands"
# Why3 runs provers through helper executables found in its libdir
# (why3server, why3cpulimit): WHY3LIB points AppRun's frama-c at our copy
WHY3_LIBDIR=$(oexec why3 --print-libdir)
for f in "$WHY3_LIBDIR"/*; do
    if [ -f "$f" ] && [ -x "$f" ]; then install -m 755 "$f" "$APPDIR/usr/lib/why3/"; echo "why3 helper: $(basename "$f")"; fi
done
[ -x "$APPDIR/usr/lib/why3/why3server" ] || die "why3server not found in $WHY3_LIBDIR"
mkdir -p "$APPDIR/usr/share/fcai/licenses/why3"
cp "$(oexec opam var why3:doc 2>/dev/null)"/LICENSE* "$APPDIR/usr/share/fcai/licenses/why3/" 2>/dev/null || true

# provers
tmpz=$(mktemp -d); unzip -q "$DL/$(basename "$Z3_URL")" -d "$tmpz"
install -m 755 "$tmpz"/*/bin/z3 "$APPDIR/usr/bin/z3"
mkdir -p "$APPDIR/usr/share/fcai/licenses/z3"; cp "$tmpz"/*/LICENSE.txt "$APPDIR/usr/share/fcai/licenses/z3/" 2>/dev/null || true
rm -rf "$tmpz"
install -m 755 "$DL/$(basename "$CVC4_URL")" "$APPDIR/usr/bin/cvc4"
PROVERS="z3 cvc4"
if [ "$WITH_CVC5" = 1 ]; then
    tmpc=$(mktemp -d); unzip -q "$DL/$(basename "$CVC5_URL")" -d "$tmpc"
    install -m 755 "$(find "$tmpc" -type f -name cvc5 -path '*/bin/*' | head -n1)" "$APPDIR/usr/bin/cvc5"
    mkdir -p "$APPDIR/usr/share/fcai/licenses/cvc5"
    find "$tmpc" -maxdepth 2 -iname 'COPYING*' -exec cp {} "$APPDIR/usr/share/fcai/licenses/cvc5/" \; || true
    rm -rf "$tmpc"
    PROVERS="$PROVERS cvc5"
fi
if [ -n "$ALTERGO_PKG" ]; then
    install -m 755 "$(oexec sh -c 'command -v alt-ergo')" "$APPDIR/usr/bin/alt-ergo"
    mkdir -p "$APPDIR/usr/share/fcai/licenses/alt-ergo"
    agdoc=$(oexec opam var "${ALTERGO_PKG%%.*}:doc" 2>/dev/null || true)
    if [ -n "$agdoc" ]; then cp -r "$agdoc"/LICENSE* "$agdoc"/licenses "$APPDIR/usr/share/fcai/licenses/alt-ergo/" 2>/dev/null || true; fi
    PROVERS="$PROVERS alt-ergo"
fi

# C preprocessor: the gcc driver + cc1 only, same layout relative to the
# driver as on the build system (gcc finds cc1 relative to itself)
say "bundle the C preprocessor"
CPPROOT="$APPDIR/usr/lib/fcai-cpp"
GCC_DRV=$(readlink -f "$(command -v gcc)")
CC1=$(readlink -f "$(gcc -print-prog-name=cc1)")
case "$GCC_DRV" in /usr/bin/*) ;; *) die "unexpected gcc location $GCC_DRV" ;; esac
case "$CC1" in /usr/*) ;; *) die "unexpected cc1 location $CC1" ;; esac
# the driver is called through a wrapper adding -nostdinc: only Frama-C's
# own libc headers are ever used, never the host's /usr/include (gcc finds
# cc1 relative to its own location, whatever its name)
install -D -m 755 "$GCC_DRV" "$CPPROOT/bin/gcc-real"
cat > "$CPPROOT/bin/gcc" <<'WRAP'
#!/bin/sh
# bundled preprocessor: host system headers are never searched
exec "$(dirname "$(readlink -f "$0")")/gcc-real" -nostdinc "$@"
WRAP
chmod 755 "$CPPROOT/bin/gcc"
install -D -m 755 "$CC1" "$CPPROOT/${CC1#/usr/}"
mkdir -p "$APPDIR/usr/share/fcai/licenses/gcc"
cp /usr/share/doc/gcc*/copyright "$APPDIR/usr/share/fcai/licenses/gcc/" 2>/dev/null || true

# shared libraries + relative RUNPATHs
say "bundle shared libraries"
if [ ! -x "$BUILD_ROOT/tools/patchelf/bin/patchelf" ]; then
    fetch "$PATCHELF_URL" "$PATCHELF_SHA256" "$DL/patchelf.tar.gz"
    rm -rf "$BUILD_ROOT/tools/patchelf"; mkdir -p "$BUILD_ROOT/tools/patchelf"
    tar xzf "$DL/patchelf.tar.gz" -C "$BUILD_ROOT/tools/patchelf"
fi
python3 "$SRC_DIR/lib/bundle_libs.py" "$APPDIR" --patchelf "$BUILD_ROOT/tools/patchelf/bin/patchelf"

# `dune install --relocatable` baked the dune-site locations into frama-c as
# <exe>/../ + <absolute stage path>, i.e. usr/$STAGE/share/... .  Parts of
# Frama-C use that entry (e.g. for the libc include path), so make it valid
# with one relative symlink:  usr$STAGE -> usr
mkdir -p "$(dirname "$APPDIR/usr$STAGE")"
ln -sfn "$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' \
          "$APPDIR/usr" "$APPDIR/usr$STAGE")" "$APPDIR/usr$STAGE"
echo "baked-path alias: usr$STAGE -> $(readlink "$APPDIR/usr$STAGE")"

# ------------------------------------- 7. relocation check of frama-c itself
# dune-site locations are given to frama-c by AppRun through DUNE_DIR_LOCATIONS
# (package:section:dir triples, all relative to the bundle root).  These come
# first in dune-site's search list, before whatever `dune install
# --relocatable` baked into the executable (which turned out to be
# <prefix>/<absolute stage path>, i.e. unusable).
say "relocation check"
locs=""
for d in "$STAGE"/share/*/; do p=$(basename "$d"); locs="$locs:$p:share:@APPDIR@/usr/share/$p"; done
for d in "$STAGE"/lib/*/;   do p=$(basename "$d"); locs="$locs:$p:lib:@APPDIR@/usr/lib/$p"; done
printf '%s\n' "${locs#:}" > "$APPDIR/usr/share/fcai/dune-dir-locations"
cat "$APPDIR/usr/share/fcai/dune-dir-locations"
# AppRun needs a why3.conf template; the real one is generated in step 8
[ -f "$APPDIR/usr/share/fcai/why3.conf.in" ] || : > "$APPDIR/usr/share/fcai/why3.conf.in"
RELO=$(mktemp -d "$BUILD_ROOT/relo.XXXXXX")
cp -a "$APPDIR" "$RELO/moved"
# -print-share-path lists every candidate, in search order: the first one is
# ours (DUNE_DIR_LOCATIONS), the others are what dune baked in (unused)
shares=$(env -i HOME="$RELO" PATH=/usr/bin:/bin "$RELO/moved/AppRun" frama-c -print-share-path 2>&1 || true)
echo "share paths of a moved copy:"; printf '%s\n' "$shares" | sed 's/^/  /'
share=$(printf '%s\n' "$shares" | head -n1)
while IFS= read -r d; do
    case "$d" in "$RELO/moved/"*) ;; *) die "share path outside the moved bundle: '$d'" ;; esac
    [ -d "$d/libc" ] || die "share path '$d' has no libc/ (every entry must be valid)"
done <<< "$shares"
case "$share" in
    "$RELO/moved/usr/share/"*) ;;
    *) die "frama-c does not find its share directory inside the moved bundle: '$share'" ;;
esac
[ -d "$share" ] || die "share directory '$share' does not exist"
[ -d "$share/machdeps" ] || [ -d "$share/libc" ] || die "'$share' is not Frama-C's share directory (no machdeps/ or libc/)"
# a real parse, through the bundled preprocessor, with the original moved away
mv "$APPDIR" "$APPDIR.hidden"
printf '#include <stdio.h>\n#include <string.h>\nint main(void) { return (int)strlen("x") - 1; }\n' > "$RELO/t.c"
parse_rc=0
env -i HOME="$RELO" PATH=/usr/bin:/bin "$RELO/moved/AppRun" frama-c -print "$RELO/t.c" > "$LOGDIR/relo-parse.txt" 2>&1 || parse_rc=$?
mv "$APPDIR.hidden" "$APPDIR"
cat "$LOGDIR/relo-parse.txt"
[ "$parse_rc" = 0 ] || die "moved bundle cannot parse a C file"
env -i HOME="$RELO" PATH=/usr/bin:/bin "$RELO/moved/AppRun" frama-c -plugins | tee "$LOGDIR/plugins.txt"
grep -qi 'wp' "$LOGDIR/plugins.txt" || die "WP is not among the statically linked plug-ins"
rm -rf "$RELO"

# ----------------------------------------- 8. why3.conf template for AppRun
say "Why3 prover configuration template"
W=$(mktemp -d)
env -i HOME="$W" PATH="$APPDIR/usr/bin" WHY3CONFIG="$W/why3.conf" \
    WHY3DATA="$APPDIR/usr/share/why3" "$WHY3_BIN" config detect
env -i HOME="$W" PATH="$APPDIR/usr/bin" WHY3CONFIG="$W/why3.conf" \
    WHY3DATA="$APPDIR/usr/share/why3" "$WHY3_BIN" config list-provers | tee "$LOGDIR/why3-provers.txt" || true
cat "$W/why3.conf"
for p in $PROVERS; do
    case $p in z3) n=Z3;; cvc4) n=CVC4;; cvc5) n=CVC5;; alt-ergo) n=Alt-Ergo;; esac
    grep -q "name = \"$n\"" "$W/why3.conf" || die "Why3 did not detect bundled prover $n"
done
grep -vE '^[[:space:]]*(libdir|datadir)[[:space:]]*=' "$W/why3.conf" \
    | sed "s|$APPDIR|@APPDIR@|g" > "$APPDIR/usr/share/fcai/why3.conf.in"
if grep -q -e "$BUILD_ROOT" -e "$OPAMROOT" "$APPDIR/usr/share/fcai/why3.conf.in"; then
    die "why3.conf template still contains build paths"
fi
rm -rf "$W"

# ------------------------------------------------------------- 8b. Ivette
# import_ivette SRC: find a packaged Electron app (unpacked directory, or an
# AppImage to extract) under SRC -- or SRC itself -- and copy it to $IVOUT.
IVOUT="$BUILD_ROOT/ivette-app"
import_ivette() {
    local src=$1 root="" asar tmp
    if [ -f "$src" ]; then   # an AppImage file
        tmp=$(mktemp -d "$BUILD_ROOT/ivx.XXXXXX")
        (cd "$tmp" && chmod +x "$src" && "$src" --appimage-extract >/dev/null)
        src="$tmp/squashfs-root"
    fi
    # prefer electron-builder's *-unpacked directory, then anything else
    for asar in $(find "$src" \( -name node_modules -prune \) -o \( -path '*/resources/app.asar' -print \) \
                  | awk '{print (/-unpacked\//?0:1) "\t" $0}' | sort | cut -f2); do
        root=$(dirname "$(dirname "$asar")"); break
    done
    if [ -z "$root" ]; then
        tmp=$(find "$src" \( -name node_modules -prune \) -o \( -name '*.AppImage' -print \) | head -n1)
        [ -n "$tmp" ] && { import_ivette "$tmp"; return; }
        return 1
    fi
    local exe=""
    for f in "$root"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        case "$(basename "$f")" in chrome-sandbox|chrome_crashpad_handler|AppRun|*.so|*.so.*) continue ;; esac
        file -b "$f" | grep -q '^ELF' || continue
        exe=$(basename "$f")
        case "$exe" in *[Ii]vette*) break ;; esac
    done
    [ -n "$exe" ] || return 1
    rm -rf "$IVOUT"; mkdir -p "$IVOUT"
    cp -a "$root/." "$IVOUT/"
    echo "$exe" > "$IVOUT/.fcai-exe"
    echo "Ivette: imported $root (executable: $exe)"
}

if [ "$WITH_IVETTE" = 1 ]; then
    if [ -n "$IVETTE_PREBUILT" ]; then
        say "Ivette: importing $IVETTE_PREBUILT"
        import_ivette "$(readlink -f "$IVETTE_PREBUILT")" || die "no Electron app found in $IVETTE_PREBUILT"
    elif step ivette-build; then
        NODE_DIR="$BUILD_ROOT/node-v$NODE_VERSION-linux-x64"
        if [ ! -x "$NODE_DIR/bin/node" ]; then
            curl -fL --retry 3 -o "$DL/node-SHASUMS256.txt" "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"
            nsum=$(awk -v f="node-v$NODE_VERSION-linux-x64.tar.xz" '$2==f{print $1}' "$DL/node-SHASUMS256.txt")
            [ -n "$nsum" ] || die "no checksum for node $NODE_VERSION"
            fetch "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" "$nsum" \
                  "$DL/node-v$NODE_VERSION-linux-x64.tar.xz"
            tar -C "$BUILD_ROOT" -xJf "$DL/node-v$NODE_VERSION-linux-x64.tar.xz"
        fi
        export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
        # npm/corepack are '#!/usr/bin/env node' scripts
        export PATH="$NODE_DIR/bin:$PATH"
        corepack enable --install-directory "$NODE_DIR/bin" || npm install -g yarn
        yarn --version
        # 'frama-c' for the Ivette build (API generation may call it)
        mkdir -p "$BUILD_ROOT/wrap"
        printf '#!/bin/sh\nexec "%s/AppRun" frama-c "$@"\n' "$APPDIR" > "$BUILD_ROOT/wrap/frama-c"
        chmod 755 "$BUILD_ROOT/wrap/frama-c"
        SWBIN=$(opam var --switch="$SWITCH" bin)
        mkdir -p "$BUILD_ROOT/ivette-home"
        ivmake() {
            (cd "$FC_SRC" && oexec env PATH="$BUILD_ROOT/wrap:$NODE_DIR/bin:$SWBIN:$PATH" \
                HOME="$BUILD_ROOT/ivette-home" \
                ELECTRON_CACHE="$BUILD_ROOT/ivette-home/.cache/electron" \
                ELECTRON_BUILDER_CACHE="$BUILD_ROOT/ivette-home/.cache/electron-builder" \
                make -C ivette "$@")
        }
        # The TypeScript bindings of the plug-in server APIs (ivette/src/frama-c/
        # **/api) are not all shipped in the tarball: they are generated by
        # Frama-C itself.  Generate them with the bundled frama-c (all plug-ins
        # linked in, run through AppRun via $BUILD_ROOT/wrap/frama-c).
        say "Ivette: make -C ivette api  (log: $LOGDIR/ivette-api.log)"
        { echo "---- ivette/api.sh:"; cat "$FC_SRC/ivette/api.sh"; echo "----"; } > "$LOGDIR/ivette-api.log"
        if ! ivmake api >> "$LOGDIR/ivette-api.log" 2>&1; then
            cat "$LOGDIR/ivette-api.log"
            die "Ivette API generation failed (log above)"
        fi
        tail -n 20 "$LOGDIR/ivette-api.log"
        say "Ivette: make -C ivette dist  (log: $LOGDIR/ivette-build.log)"
        iv_rc=0
        ivmake dist > "$LOGDIR/ivette-build.log" 2>&1 || iv_rc=$?
        tail -n 40 "$LOGDIR/ivette-build.log"
        [ "$iv_rc" = 0 ] || warn "'make -C ivette dist' exited with $iv_rc; looking for a packaged app anyway"
        if ! import_ivette "$FC_SRC/ivette"; then
            echo "---- ivette/ top level:"; ls -la "$FC_SRC/ivette" || true
            echo "---- make targets:"; make -C "$FC_SRC/ivette" -qp 2>/dev/null \
                | grep -E '^[a-zA-Z][a-zA-Z0-9_.-]*:' | cut -d: -f1 | sort -u | tr '\n' ' ' || true
            echo; echo "---- package.json scripts:"
            python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("scripts",{}),indent=1))' \
                "$FC_SRC/ivette/package.json" 2>/dev/null || true
            die "Ivette build produced no packaged Electron app (see $LOGDIR/ivette-build.log); \
set WITH_IVETTE=0 to skip, or IVETTE_PREBUILT=<Ivette AppImage> to import one"
        fi
        done_step ivette-build
    fi
    [ -f "$IVOUT/.fcai-exe" ] || die "Ivette: $IVOUT is incomplete (FORCE=ivette-build to rebuild)"
    mkdir -p "$APPDIR/usr/lib/ivette"
    cp -a "$IVOUT/." "$APPDIR/usr/lib/ivette/"
    # chrome-sandbox cannot be setuid root in an AppImage: AppRun decides
    # between the user-namespace sandbox and --no-sandbox at run time
    chmod 755 "$APPDIR/usr/lib/ivette/chrome-sandbox" 2>/dev/null || true
    mkdir -p "$APPDIR/usr/share/fcai/licenses/ivette"
    cp "$APPDIR"/usr/lib/ivette/LICENSE* "$APPDIR/usr/share/fcai/licenses/ivette/" 2>/dev/null || true
fi

# -------------------------------------------------------- 9. build-info
say "build info"
glibc_floor=$(find "$APPDIR" -path "$APPDIR/usr/lib/ivette" -prune -o -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && objdump -T "$1" 2>/dev/null' _ {} \; \
    | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n1)
ver() { "$APPDIR/usr/bin/$1" --version 2>&1 | head -n1; }
{
    echo "FRAMAC_VERSION=$FRAMAC_VERSION"
    echo "FRAMAC_VERSION_STRING=$(env -i PATH=/usr/bin:/bin "$APPDIR/usr/bin/frama-c" -no-autoload-plugins -version 2>&1 | head -n1)"
    echo "WHY3_VERSION=$WHY3_VERSION"
    echo "OCAML_VERSION=$OCAML_VERSION$([ "$OCAML_FLAMBDA" = 1 ] && echo +flambda)"
    echo "PROVERS=$PROVERS"
    echo "EXTRA_PLUGINS=$EXTRA_PLUGINS"
    if [ -f "$APPDIR/usr/lib/ivette/.fcai-exe" ]; then
        echo "IVETTE=yes ($(cat "$APPDIR/usr/lib/ivette/.fcai-exe"), $(du -sh "$APPDIR/usr/lib/ivette" | cut -f1))"
    else
        echo "IVETTE=no"
    fi
    for p in $PROVERS; do echo "PROVER_$(echo "$p" | tr a-z- A-Z_)=$(ver "$p")"; done
    echo "PREPROCESSOR=$("$CPPROOT/bin/gcc" --version | head -n1)"
    echo "PLUGINS=$(grep -oE '^ *[A-Za-z][A-Za-z0-9_-]*' "$LOGDIR/plugins.txt" | tr -s ' \n' ' ' | sed 's/^ //')"
    echo "GLIBC_REQUIRED=$glibc_floor"
    if [ -d "$APPDIR/usr/lib/ivette" ]; then
        echo "GLIBC_REQUIRED_IVETTE=$(find "$APPDIR/usr/lib/ivette" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && objdump -T "$1" 2>/dev/null' _ {} \; \
            | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n1)"
    fi
    echo "BUILD_BASE=$( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null)"
    echo "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%MZ)"
    echo "BUILD_ROOTS=$BUILD_ROOT $OPAMROOT"
} > "$APPDIR/usr/share/fcai/build-info"
cat "$APPDIR/usr/share/fcai/build-info"
# fail now rather than on the target with "GLIBC_x.y not found"
glibc_too_new() { [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$1" "$GLIBC_MAX" | sort -V | tail -n1)" != "$GLIBC_MAX" ]; }
for key in GLIBC_REQUIRED GLIBC_REQUIRED_IVETTE; do
    need=$(sed -n "s/^$key=//p" "$APPDIR/usr/share/fcai/build-info")
    if glibc_too_new "$need"; then
        find "$APPDIR" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && objdump -T "$1" 2>/dev/null | grep -q "GLIBC_$2[^0-9.]" && echo "  $1"' _ {} "$need" \; \
            | sed "s|$APPDIR/||" | tee "$LOGDIR/glibc-too-new.txt"
        die "$key=$need > GLIBC_MAX=$GLIBC_MAX (files above, in logs/glibc-too-new.txt): build with an older BASE_IMAGE (default ubuntu:20.04), or raise GLIBC_MAX"
    fi
done

say "strings check (informational): build paths embedded in bundle files"
grep -rlaF --exclude=build-info "$BUILD_ROOT" "$APPDIR" | sed "s|$APPDIR/||" | tee "$LOGDIR/embedded-build-paths.txt" || true

# ---------------------------------------------------------- 10. self-test
if [ -z "${SKIP_SELFTEST:-}" ]; then
    say "self-test on the AppDir"
    ST=$(mktemp -d "${TMPDIR:-/tmp}/fcai-selftest.XXXXXX")
    st_rc=0
    (cd "$ST" && env PATH=/usr/local/bin:/usr/bin:/bin bash "$SRC_DIR/delivery/run-tests.sh" "$APPDIR") || st_rc=$?
    rep=$(ls -1 "$ST"/fcai-test-report-*.txt 2>/dev/null | head -n1 || true)
    if [ -n "$rep" ]; then cp "$rep" "$LOGDIR/"; fi
    rm -rf "$ST"
    if [ "$st_rc" != 0 ]; then
        res=$(sed -n '/^---- results/,/^FAIL:/p' "$LOGDIR/$(basename "${rep:-none}")" 2>/dev/null || true)
        fails=$(printf '%s\n' "$res" | awk '$1=="FAIL"{print $2}' | tr '\n' ' ')
        other=$(printf '%s\n' "$res" | awk '$1=="FAIL" && $2 !~ /^ivette-/{print $2}' | tr '\n' ' ')
        if [ -z "$fails" ] || [ -n "$other" ]; then
            die "self-test failed: ${fails:-see report} (report in $LOGDIR)"
        fi
        warn "self-test: only Ivette checks failed ($fails) -- packaging anyway, see the report"
    fi
fi

# ------------------------------------------------------------ 11. AppImage
say "AppImage"
DIST_NAME="frama-c-$FRAMAC_VERSION-offline-x86_64"
DIST="$OUT_DIR/$DIST_NAME"
rm -rf "$DIST"; mkdir -p "$DIST/tests"
AI="$DIST/Frama-C-$FRAMAC_VERSION-x86_64.AppImage"
chmod 755 "$DL/appimagetool.AppImage"
if ! command -v desktop-file-validate >/dev/null; then
    warn "desktop-file-validate missing (package desktop-file-utils); using a no-op stand-in"
    printf '#!/bin/sh\nexit 0\n' > "$BUILD_ROOT/bin/desktop-file-validate"
    chmod 755 "$BUILD_ROOT/bin/desktop-file-validate"
fi
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$DL/appimagetool.AppImage" -n \
    --runtime-file "$DL/runtime-x86_64" "$APPDIR" "$AI"
chmod 755 "$AI"
APPIMAGE_EXTRACT_AND_RUN=1 "$AI" -version

# -------------------------------------------------------- 12. delivery
say "delivery archive"
install -m 755 "$SRC_DIR/delivery/install.sh" "$SRC_DIR/delivery/run-tests.sh" "$DIST/"
cp "$SRC_DIR"/delivery/tests/* "$DIST/tests/"
cp "$SRC_DIR/delivery/README-offline.md" "$DIST/README.md"
cp "$APPDIR/usr/share/fcai/build-info" "$DIST/build-info.txt"
(cd "$DIST" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -C "$OUT_DIR" -cf "$OUT_DIR/$DIST_NAME.tar" "$DIST_NAME"
cp "$LOG" "$OUT_DIR/"
latest=$(ls -1t "$LOGDIR"/fcai-test-report-*.txt 2>/dev/null | head -n1 || true)
if [ -n "$latest" ]; then cp "$latest" "$OUT_DIR/selftest-report.txt"; fi
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT_DIR"; fi

say "done"
ls -la "$OUT_DIR"
echo "Delivery archive: $OUT_DIR/$DIST_NAME.tar   (copy it to the offline machine)"
