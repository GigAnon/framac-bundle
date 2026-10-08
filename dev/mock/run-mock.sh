#!/usr/bin/env bash
# run-mock.sh -- exercise the whole bundle pipeline WITHOUT building Frama-C.
#
# The real build needs opam.ocaml.org / frama-c.com and ~1 h.  This harness
# fakes only the network-bound steps (opam, the Frama-C build, Why3 CLI,
# Alt-Ergo, the Ivette Electron app) with small mocks that reproduce the
# behaviours observed on the real build (see CLAUDE.md, "real-build facts"),
# then runs the REAL build.sh from step 5 on: prover downloads (GitHub), AppDir
# assembly, bundled gcc preprocessor, bundle_libs.py, relocation check, Why3
# config template, self-test (run-tests.sh), appimagetool, delivery archive.
# Finally it untars the delivery archive elsewhere and runs run-tests.sh on
# the AppImage, like on the offline target.
#
#   dev/mock/run-mock.sh [WORKDIR]        (default: <repo>/_mock)
#   IVETTE_MOCK=bad  -> an Ivette that never starts frama-c (tests the
#                       "only Ivette checks failed" path)
#
# Needs: bash, gcc, python3, curl, unzip, file, objdump, strace (optional),
# xvfb-run (optional), FUSE (optional).  patchelf is fetched if missing.
set -euo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
MOCKSRC="$REPO/dev/mock"
W=$(readlink -f "${1:-$REPO/_mock}")
R="$W/root"                      # BUILD_ROOT of the mocked build
mkdir -p "$W"

# --- patchelf ---------------------------------------------------------------
if ! command -v patchelf >/dev/null; then
    if [ ! -x "$W/patchelf/bin/patchelf" ]; then
        mkdir -p "$W/patchelf"
        curl -fsSL https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz \
            | tar xz -C "$W/patchelf"
    fi
    export PATH="$W/patchelf/bin:$PATH"
fi

# --- fake opam + stamps: build.sh skips steps 0-4 -----------------------------
mkdir -p "$R/bin" "$R/stamps" "$R/src/frama-c-33.0" "$W/mockbin"
for s in system-packages opam-init opam-switch opam-deps framac-source framac-build framac-static; do
    touch "$R/stamps/$s"
done
echo "LGPL (mock)" > "$R/src/frama-c-33.0/LICENSE"
cat > "$R/bin/opam" <<EOF
#!/bin/bash
# mock opam: 'opam exec ... -- CMD' runs CMD with the mock tools first in PATH
if [ "\$1" = exec ]; then shift; while [ "\$1" != "--" ]; do shift; done; shift
    PATH="$W/mockbin:\$PATH" exec "\$@"; fi
if [ "\$1" = var ]; then echo /nonexistent; exit 0; fi
echo "mock opam: \$*" >&2
EOF
chmod +x "$R/bin/opam"

# --- fake stage (what 'dune install --relocatable' produced) -------------------
STAGE="$R/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/bin" "$STAGE/share/frama-c/share/libc" \
    "$STAGE/share/frama-c/share/machdeps" "$STAGE/lib/frama-c/plugins"
sed "s|@STAGE@|$STAGE|g" "$MOCKSRC/frama-c-static.in" > "$STAGE/bin/frama-c-static"
chmod +x "$STAGE/bin/frama-c-static"
for h in stdio.h string.h stdint.h limits.h stdlib.h; do
    echo "/* mock $h */ int printf(const char*, ...); unsigned long strlen(const char*); char* strcpy(char*,const char*); typedef int int32_t;" \
        > "$STAGE/share/frama-c/share/libc/$h"
done

install -m 755 "$MOCKSRC/frama-c-script" "$STAGE/bin/frama-c-script"
# the real 33.0 frama-c-script runs $(frama-c -print-lib-path)/analysis-scripts/*.py
install -D -m 755 "$MOCKSRC/find_fun.py" "$STAGE/lib/frama-c/lib/analysis-scripts/find_fun.py"
install -D -m 755 "$MOCKSRC/make_machdep.py" "$STAGE/lib/frama-c/lib/make_machdep/make_machdep.py"

# --- fake Why3 CLI / data / libdir, fake alt-ergo ------------------------------
mkdir -p "$W/why3data/drivers" "$W/why3lib"
echo "(* mock driver *)" > "$W/why3data/drivers/z3.drv"
# why3server: an ELF depending on libraries laid out like ubuntu:20.04's
# libmpc.so.3 (old binutils: 2 MiB p_align, no separate-code), with an
# absolute RUNPATH into the build root.  Real failure: patchelf 0.18 adding a
# RUNPATH to such a library -> glibc 2.31: "ELF load command address/offset
# not properly aligned".  bundle_libs.py must leave them aligned and loadable.
OLD="$R/oldlibs"; rm -rf "$OLD"; mkdir -p "$OLD"
OLDLD="-Wl,-z,max-page-size=0x200000 -Wl,-z,noseparate-code"
printf 'int fcai_old2(void){ return 41; }\n' > "$OLD/old2.c"
printf 'int fcai_old2(void);\nint fcai_old(void){ return fcai_old2() + 1; }\n' > "$OLD/old.c"
printf '#include <stdio.h>\nint fcai_old(void);\nint main(void){ if (fcai_old() != 42) return 1; puts("why3server-ok"); return 0; }\n' > "$OLD/server.c"
# shellcheck disable=SC2086
gcc -shared -fPIC -O2 $OLDLD -o "$OLD/libfcaiold2.so.1" -Wl,-soname,libfcaiold2.so.1 "$OLD/old2.c"
# shellcheck disable=SC2086
gcc -shared -fPIC -O2 $OLDLD -o "$OLD/libfcaiold.so.1" -Wl,-soname,libfcaiold.so.1 "$OLD/old.c" \
    "$OLD/libfcaiold2.so.1" -Wl,--enable-new-dtags,-rpath,"$OLD"
gcc -O2 -o "$W/why3lib/why3server" "$OLD/server.c" "$OLD/libfcaiold.so.1" -Wl,--enable-new-dtags,-rpath,"$OLD"
"$W/why3lib/why3server" | grep -q why3server-ok || { echo "mock why3server does not run"; exit 1; }
sed -e "s|@WHY3LIB@|$W/why3lib|" -e "s|@WHY3DATA@|$W/why3data|" "$MOCKSRC/why3.in" > "$W/mockbin/why3"
chmod +x "$W/mockbin/why3"
install -m 755 "$MOCKSRC/alt-ergo" "$W/mockbin/alt-ergo"

# --- fake Ivette (an ELF that starts 'frama-c -server-socket' from PATH) ------
IV="$W/ivette-src/dist/linux-unpacked"
rm -rf "$W/ivette-src"; mkdir -p "$IV/resources"
if [ "${IVETTE_MOCK:-}" = bad ]; then
    printf '#include <unistd.h>\nint main(void){sleep(200);return 0;}\n' > "$W/bad-ivette.c"
    gcc -O2 -o "$IV/ivette" "$W/bad-ivette.c"
else
    gcc -O2 -o "$IV/ivette" "$MOCKSRC/mock-ivette.c"
fi
cp /bin/true "$IV/chrome-sandbox"; echo asar > "$IV/resources/app.asar"; echo MIT > "$IV/LICENSE.electron.txt"

# --- the real build.sh, from step 5 on ---------------------------------------
rm -rf "$W/dist" "${XDG_RUNTIME_DIR:-/tmp}/fcai-$(id -u)" "/tmp/fcai-$(id -u)"
echo "==> build.sh (mocked Frama-C), log: $W/build.out"
rc=0
# the mock bundles this machine's gcc: allow this machine's glibc
HOST_GLIBC=$(getconf GNU_LIBC_VERSION | sed 's/^glibc //')
(cd "$W" && BUILD_ROOT="$R" OUT_DIR="$W/dist" IVETTE_PREBUILT="$W/ivette-src" EXTRA_PLUGINS= \
    GLIBC_MAX="$HOST_GLIBC" bash "$REPO/build.sh") > "$W/build.out" 2>&1 || rc=$?
grep -E '^(PASS|FAIL|WARN|SKIP|INFO) |ERROR|WARNING' "$W/build.out" | sort -u || true
[ $rc = 0 ] || { echo "build.sh FAILED (rc=$rc), see $W/build.out"; exit $rc; }

# --- the delivery archive, as on the offline target ----------------------------
T="$W/target"; rm -rf "$T"; mkdir -p "$T/home"
tar -C "$T" -xf "$W/dist"/frama-c-*-offline-x86_64.tar
echo "==> run-tests.sh on the delivered AppImage, log: $T/out.txt"
rc=0
(cd "$T" && env -i HOME="$T/home" PATH=/usr/local/bin:/usr/bin:/bin ${DISPLAY:+DISPLAY=$DISPLAY} \
    bash "$T"/frama-c-*-offline-x86_64/run-tests.sh) > "$T/out.txt" 2>&1 || rc=$?
echo "PASS: $(grep -c '^PASS' "$T/out.txt")"
grep -E '^(FAIL|WARN|SKIP) ' "$T/out.txt" | sort -u || true
[ $rc = 0 ] || exit $rc

# --- glibc too old on the target (real: bundle built on ubuntu:22.04 = glibc
#     2.35, run on RHEL 9 = glibc 2.34 -> "GLIBC_2.35 not found") -------------
# simulated with FCAI_HOST_GLIBC=2.17: AppRun, run-tests.sh and install.sh must
# all refuse with a clear message
echo "==> glibc-too-old scenarios (FCAI_HOST_GLIBC=2.17)"
G="$W/glibc"; rm -rf "$G"; mkdir -p "$G/home"
D=$(echo "$T"/frama-c-*-offline-x86_64)
(cd "$G" && "$D"/*.AppImage --appimage-extract >/dev/null 2>&1)
gfail() { echo "MOCK FAIL: $*"; exit 1; }
out=$(env -i HOME="$G/home" PATH=/usr/bin:/bin FCAI_HOST_GLIBC=2.17 "$G/squashfs-root/AppRun" frama-c -version 2>&1) \
    && gfail "AppRun ran with an older host glibc: $out"
case "$out" in *"has glibc 2.17, but this bundle needs glibc >="*) echo "ok    AppRun refuses: ${out%%$'\n'*}" ;;
    *) gfail "AppRun message: $out" ;; esac
env -i HOME="$G/home" PATH=/usr/bin:/bin FCAI_HOST_GLIBC=2.17 FCAI_SKIP_GLIBC_CHECK=1 \
    "$G/squashfs-root/AppRun" frama-c -version >/dev/null 2>&1 || gfail "FCAI_SKIP_GLIBC_CHECK=1 not honoured"
echo "ok    FCAI_SKIP_GLIBC_CHECK=1 bypasses the check"
rc=0; (cd "$G" && env -i HOME="$G/home" PATH=/usr/bin:/bin FCAI_HOST_GLIBC=2.17 \
    bash "$D/run-tests.sh") > "$G/tests.out" 2>&1 || rc=$?
[ $rc != 0 ] && grep -q '^FAIL  glibc .*host glibc 2.17 <' "$G/tests.out" && ! grep -q -- '-version' "$G/tests.out" \
    && ls "$G"/fcai-test-report-*.txt >/dev/null 2>&1 \
    || gfail "run-tests.sh did not stop on glibc (rc=$rc, $G/tests.out)"
echo "ok    run-tests.sh: $(grep '^FAIL  glibc' "$G/tests.out" | head -n1 | cut -c1-90)... (stopped, report written)"
rc=0; out=$(env -i HOME="$G/home" PATH=/usr/bin:/bin FCAI_HOST_GLIBC=2.17 sh "$D/install.sh" --dir "$G/inst" 2>&1) || rc=$?
[ $rc != 0 ] && [ ! -e "$G/inst" ] && case "$out" in *"needs glibc >="*) true ;; *) false ;; esac \
    || gfail "install.sh did not refuse (rc=$rc): $out"
echo "ok    install.sh refuses"

# --- build side: a bundled ELF needing glibc > GLIBC_MAX must stop the build --
echo "==> build with GLIBC_MAX=2.17 (must fail, listing the offending files)"
rc=0
(cd "$W" && BUILD_ROOT="$R" OUT_DIR="$G/dist" IVETTE_PREBUILT="$W/ivette-src" EXTRA_PLUGINS= \
    GLIBC_MAX=2.17 SKIP_SELFTEST=1 bash "$REPO/build.sh") > "$G/build.out" 2>&1 || rc=$?
[ $rc != 0 ] && grep -q 'GLIBC_REQUIRED=.* > GLIBC_MAX=2.17' "$G/build.out" && [ -s "$G/dist/logs/glibc-too-new.txt" ] \
    || gfail "build did not stop on GLIBC_MAX (rc=$rc, $G/build.out)"
echo "ok    build stops: $(grep -o 'GLIBC_REQUIRED=[0-9.]* > GLIBC_MAX=2.17' "$G/build.out" | head -n1), files: $(tr -d ' ' < "$G/dist/logs/glibc-too-new.txt" | tr '\n' ' ')"
echo "glibc scenarios: all ok"

# --- host python3 too old (real: focal 3.8, RHEL 9 3.9; the helpers need 3.10)
# frama-c-script must use the BUNDLED python: the host python3 stub reports
# 3.8 and fails if it is asked to run a script
echo "==> frama-c-script with a host python3 that is 3.8 and must not be used"
PY="$W/py38"; rm -rf "$PY"; mkdir -p "$PY"
REALPY=$(command -v python3)
cat > "$PY/python3" <<EOS
#!/bin/sh
if [ "\$1" = -c ]; then shift; c=\$1; shift; exec "$REALPY" -c "import sys; sys.version_info=(3,8,10); \$c" "\$@"; fi
echo "host python3 used: \$*" >&2; exit 99
EOS
chmod +x "$PY/python3"
rc=0; (cd "$G" && env -i HOME="$G/home" PATH="$PY:/usr/bin:/bin" bash "$D/run-tests.sh" --quick) > "$G/py38.out" 2>&1 || rc=$?
grep -q '^PASS  [a-z]*-script .*python: bundled' "$G/py38.out" && ! grep -qE '^(FAIL|WARN)  [a-z]*-script' "$G/py38.out" \
    || gfail "frama-c-script did not run on the bundled python ($G/py38.out)"
echo "ok    $(grep -m1 '^PASS  [a-z]*-script' "$G/py38.out")"
