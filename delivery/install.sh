#!/bin/sh
# install.sh -- offline installer for the Frama-C bundle (no root needed).
#
#   ./install.sh [--dir DIR] [--bin BINDIR] [--extract]
#   ./install.sh --uninstall [--dir DIR] [--bin BINDIR]
#
#   --dir DIR      where the bundle goes      (default: ~/.local/opt/frama-c-VERSION)
#   --bin BINDIR   where command symlinks go  (default: ~/.local/bin)
#   --extract      install the extracted directory instead of the AppImage
#                  (needed when FUSE is unavailable; automatic in that case)
#   --appimage     force AppImage mode even if FUSE seems unavailable
#   --no-links     do not create symlinks
#
# Commands linked into BINDIR: frama-c, frama-c-script, ivette, z3, cvc4, and cvc5 /
# alt-ergo when bundled.  Everything is relative to DIR: moving DIR only requires
# re-running the installer (or fixing the symlinks).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
APPIMAGE=$(ls -1 "$HERE"/*.AppImage 2>/dev/null | grep -iv ivette | head -n1 || true)
[ -n "$APPIMAGE" ] || { echo "no Frama-C *.AppImage next to install.sh" >&2; exit 1; }
BASE=$(basename "$APPIMAGE" .AppImage)          # e.g. Frama-C-33.0-x86_64
VERSION=$(echo "$BASE" | sed -n 's/^Frama-C-\([^-]*\)-.*/\1/p')
DIR="$HOME/.local/opt/frama-c-${VERSION:-bundle}"
BIN="$HOME/.local/bin"
MODE=auto LINKS=1 UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR=$2; shift ;;
        --bin) BIN=$2; shift ;;
        --extract) MODE=extract ;;
        --appimage) MODE=appimage ;;
        --no-links) LINKS=0 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$DIR" in
    *:*) echo "DIR must not contain ':' ($DIR)" >&2; exit 2 ;;
    *" "*) echo "warning: DIR contains spaces; this is not recommended" >&2 ;;
esac

CMDS="frama-c frama-c-script ivette z3 cvc4 cvc5 alt-ergo"

if [ $UNINSTALL = 1 ]; then
    [ -d "$DIR" ] && DIR=$(cd "$DIR" && pwd)
    for c in $CMDS; do
        l="$BIN/$c"
        if [ -L "$l" ]; then
            case "$(readlink "$l")" in "$DIR"/*) rm -f "$l"; echo "removed $l" ;; esac
        fi
    done
    [ -d "$DIR" ] && rm -rf "$DIR" && echo "removed $DIR"
    exit 0
fi

# glibc: refuse early, with a clear message, on a host older than the bundle
need=$(sed -n 's/^GLIBC_REQUIRED=//p' "$HERE/build-info.txt" 2>/dev/null | head -n1)
have=${FCAI_HOST_GLIBC:-$(getconf GNU_LIBC_VERSION 2>/dev/null | sed -n 's/^glibc //p')}
if [ -n "$need" ] && [ -n "$have" ] && [ -z "${FCAI_SKIP_GLIBC_CHECK:-}" ] &&
   [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)" != "$need" ]; then
    echo "error: this system has glibc $have, but the bundle needs glibc >= $need" >&2
    echo "       (see build-info.txt; rebuild with an older BASE_IMAGE, or set FCAI_SKIP_GLIBC_CHECK=1)" >&2
    exit 1
fi

chmod +x "$APPIMAGE"
if [ $MODE = auto ]; then
    if "$APPIMAGE" --fcai-info >/dev/null 2>&1; then MODE=appimage; else
        echo "note: the AppImage cannot be mounted here (FUSE unavailable?), installing the extracted form"
        MODE=extract
    fi
fi

mkdir -p "$DIR"
DIR=$(cd "$DIR" && pwd)
if [ $MODE = appimage ]; then
    cp -f "$APPIMAGE" "$DIR/$BASE.AppImage"
    chmod 755 "$DIR/$BASE.AppImage"
    TARGET="$DIR/$BASE.AppImage"
else
    tmp=$(mktemp -d "$DIR/.extract.XXXXXX")
    (cd "$tmp" && "$APPIMAGE" --appimage-extract >/dev/null)
    rm -rf "$DIR/$BASE"
    mv "$tmp/squashfs-root" "$DIR/$BASE"
    rmdir "$tmp"
    TARGET="$DIR/$BASE/AppRun"
fi
echo "installed: $TARGET"

if [ $LINKS = 1 ]; then
    mkdir -p "$BIN"
    avail=$("$TARGET" --fcai-help 2>/dev/null | sed -n '/^Bundled commands:/,$p' | sed 1d | tr -d ' ')
    for c in $avail; do
        ln -sfn "$TARGET" "$BIN/$c"
        echo "linked:    $BIN/$c"
    done
    case ":$PATH:" in
        *":$BIN:"*) ;;
        *) echo "note: $BIN is not in PATH; add:  export PATH=\"$BIN:\$PATH\"" ;;
    esac
fi
echo "check:     frama-c -version     (or: $TARGET -version)"
