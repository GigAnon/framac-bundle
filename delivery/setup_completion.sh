#!/bin/sh
# setup_completion.sh -- enable bash completion of frama-c, ivette,
# frama-c-script and why3 for the user running it (no root needed), or system-wide.
#
#   setup_completion.sh              for the current user
#   setup_completion.sh --system     for all users (root): bash-completion's
#                                    system directory
#   setup_completion.sh --uninstall [--system]
#   setup_completion.sh --print      print the completion script
#
# The completion script (frama-c-completion.bash) sits next to this file in
# the Frama-C bundle's install directory; it is linked, not copied, so a
# re-install of the bundle updates it for everyone.
# Per user, it goes to ${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions,
# which bash-completion loads on demand.  If bash-completion is not
# installed, a line sourcing it is added to ~/.bashrc instead (--no-bashrc
# to skip; removed by --uninstall).
set -eu

SELF=$(readlink -f -- "$0")
HERE=${SELF%/*}
COMP="$HERE/frama-c-completion.bash"
SYSTEM=0 UNINSTALL=0 BASHRC=1
for a in "$@"; do
    case "$a" in
        --system) SYSTEM=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --no-bashrc) BASHRC=0 ;;
        --print) cat "$COMP"; exit 0 ;;
        -h|--help) sed -n '2,19p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
    esac
done
[ -f "$COMP" ] && head -n1 "$COMP" | grep -q '^# fcai-completion' \
    || { echo "error: no completion script at $COMP" >&2; exit 1; }

MARK="# frama-c bundle completion (setup_completion.sh)"
if [ $SYSTEM = 1 ]; then
    DEST=""
    for d in /usr/share/bash-completion/completions /etc/bash_completion.d; do
        if [ -d "$d" ]; then DEST=$d; break; fi
    done
    [ -n "$DEST" ] || { echo "error: no system bash-completion directory (is bash-completion installed?)" >&2; exit 1; }
    [ -w "$DEST" ] || { echo "error: $DEST is not writable (run as root, or without --system)" >&2; exit 1; }
else
    DEST="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
fi

if [ $UNINSTALL = 1 ]; then
    for c in frama-c frama-c-script ivette why3; do
        f="$DEST/$c"
        if [ -L "$f" ] && [ "$(readlink -- "$f")" = "$COMP" ] || [ "$(readlink -- "$f" 2>/dev/null)" = frama-c ]; then
            rm -f "$f"; echo "removed $f"
        fi
    done
    if [ $SYSTEM = 0 ] && [ -f "$HOME/.bashrc" ] && grep -qF "$MARK" "$HOME/.bashrc"; then
        tmp=$(mktemp "$HOME/.bashrc.XXXXXX")
        grep -vF "$MARK" "$HOME/.bashrc" > "$tmp" || true
        cat "$tmp" > "$HOME/.bashrc"; rm -f "$tmp"
        echo "removed the completion line from ~/.bashrc"
    fi
    exit 0
fi

mkdir -p "$DEST"
ln -sfn "$COMP" "$DEST/frama-c"
# bash-completion loads a completion by command name
ln -sfn frama-c "$DEST/frama-c-script"
ln -sfn frama-c "$DEST/ivette"
ln -sfn frama-c "$DEST/why3"
echo "installed: $DEST/frama-c (+ frama-c-script, ivette, why3)"

has_bash_completion=0
for f in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
    [ -f "$f" ] && has_bash_completion=1
done
if [ $SYSTEM = 0 ] && [ $has_bash_completion = 0 ]; then
    if [ $BASHRC = 1 ]; then
        if ! grep -qF "$MARK" "$HOME/.bashrc" 2>/dev/null; then
            printf '[ -f "%s" ] && . "%s"  %s\n' "$DEST/frama-c" "$DEST/frama-c" "$MARK" >> "$HOME/.bashrc"
        fi
        echo "bash-completion is not installed: added a line to ~/.bashrc"
    else
        echo "bash-completion is not installed: add to ~/.bashrc:  . $DEST/frama-c"
    fi
fi
echo "open a new shell (or run: . $DEST/frama-c) and try: frama-c -wp-<TAB>"
