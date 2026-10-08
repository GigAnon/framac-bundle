#!/usr/bin/env bash
# run-tests.sh -- acceptance tests for the offline Frama-C bundle.
#
# Usage:
#   ./run-tests.sh [TARGET] [--quick] [--keep]
#
#   TARGET  the .AppImage file, or a bundle directory (containing AppRun),
#           or an installed command (e.g. ~/.local/bin/frama-c).
#           Default: the *.AppImage next to this script.
#   --quick only one prover for WP, skip strace/relocation/offline tests
#   --keep  keep the scratch directory
#
# Needs no network.  Writes fcai-test-report-<host>-<date>.txt in the current
# directory: please send that file back.  Exit status 0 iff no test FAILed.
set -u
LC_ALL=C; export LC_ALL

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
TESTS="$SCRIPT_DIR/tests"
QUICK=0 KEEP=0 TARGET=""
for a in "$@"; do
    case "$a" in
        --quick) QUICK=1 ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) TARGET=$a ;;
    esac
done
if [ -z "$TARGET" ]; then
    TARGET=$(ls -1 "$SCRIPT_DIR"/*.AppImage 2>/dev/null | head -n1)
    [ -n "$TARGET" ] || { echo "no TARGET given and no *.AppImage next to $0" >&2; exit 2; }
fi
TARGET=$(readlink -f -- "$TARGET")
if [ -d "$TARGET" ]; then TARGET="$TARGET/AppRun"; fi
[ -x "$TARGET" ] || { echo "not executable: $TARGET" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fcai-test.XXXXXX")
REPORT="$PWD/fcai-test-report-$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt"
LOGS="$WORK/logs"; mkdir -p "$LOGS" "$WORK/home"
# isolated HOME: we also check what the bundle writes there
export HOME="$WORK/home"
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME
unset WHY3CONFIG WHY3DATA WHY3LIB OCAMLPATH DUNE_DIR_LOCATIONS FRAMAC_SHARE
NPAR=$(nproc 2>/dev/null || echo 2); [ "$NPAR" -gt 4 ] && NPAR=4
TO=""; command -v timeout >/dev/null && TO="timeout 900"

RESULTS=()
NFAIL=0 NWARN=0
log() { printf '%s\n' "$*" | tee -a "$WORK/summary.txt"; }
result() { # STATUS ID TEXT
    RESULTS+=("$(printf '%-5s %-28s %s' "$1" "$2" "$3")")
    [ "$1" = FAIL ] && NFAIL=$((NFAIL + 1))
    [ "$1" = WARN ] && NWARN=$((NWARN + 1))
    printf '%-5s %-28s %s\n' "$1" "$2" "$3"
}
# runl ID CMD...   run a command, log stdout+stderr to $LOGS/ID.log, return rc
runl() {
    local id=$1; shift
    { echo "\$ $*"; } > "$LOGS/$id.log"
    local t0=$SECONDS
    $TO "$@" >> "$LOGS/$id.log" 2>&1
    local rc=$?
    echo "[rc=$rc, $((SECONDS - t0))s]" >> "$LOGS/$id.log"
    return $rc
}

# finish: write the report, print the summary, exit (0 iff no FAIL)
finish() {
    {
        echo "############ Frama-C offline bundle -- test report ############"
        cat "$WORK/env.txt"; echo
        echo "---- build info"; cat "$WORK/build-info.txt"; echo
        echo "---- results"; printf '%s\n' "${RESULTS[@]}"; echo
        echo "FAIL: $NFAIL   WARN: $NWARN"; echo
        if [ -f "$WORK/access-report.tsv" ]; then
            echo "---- file-access report (non-standard paths touched during WP+Eva)"
            cat "$WORK/access-report.tsv"; echo
        fi
        echo "---- files created under \$HOME"; cat "$WORK/home-files.txt" 2>/dev/null; echo
        for f in "$LOGS"/*.log; do
            id=$(basename "$f" .log)
            if [ $((NFAIL + NWARN)) -gt 0 ]; then
                echo "==== log $id"; head -n 400 "$f"
            else
                echo "==== log $id (tail)"; tail -n 15 "$f"
            fi
            echo
        done
    } > "$REPORT"

    echo
    echo "===================== SUMMARY ====================="
    printf '%s\n' "${RESULTS[@]}"
    echo "FAIL: $NFAIL   WARN: $NWARN"
    echo "report: $REPORT"
    if [ $KEEP = 1 ]; then echo "scratch kept: $WORK"; else rm -rf "$WORK"; fi
    [ "$NFAIL" = 0 ]; exit
}

# ---------------------------------------------------------------------------
echo "== environment"
{
    echo "date:     $(date -Is)"
    echo "target:   $TARGET"
    echo "kernel:   $(uname -srm)"
    echo "distro:   $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    echo "glibc:    $(getconf GNU_LIBC_VERSION 2>/dev/null || ldd --version 2>&1 | head -n1)"
    echo "cpus:     $(nproc 2>/dev/null)"
    echo "fuse:     /dev/fuse=$([ -e /dev/fuse ] && echo yes || echo no)" \
         "fusermount=$(command -v fusermount || echo none)" \
         "fusermount3=$(command -v fusermount3 || echo none)"
    echo "host gcc: $(command -v gcc || echo none)   host z3: $(command -v z3 || echo none)" \
         "  host why3: $(command -v why3 || echo none)   host frama-c: $(command -v frama-c || echo none)"
    echo "strace:   $(command -v strace || echo none)   unshare: $(command -v unshare || echo none)"
} | tee "$WORK/env.txt"

# ---------------------------------------------------------------------------
# Modes: an AppImage is tested (a) mounted through FUSE, if possible, and
# (b) extracted to a directory.  A directory target is tested as is.
MODES=()
declare -A FC
case "$TARGET" in
    *.AppImage|*.appimage)
        if runl appimage-mount "$TARGET" --fcai-info; then
            MODES+=(appimage); FC[appimage]="$TARGET"
            result PASS appimage-mount "FUSE mount works"
        else
            result WARN appimage-mount "AppImage cannot be mounted (no FUSE?) -- see logs; use 'install.sh --extract'"
        fi
        if (cd "$WORK" && runl appimage-extract "$TARGET" --appimage-extract) \
                && [ -x "$WORK/squashfs-root/AppRun" ]; then
            mv "$WORK/squashfs-root" "$WORK/extracted"
            MODES+=(extracted); FC[extracted]="$WORK/extracted/AppRun"
            result PASS appimage-extract "extraction works (no FUSE needed)"
        else
            result FAIL appimage-extract "--appimage-extract failed"
        fi ;;
    *)
        MODES+=(dir); FC[dir]="$TARGET" ;;
esac
[ ${#MODES[@]} -gt 0 ] || { echo "nothing to test"; exit 1; }

INFO_MODE=${MODES[0]}
"${FC[$INFO_MODE]}" --fcai-info > "$WORK/build-info.txt" 2>&1
echo "== build info"; cat "$WORK/build-info.txt"
binfo() { sed -n "s/^$1=//p" "$WORK/build-info.txt" | head -n1; }
EXP_VERSION=$(binfo FRAMAC_VERSION)
PROVERS=$(binfo PROVERS)
BUILD_ROOTS=$(binfo BUILD_ROOTS)
[ -n "$PROVERS" ] || PROVERS="z3 cvc4"

# glibc: the host must be at least as new as the one the bundle was built
# against; otherwise every program fails with "GLIBC_x.y not found"
HOST_GLIBC=${FCAI_HOST_GLIBC:-$(getconf GNU_LIBC_VERSION 2>/dev/null | sed -n 's/^glibc //p')}
GLIBC_NEED=$(binfo GLIBC_REQUIRED)
GLIBC_NEED_IV=$(binfo GLIBC_REQUIRED_IVETTE)
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
if [ -z "$HOST_GLIBC" ] || [ -z "$GLIBC_NEED" ]; then
    result WARN glibc "cannot compare host glibc '${HOST_GLIBC:-?}' with required '${GLIBC_NEED:-?}'"
elif ! ver_le "$GLIBC_NEED" "$HOST_GLIBC"; then
    result FAIL glibc "host glibc $HOST_GLIBC < $GLIBC_NEED required by the bundle (built on $(binfo BUILD_BASE)): rebuild with an older BASE_IMAGE"
    echo "stopping: nothing in the bundle can run on this host"
    finish
elif [ -n "$GLIBC_NEED_IV" ] && ! ver_le "$GLIBC_NEED_IV" "$HOST_GLIBC"; then
    result FAIL glibc "host glibc $HOST_GLIBC >= $GLIBC_NEED (CLI ok), but Ivette needs $GLIBC_NEED_IV"
else
    result PASS glibc "host glibc $HOST_GLIBC >= required $GLIBC_NEED${GLIBC_NEED_IV:+ (Ivette: $GLIBC_NEED_IV)}"
fi

prover_label() { case "$1" in z3) echo Z3;; cvc4) echo CVC4;; cvc5) echo CVC5;; alt-ergo) echo Alt-Ergo;; *) echo "$1";; esac; }

# parse "[wp] Proved goals:   N / M"  -> "N M"
wp_counts() { grep -E 'Proved goals:' "$1" | tail -n1 | sed -E 's/.*Proved goals: *([0-9]+) *\/ *([0-9]+).*/\1 \2/'; }

mode_tests() {
    local m=$1; local fc=${FC[$m]}
    echo "== mode: $m ($fc)"

    # 1. version
    if runl "$m-version" "$fc" frama-c -version && grep -q "${EXP_VERSION:-.}" "$LOGS/$m-version.log"; then
        result PASS "$m-version" "$(grep -v '^\$\|^\[rc' "$LOGS/$m-version.log" | head -n1)"
    else result FAIL "$m-version" "frama-c -version (see log)"; fi

    # 2. everything resolves inside the bundle
    runl "$m-paths" "$fc" --fcai-run sh -c '
        echo "ROOT=$FCAI_ROOT"
        all=$("$FCAI_ROOT/AppRun" frama-c -print-share-path)
        s=$(printf "%s\n" "$all" | head -n1); echo "SHARE=$s"
        ok=yes
        while IFS= read -r d; do
            [ -d "$d/libc" ] || { ok=no; echo "SHAREBAD=$d"; }
        done <<EOS
$all
EOS
        [ "$ok" = yes ] && echo "SHAREOK=yes"
        echo "GCC=$(command -v gcc)"
        echo "CONF=$WHY3CONFIG"
        echo "WHY3DATA=$WHY3DATA"
        echo "----- why3.conf"; cat "$WHY3CONFIG"'
    local root share gcc conf
    root=$(sed -n 's/^ROOT=//p' "$LOGS/$m-paths.log")
    share=$(sed -n 's/^SHARE=//p' "$LOGS/$m-paths.log")
    gcc=$(sed -n 's/^GCC=//p' "$LOGS/$m-paths.log")
    if [ -n "$root" ] && [ "${share#"$root"/usr/share/}" != "$share" ] \
            && grep -q '^SHAREOK=yes' "$LOGS/$m-paths.log"; then
        result PASS "$m-share-path" "$share"
    else result FAIL "$m-share-path" "share path '$share' is not an existing Frama-C share dir inside '$root'"; fi
    if [ -n "$root" ] && [ "${gcc#"$root"/}" != "$gcc" ]; then
        result PASS "$m-bundled-cpp" "preprocessor: $gcc"
    else result FAIL "$m-bundled-cpp" "gcc resolves to '$gcc', not the bundled one"; fi
    local badconf=0
    sed -n '/^----- why3.conf/,$p' "$LOGS/$m-paths.log" > "$WORK/$m-why3.conf"
    for p in $PROVERS; do grep -qi "name = \"$(prover_label "$p")\"" "$WORK/$m-why3.conf" || badconf=1; done
    grep -E '^ *(path|command) *=' "$WORK/$m-why3.conf" | grep '"/' | grep -v -F "\"$root/" && badconf=1
    local noroot; noroot=$(cat "$WORK/$m-why3.conf"); noroot=${noroot//"$root"/}
    for b in $BUILD_ROOTS; do case "$noroot" in *"$b"*) badconf=1 ;; esac; done
    if [ $badconf = 0 ]; then result PASS "$m-why3-conf" "why3.conf lists: $PROVERS (paths inside bundle)"
    else result FAIL "$m-why3-conf" "why3.conf incomplete or points outside the bundle (see $m-paths log)"; fi

    # 3. statically linked plug-ins
    if runl "$m-plugins" "$fc" frama-c -plugins; then
        local miss=""
        local want="wp eva rte" x
        for x in $(binfo EXTRA_PLUGINS); do x=${x%%.*}; want="$want ${x#frama-c-}"; done
        for p in $want; do grep -qi "$p" "$LOGS/$m-plugins.log" || miss="$miss $p"; done
        if [ -z "$miss" ]; then result PASS "$m-plugins" "present: $want"
        else result FAIL "$m-plugins" "missing:$miss"; fi
    else result FAIL "$m-plugins" "frama-c -plugins failed"; fi

    # 4. prover binaries
    for p in $PROVERS; do
        if runl "$m-$p-version" "$fc" "$p" --version; then
            result PASS "$m-$p-bin" "$(grep -v '^\$\|^\[rc' "$LOGS/$m-$p-version.log" | grep -m1 -i 'version\|[0-9]\.[0-9]')"
        else result FAIL "$m-$p-bin" "$p --version failed"; fi
    done

    # 5. symlink dispatch (as install.sh sets it up)
    mkdir -p "$WORK/links-$m"
    local tgt=$fc; [ "$m" = appimage ] && tgt=$TARGET
    ln -sf "$tgt" "$WORK/links-$m/frama-c"; ln -sf "$tgt" "$WORK/links-$m/z3"
    if runl "$m-link-fc" "$WORK/links-$m/frama-c" -version && runl "$m-link-z3" "$WORK/links-$m/z3" --version \
            && grep -qi 'z3 version' "$LOGS/$m-link-z3.log"; then
        result PASS "$m-symlinks" "frama-c / z3 symlinks dispatch correctly"
    else result FAIL "$m-symlinks" "symlink dispatch (see $m-link-* logs)"; fi

    # 6. frama-c-script: its python helpers are found in the bundled share
    #    dir (python3 comes from the host)
    #    (bundled python, or host python3 >= 3.10 when the bundle has none)
    local pyv bundled_py=""; pyv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
    "$fc" --fcai-run sh -c 'test -x "$FCAI_ROOT/usr/lib/fcai-python/bin/python3"' 2>/dev/null && bundled_py=yes
    if [ -z "$bundled_py" ] && ! command -v python3 >/dev/null; then
        result WARN "$m-script" "no bundled python and no host python3: frama-c-script commands need python >= 3.10"
    elif [ -z "$bundled_py" ] && ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        result WARN "$m-script" "no bundled python, host python3 is $pyv: frama-c-script commands need python >= 3.10"
    elif runl "$m-script-help" "$fc" frama-c-script help \
            && runl "$m-script" "$fc" frama-c-script find-fun main "$TESTS" \
            && grep -q 'eva\.c' "$LOGS/$m-script.log"; then
        result PASS "$m-script" "frama-c-script find-fun found main in tests/eva.c (python: $([ -n "$bundled_py" ] && echo bundled || echo "host $pyv"))"
    else result FAIL "$m-script" "frama-c-script help / find-fun failed (see $m-script* logs)"; fi
    #    make-machdep imports yaml (PyYAML: bundled with the bundled python)
    if [ -n "$bundled_py" ] || python3 -c 'import sys, yaml; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        if runl "$m-script-yaml" "$fc" frama-c-script make-machdep --help \
                && ! grep -qE 'ModuleNotFoundError|ImportError|Traceback' "$LOGS/$m-script-yaml.log"; then
            result PASS "$m-script-yaml" "frama-c-script make-machdep --help (PyYAML importable)"
        else result FAIL "$m-script-yaml" "frama-c-script make-machdep --help failed (see $m-script-yaml log)"; fi
    else
        result WARN "$m-script-yaml" "no bundled python and no host python3 >= 3.10 with PyYAML: make-machdep unavailable"
    fi

    # 6. Why3 prover detection as seen from WP
    runl "$m-wp-detect" "$fc" frama-c -wp-detect; wd=$?
    if grep -q "is unknown" "$LOGS/$m-wp-detect.log"; then
        result SKIP "$m-wp-detect" "no -wp-detect in this Frama-C (prover use is tested below)"
    elif [ $wd = 0 ]; then
        local miss=""
        for p in $PROVERS; do grep -qi "$(prover_label "$p")" "$LOGS/$m-wp-detect.log" || miss="$miss $p"; done
        if [ -z "$miss" ]; then result PASS "$m-wp-detect" "all bundled provers detected"
        else result FAIL "$m-wp-detect" "not detected:$miss"; fi
    else result FAIL "$m-wp-detect" "frama-c -wp-detect failed"; fi

    # 7. WP, one run per prover.  Each prover must actually be run and prove
    #    goals Qed cannot, without any prover error; how many of the harder
    #    (quantified) goals each one closes is its own business (CVC4/cvc5
    #    answer Unknown on some, Z3 may time out) and is only reported.
    local plist=$PROVERS; [ $QUICK = 1 ] && plist=z3
    for p in $plist; do
        local id="$m-wp-$p" lbl n
        lbl=$(prover_label "$p")
        mkdir -p "$WORK/$id"
        (cd "$WORK/$id" && runl "$id" "$fc" frama-c -wp -wp-rte -wp-prover "$p" -wp-timeout 30 \
            -wp-par "$NPAR" "$TESTS/wp_ok.c")
        set -- $(wp_counts "$LOGS/$id.log")
        n=$(grep -iE "^ +$lbl [0-9][^:]*: +[0-9]+" "$LOGS/$id.log" | sed -E 's/.*: +([0-9]+).*/\1/' | head -n1)
        if grep -qE 'anomaly|running prover .* failed|\[Failure\]' "$LOGS/$id.log"; then
            result FAIL "$id" "prover errors (see log)"
        elif [ "${n:-0}" -gt 0 ]; then
            result PASS "$id" "$lbl proved ${n} goal(s); total ${1:-?}/${2:-?}"
        else
            result FAIL "$id" "$lbl proved nothing (total ${1:-?}/${2:-?}, see log)"
        fi
    done
    # all provers together must close every goal of the sample
    if [ $QUICK = 0 ]; then
        local all; all=$(echo $PROVERS | tr ' ' ',')
        mkdir -p "$WORK/$m-wp-all"
        (cd "$WORK/$m-wp-all" && runl "$m-wp-all" "$fc" frama-c -wp -wp-rte -wp-prover "$all" \
            -wp-timeout 30 -wp-par "$NPAR" "$TESTS/wp_ok.c")
        set -- $(wp_counts "$LOGS/$m-wp-all.log")
        if [ -n "${1:-}" ] && [ "$1" = "${2:-x}" ]; then result PASS "$m-wp-all" "all provers together: $1/$2"
        else result FAIL "$m-wp-all" "all provers together: ${1:-?}/${2:-?} (see log)"; fi
    fi

    # 8. WP must NOT prove a false property (checks the prover really answers)
    mkdir -p "$WORK/$m-wp-neg"
    (cd "$WORK/$m-wp-neg" && runl "$m-wp-neg" "$fc" frama-c -wp -wp-prover z3 -wp-timeout 10 "$TESTS/wp_ko.c")
    set -- $(wp_counts "$LOGS/$m-wp-neg.log")
    if [ -n "${1:-}" ] && [ "$1" -lt "$2" ]; then result PASS "$m-wp-negative" "false goal not proved ($1/$2)"
    else result FAIL "$m-wp-negative" "unexpected: ${1:-?}/${2:-?}"; fi

    # 9. Eva + Frama-C libc headers through the bundled preprocessor
    mkdir -p "$WORK/$m-eva"
    if (cd "$WORK/$m-eva" && runl "$m-eva" "$fc" frama-c -eva "$TESTS/eva.c") \
            && grep -qiE 'division.by.zero|division_by_zero' "$LOGS/$m-eva.log"; then
        result PASS "$m-eva" "Eva ran, expected alarm found"
    else result FAIL "$m-eva" "Eva run failed or expected alarm missing"; fi
}

for m in "${MODES[@]}"; do mode_tests "$m"; done

# the remaining tests use the first working mode (preferably extracted/dir)
M=${MODES[-1]}; FCM=${FC[$M]}

# ---------------------------------------------------------------------------
# Ivette (Electron GUI)
if grep -q '^IVETTE=yes' "$WORK/build-info.txt"; then
    echo "== ivette"
    FCI=${FC[${MODES[0]}]}
    # a. inside the bundle, 'frama-c' on PATH is the AppRun wrapper
    runl ivette-wrapper "$FCI" --fcai-run sh -c 'echo "ROOT=$FCAI_ROOT"; echo "FC=$(command -v frama-c)"; frama-c -version'
    root=$(sed -n 's/^ROOT=//p' "$LOGS/ivette-wrapper.log"); w=$(sed -n 's/^FC=//p' "$LOGS/ivette-wrapper.log")
    if [ -n "$root" ] && [ "$w" = "$root/usr/lib/fcai-wrappers/frama-c" ] \
            && grep -q "${EXP_VERSION:-.}" "$LOGS/ivette-wrapper.log"; then
        result PASS ivette-wrapper "frama-c seen by Ivette: bundled wrapper, runs"
    else result FAIL ivette-wrapper "frama-c on the bundle PATH is '$w' (see log)"; fi
    # b. desktop libraries Electron takes from the host
    runl ivette-ldd "$FCI" --fcai-run sh -c 'd="$FCAI_ROOT/usr/lib/ivette"; ldd "$d/$(cat "$d/.fcai-exe")"'
    miss=$(grep 'not found' "$LOGS/ivette-ldd.log" | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -z "$miss" ]; then result PASS ivette-hostlibs "all desktop libraries needed by Electron are present"
    else result WARN ivette-hostlibs "GUI needs host desktop libraries, missing: $miss"; fi
    # c. start it for real (needs a display, or xvfb-run) and check it starts
    #    the bundled frama-c as its server
    RUNNER=()
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then RUNNER=(setsid)
    elif command -v xvfb-run >/dev/null; then RUNNER=(setsid xvfb-run -a)
    fi
    if [ -n "$miss" ]; then
        result SKIP ivette-launch "missing host libraries (see ivette-hostlibs)"
    elif [ ${#RUNNER[@]} = 0 ]; then
        result SKIP ivette-launch "no display (DISPLAY/WAYLAND_DISPLAY unset, no xvfb-run): run the tests from a desktop session"
    elif ! command -v ps >/dev/null || ! command -v setsid >/dev/null; then
        result SKIP ivette-launch "ps/setsid not available"
    else
        mkdir -p "$WORK/ivette"
        : > "$WORK/ivette-trace"
        ( cd "$WORK/ivette" && FCAI_TRACE_FILE="$WORK/ivette-trace" \
            exec "${RUNNER[@]}" "$FCI" ivette "$TESTS/eva.c" -eva ) > "$LOGS/ivette-launch.log" 2>&1 &
        ipid=$!
        found=""
        for _ in $(seq 1 90); do
            sleep 1
            ps -eo pid=,ppid=,args= | awk -v r="$ipid" '
                { pp[$1] = $2; a[$1] = $0 }
                END { s[r] = 1; do { c = 0; for (p in pp) if (!(p in s) && (pp[p] in s)) { s[p] = 1; c = 1 } } while (c)
                      for (p in s) if (p in a) print a[p] }' > "$WORK/ivette-tree.txt"
            # the frama-c wrapper records each call (the server may be short-lived)
            if [ -s "$WORK/ivette-trace" ] || grep -q '/usr/bin/frama-c' "$WORK/ivette-tree.txt"; then
                found=1; break
            fi
            kill -0 "$ipid" 2>/dev/null || break
        done
        { echo "---- frama-c calls made by Ivette"; cat "$WORK/ivette-trace"
          echo "---- process tree"; cat "$WORK/ivette-tree.txt"; } >> "$LOGS/ivette-launch.log"
        [ -n "$found" ] && sleep 10    # let the server answer, errors land in the log
        kill -TERM -- "-$ipid" 2>/dev/null; kill -TERM "$ipid" 2>/dev/null
        awk '{print $1}' "$WORK/ivette-tree.txt" | xargs -r kill -TERM 2>/dev/null
        sleep 2
        kill -KILL -- "-$ipid" 2>/dev/null
        awk '{print $1}' "$WORK/ivette-tree.txt" | xargs -r kill -KILL 2>/dev/null
        wait "$ipid" 2>/dev/null
        if [ -n "$found" ]; then
            result PASS ivette-launch "Ivette started and ran the bundled frama-c as its server"
            result INFO ivette-visual "please also try it by hand: frama-c bundle 'ivette file.c -eva'"
        else
            result FAIL ivette-launch "Ivette did not start the bundled frama-c within 90 s (see log)"
        fi
    fi
else
    result INFO ivette "not bundled in this build"
fi

# ---------------------------------------------------------------------------
if [ $QUICK = 0 ]; then
    echo "== concurrency"
    ( mkdir -p "$WORK/c1" && cd "$WORK/c1" && runl conc-1 "$FCM" frama-c -wp -wp-prover z3 "$TESTS/wp_ok.c" ) &
    p1=$!
    ( mkdir -p "$WORK/c2" && cd "$WORK/c2" && runl conc-2 "${FC[${MODES[0]}]}" frama-c -wp -wp-prover alt-ergo,z3 "$TESTS/wp_ok.c" ) &
    p2=$!
    wait $p1; wait $p2
    set -- $(wp_counts "$LOGS/conc-1.log"); a="${1:-?}/${2:-?}"; ok1=$([ "${1:-0}" = "${2:-x}" ] && echo 1)
    set -- $(wp_counts "$LOGS/conc-2.log"); b="${1:-?}/${2:-?}"; ok2=$([ "${1:-0}" = "${2:-x}" ] && echo 1)
    if [ "$ok1$ok2" = 11 ]; then result PASS concurrency "two simultaneous runs: $a, $b"
    else result FAIL concurrency "two simultaneous runs: $a, $b"; fi

    echo "== relocation"
    if [ "$M" = appimage ] || [[ "$TARGET" == *.AppImage ]]; then
        mkdir -p "$WORK/moved elsewhere"
        cp "$TARGET" "$WORK/moved elsewhere/renamed.AppImage"
        if [ "${MODES[0]}" = appimage ]; then
            RT="$WORK/moved elsewhere/renamed.AppImage"
            (cd "$WORK" && runl reloc-appimage "$RT" frama-c -wp -wp-prover z3 "$TESTS/wp_ok.c")
            set -- $(wp_counts "$LOGS/reloc-appimage.log")
            if [ "${1:-0}" = "${2:-x}" ]; then result PASS reloc-appimage "copied+renamed AppImage: $1/$2"
            else result FAIL reloc-appimage "copied+renamed AppImage: ${1:-?}/${2:-?}"; fi
        fi
    fi
    SRCDIR=$(dirname "$FCM")
    cp -a "$SRCDIR" "$WORK/moved-dir"
    (cd "$WORK" && runl reloc-dir "$WORK/moved-dir/AppRun" frama-c -wp -wp-prover z3 "$TESTS/wp_ok.c")
    set -- $(wp_counts "$LOGS/reloc-dir.log")
    if [ "${1:-0}" = "${2:-x}" ]; then result PASS reloc-dir "copied directory: $1/$2"
    else result FAIL reloc-dir "copied directory: ${1:-?}/${2:-?}"; fi
    # original must no longer be needed: hide it while running the copy
    if [ "$M" != dir ] && mv "$SRCDIR" "$SRCDIR.hidden" 2>/dev/null; then
        (cd "$WORK" && runl reloc-orig-hidden "$WORK/moved-dir/AppRun" frama-c -eva "$TESTS/eva.c")
        mv "$SRCDIR.hidden" "$SRCDIR"
        if grep -qiE 'division.by.zero|division_by_zero' "$LOGS/reloc-orig-hidden.log"; then
            result PASS reloc-orig-hidden "copy works with the original directory gone"
        else result FAIL reloc-orig-hidden "copy fails when the original is gone"; fi
    fi
    cp -a "$SRCDIR" "$WORK/dir with spaces"
    (cd "$WORK" && runl reloc-spaces "$WORK/dir with spaces/AppRun" frama-c -eva "$TESTS/eva.c")
    if grep -qiE 'division.by.zero|division_by_zero' "$LOGS/reloc-spaces.log"; then
        result PASS reloc-spaces "directory path containing spaces works"
    else result WARN reloc-spaces "directory path containing spaces fails (avoid spaces in the install path)"; fi

    echo "== offline (network namespace)"
    if command -v unshare >/dev/null && unshare -rn true 2>/dev/null; then
        (cd "$WORK" && runl offline unshare -rn "$FCM" frama-c -wp -wp-prover z3 "$TESTS/wp_ok.c")
        set -- $(wp_counts "$LOGS/offline.log")
        if [ "${1:-0}" = "${2:-x}" ]; then result PASS offline "WP inside 'unshare -rn' (no network): $1/$2"
        else result FAIL offline "WP without network: ${1:-?}/${2:-?}"; fi
    else
        result SKIP offline "unprivileged 'unshare -rn' not available (machine is offline anyway?)"
    fi

    echo "== file-access trace"
    if command -v strace >/dev/null; then
        mkdir -p "$WORK/trace"
        (cd "$WORK/trace" && runl strace-run strace -f -qq -e trace=file,process -o "$WORK/strace.txt" \
            "$FCM" frama-c -wp -wp-rte -wp-prover "$(echo $PROVERS | tr ' ' ',')" "$TESTS/wp_ok.c" \
            -then -eva "$TESTS/eva.c")
        if [ -s "$WORK/strace.txt" ]; then
            ROOTDIR=$(dirname "$FCM")
            # every path the processes touched, with success/failure
            awk '{
                    if (!match($0, /"\/[^"]*"/)) next
                    p = substr($0, RSTART + 1, RLENGTH - 2)
                    if ($0 ~ /<unfinished/) { print p "\t?\t"; next }
                    if (match($0, / = -?[0-9]+( [A-Z]+)?[^=]*$/)) {
                        n = split(substr($0, RSTART + 3), a, " ")
                        print p "\t" a[1] "\t" (a[2] ~ /^[A-Z]+$/ ? a[2] : "")
                    }
                }' "$WORK/strace.txt" | sort -u > "$WORK/paths.tsv"
            awk -F'\t' -v root="$ROOTDIR" -v work="$WORK" -v roots="$BUILD_ROOTS" '
                function allowed(p) {
                    if (index(p, root "/") == 1 || p == root) return 1
                    if (index(p, work "/") == 1) return 1
                    if (p ~ /^\/(proc|sys|dev)\//) return 1
                    if (p ~ /^\/tmp\/|^\/run\/user\//) return 1
                    if (p ~ /^\/etc\/(ld\.so\.|localtime|nsswitch|passwd|group|host\.conf|resolv\.conf|gai\.conf|fuse\.conf|mtab)/) return 1
                    if (p ~ /^\/(usr\/)?lib(64|32|x32)?\/(x86_64-linux-gnu\/)?(ld-linux|libc\.|libm\.|libdl\.|libpthread\.|librt\.|libutil\.|libresolv\.|libmvec\.|libnss_|libgcc_s\.)/) return 1
                    if (p ~ /^\/(usr\/)?lib(64)?\/(x86_64-linux-gnu\/)?(tls|haswell|x86_64|glibc-hwcaps|\.)/) return 1
                    if (p ~ /^\/(usr\/)?lib(64)?(\/x86_64-linux-gnu)?\/?\.?$/) return 1
                    if (p ~ /^\/(usr\/)?(s)?bin\/(sh|dash|bash|env|fusermount3?)$/) return 1
                    if (p ~ /^\/usr\/(share|lib)\/(locale|zoneinfo)/) return 1
                    return 0
                }
                BEGIN { n = split(roots, R, " ") }
                {
                    p = $1; rc = $2; err = $3
                    if (index(p, root "/") == 1 || p == root || index(p, work "/") == 1) next
                    if (index(root "/", p "/") == 1) next   # an ancestor directory of the bundle
                    for (i = 1; i <= n; i++) if (R[i] != "" && index(p, R[i]) == 1) {
                        if (rc ~ /^-/) print "WARNPROBE\t" p "\t" err; else print "FAILBUILD\t" p; next }
                    if (allowed(p)) next
                    if (p ~ /(\/usr\/(lib|libexec)\/gcc|\/usr\/include|\.opam|\/why3|frama-c|\/(z3|cvc4|cvc5|alt-ergo)$)/) {
                        if (rc ~ /^-/) print "INFOPROBE\t" p "\t" err; else print "FAILHOST\t" p; next }
                    if (rc !~ /^-/) print "INFOOK\t" p
                }' "$WORK/paths.tsv" | sort -u > "$WORK/access-report.tsv"
            nbuild=$(grep -c '^FAILBUILD' "$WORK/access-report.tsv")
            nhost=$(grep -c '^FAILHOST' "$WORK/access-report.tsv")
            nprobe=$(grep -c '^WARNPROBE' "$WORK/access-report.tsv")
            if [ "$nbuild" = 0 ] && [ "$nhost" = 0 ]; then
                result PASS strace-leaks "no successful access to build paths or host toolchain/provers ($nprobe failed probes of build paths)"
            else
                result FAIL strace-leaks "$nbuild build-path and $nhost host-tool accesses (see access report)"
            fi
            [ "$nprobe" -gt 0 ] && result WARN strace-probes "$nprobe failed lookups of build-machine paths (harmless, listed in report)"
            grep -q "execve(\"/usr/bin/gcc\|execve(\"/usr/bin/cpp" "$WORK/strace.txt" \
                && result FAIL strace-host-gcc "host gcc/cpp was executed"
        else
            result SKIP strace-leaks "strace produced no output (ptrace not permitted?)"
        fi
    else
        result SKIP strace-leaks "strace not installed"
    fi
fi

echo "== bash completion"
if "${FC[$INFO_MODE]}" --fcai-completion > "$WORK/completion.bash" 2> "$LOGS/completion.log" \
        && head -n1 "$WORK/completion.bash" | grep -q '^# fcai-completion'; then
    # drive the completion functions the way bash does (no frama-c involved)
    cat > "$WORK/completion-test.sh" <<'EOS'
. "$1"; T=$2
c() { COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
      case "$1" in frama-c-script) _fcai_frama_c_script ;; *) _fcai_frama_c ;; esac
      printf '%s\n' "${COMPREPLY[@]}"; }
fail=0
chk() { # DESC EXPECTED -- WORDS...
    local d=$1 e=$2; shift 3
    if c "$@" | grep -qxF -- "$e"; then echo "ok   $d"; else echo "BAD  $d: '$e' not in: $(c "$@" | head -n 5 | tr '\n' ' ')"; fail=1; fi; }
chk "option prefix"      -wp-prover       -- frama-c -wp-pr
chk "kernel option"      -machdep         -- frama-c -machd
chk "eva option"         -eva             -- frama-c -ev
chk "opposite option"    -no-unicode      -- frama-c -no-unic
chk "machdep value"      x86_64           -- frama-c -machdep x86_6
chk "prover list"        alt-ergo,z3      -- frama-c -wp-prover alt-ergo,z
chk "C source"           "$T/eva.c"       -- frama-c -eva "$T/ev"
chk "ivette"             -wp              -- ivette -wp
chk "script command"     find-fun         -- frama-c-script find-f
echo "options: $(echo $_fcai_opts | wc -w)"
exit $fail
EOS
    if bash "$WORK/completion-test.sh" "$WORK/completion.bash" "$TESTS" >> "$LOGS/completion.log" 2>&1; then
        result PASS completion "bash completion works ($(sed -n 's/^options: //p' "$LOGS/completion.log") options; frama-c, ivette, frama-c-script)"
    else
        result FAIL completion "bash completion: $(grep -c '^BAD' "$LOGS/completion.log") check(s) failed (see completion log)"
    fi
else
    result FAIL completion "--fcai-completion did not print a completion script"
fi

echo "== HOME usage"
(cd "$HOME" && find . -mindepth 1 | sort) > "$WORK/home-files.txt"
result INFO home-writes "$(wc -l < "$WORK/home-files.txt") entries created under \$HOME (listed in report)"

# ---------------------------------------------------------------------------
finish
