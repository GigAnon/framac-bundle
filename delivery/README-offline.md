# Frama-C offline bundle

This bundle contains one file, `Frama-C-<version>-x86_64.AppImage`, which holds everything needed:

* **Frama-C.** One executable with all of its plug-ins (WP, Eva, RTE, …) statically linked in.
* **`frama-c-script`.** Frama-C's helper commands (`find-fun`, `list-files`, `make-machdep`, `summary`, …), with their Python scripts.
* **Python 3.12 with PyYAML.** Only `frama-c-script` uses it; the analysis scripts need Python ≥ 3.10, and the host's Python is not used.
* **Ivette.** The Frama-C GUI, an Electron app, which replaces the GTK GUI removed in Frama-C 33.
* **Why3.** Linked into Frama-C as a library, and also available as the `why3` command (`why3 prove`, `why3 config`, `why3 replay`, …), together with its data files.
* **Provers.** Z3, CVC4 and, when they were included in the build, cvc5 and Alt-Ergo.
* **A C preprocessor.** The `gcc` driver and `cc1` only, so Frama-C does not rely on the host having gcc.

Nothing is downloaded at run time. Nothing is read from where the bundle was built, and the bundle works from any directory. The host has to provide only the Linux kernel, glibc (at least `GLIBC_REQUIRED` from `build-info.txt`; on an older system the bundle stops with a clear message, and `FCAI_SKIP_GLIBC_CHECK=1` makes it try anyway), `/bin/sh`, and basic coreutils such as `sed`, `cut`, `cksum` and `mktemp`.

## Install (no root, no network)

```sh
tar xf frama-c-<version>-offline-x86_64.tar
cd frama-c-<version>-offline-x86_64
sha256sum -c SHA256SUMS
./install.sh                       # ~/.local/opt/frama-c-<version> + links in ~/.local/bin
                                   # (as root: /opt/frama-c-<version> + /usr/local/bin)
./install.sh --dir /opt/fc --bin /usr/local/bin   # anywhere else
./install.sh --extract             # unpacked directory instead of the AppImage
./install.sh --uninstall           # removes what was installed
```

The installer creates symlinks `frama-c`, `frama-c-script`, `ivette`, `why3`, `z3`, `cvc4` (and `cvc5`, `alt-ergo` when they are bundled). All of them point to the same AppImage, which picks the tool to run from the name it was called under.

**Without FUSE.** An AppImage mounts itself with FUSE. When FUSE is not available, `install.sh` switches to `--extract` automatically. You can also run the AppImage without installing it:

* `./Frama-C-*.AppImage --appimage-extract` unpacks it into `squashfs-root/`. That directory can be moved anywhere, and `squashfs-root/AppRun` works like the AppImage.
* `APPIMAGE_EXTRACT_AND_RUN=1 ./Frama-C-*.AppImage …` unpacks it on every run. This is slower.

**Without installing.** Pass the command name as the first argument:

```sh
./Frama-C-*.AppImage -wp -wp-prover z3,cvc4 file.c   # frama-c is the default command
./Frama-C-*.AppImage z3 --version
./Frama-C-*.AppImage frama-c-script help
./Frama-C-*.AppImage --fcai-version # bundle version: <Frama-C version>-<bundle revision>, e.g. 33.0-1.0
./Frama-C-*.AppImage --fcai-info    # versions, required glibc
./Frama-C-*.AppImage --fcai-help
```

## Bash completion

`install.sh` does not touch anyone's home directory. Each user who wants completion for `frama-c`, `ivette` and `frama-c-script` runs:

```sh
setup_completion.sh                # links it into ~/.local/share/bash-completion/completions
setup_completion.sh --uninstall
sudo setup_completion.sh --system  # for all users, in bash-completion's system directory
```

New shells load it through bash-completion. If bash-completion is not installed, `setup_completion.sh` adds one marked line to `~/.bashrc`; `--no-bashrc` skips that, and `--uninstall` removes it. Without installing anything:

```sh
source <(./Frama-C-*.AppImage --fcai-completion)
```

It was generated from this Frama-C's own help. It completes:
* every kernel and plug-in option, including the `-no-…` forms;
* `-machdep` values;
* prover lists for `-wp-prover` (comma-separated: `alt-ergo,z3`);
* file arguments and C sources;
* `frama-c-script` commands.

Pressing TAB never starts Frama-C.

The upstream `autocomplete_frama-c` script is also shipped, in `usr/share/frama-c/share/` inside the AppImage.

## How provers are configured

On every start, the bundle writes a `why3.conf` that points at the provers inside the current location of the bundle. It goes to `$XDG_RUNTIME_DIR/fcai-<uid>/`, or to `/tmp/fcai-<uid>/` if that is not available. Frama-C/WP is started with `WHY3CONFIG`, `WHY3DATA` and `WHY3LIB` set to these bundled files, so `~/.why3.conf` is not read and not modified. This applies to `frama-c`/WP, `why3` and Ivette alike.

To use your own configuration, set Why3's usual variable, for example `export WHY3CONFIG=~/.why3.conf`; the bundle then uses that file as is. `FCAI_WHY3CONFIG=/path/to/why3.conf` does the same and takes precedence. The provers listed in such a file are run from the paths it gives. To make a configuration for the bundled provers, start from the generated one: `frama-c --fcai-run sh -c 'cat "$WHY3CONFIG"' > my-why3.conf`.

C files are preprocessed with the bundled `gcc -E`, using Frama-C's own libc headers. To use the host's gcc instead, set `FCAI_HOST_CPP=1`.

## frama-c-script

```sh
frama-c-script help
frama-c-script find-fun main src/
frama-c-script make-machdep --help
```

It runs the bundled Frama-C and the bundled Python, with PyYAML included. The host's `python3` and any `PYTHONPATH`/`PYTHONHOME` are ignored. A few commands call other host tools:
* `make-wrapper` and `summary` drive `make`;
* `creduce` needs C-Reduce;
* `flamegraph` opens a browser.

PyYAML is the pure-Python version: YAML loading is slower than with libyaml, and `yaml.CLoader` is not available.

## Ivette (GUI)

```sh
ivette file.c -eva                       # after install.sh
./Frama-C-*.AppImage ivette file.c -wp   # without installing
```

Ivette starts `frama-c` as its server. Inside the bundle, the first `frama-c` on `PATH` is a small wrapper that runs the bundled Frama-C with the bundle's environment, so Ivette never uses a Frama-C installed on the host. Double-clicking the AppImage in a file manager also opens Ivette.

**Host requirements.** Like every Electron app, Ivette takes the desktop libraries from the host: GTK 3, NSS, ALSA, libgbm, X11 or Wayland. Any desktop installation has them, and `run-tests.sh` lists any that are missing. Frama-C and the provers do not need them.

**Sandbox.** Chromium's sandbox needs either unprivileged user namespaces or a setuid-root helper. A setuid helper is impossible inside an AppImage or a user-owned folder. So the bundle keeps the sandbox on when user namespaces work, and otherwise starts Ivette with `--no-sandbox`, as it also does when running as root. Ivette only displays local content. To force the choice, set `FCAI_IVETTE_SANDBOX=1` or `0`.

## Testing

```sh
./run-tests.sh                 # tests the AppImage next to this file
./run-tests.sh ~/.local/bin/frama-c    # or an installed copy
```

The script needs no network access. It writes `fcai-test-report-<host>-<date>.txt` in the current directory; send that file back if something fails.

What it tests:
* **Prerequisites:** the host glibc first; if it is too old, it stops there.
* **Frama-C:** the version, the share paths, the bundled preprocessor and the plug-ins.
* **Provers:** each one on its own, all of them together, and a proof that must fail. Eva runs too.
* **`frama-c-script`:** `find-fun` and `make-machdep --help`.
* **Ivette:** the bundled `frama-c` wrapper, the host's desktop libraries, and a launch.
* **Locations:** the AppImage mounted and extracted, a copied, renamed and moved bundle, and a path containing spaces. That case is a known limitation: Frama-C does not quote its libc path, so avoid spaces in the install directory.
* **Isolation:** concurrent runs, a run without network (`unshare -rn`), and an `strace` check that nothing from the build machine or the host's toolchain or provers is used.
