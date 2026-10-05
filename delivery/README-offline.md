# Frama-C offline bundle

This bundle contains one file, `Frama-C-<version>-x86_64.AppImage`, which holds everything needed:

* **Frama-C.** One executable with all of its plug-ins (WP, Eva, RTE, …) statically linked in.
* **Ivette.** The Frama-C GUI, an Electron app, which replaces the GTK GUI removed in Frama-C 33.
* **Why3.** Linked into Frama-C as a library, together with its data files.
* **Provers.** Z3, CVC4 and, when they were included in the build, cvc5 and Alt-Ergo.
* **A C preprocessor.** The `gcc` driver and `cc1` only, so Frama-C does not rely on the host having gcc.

Nothing is downloaded at run time. Nothing is read from where the bundle was built, and the bundle works from any directory. The host has to provide only the Linux kernel, glibc (at least `GLIBC_REQUIRED` from `build-info.txt`; on an older system the bundle stops with a clear message, and `FCAI_SKIP_GLIBC_CHECK=1` makes it try anyway), `/bin/sh`, and basic coreutils such as `sed`, `cut`, `cksum` and `mktemp`.

## Install (no root, no network)

```sh
tar xf frama-c-<version>-offline-x86_64.tar
cd frama-c-<version>-offline-x86_64
sha256sum -c SHA256SUMS
./install.sh                       # ~/.local/opt/frama-c-<version> + links in ~/.local/bin
./install.sh --dir /opt/fc --bin /usr/local/bin   # anywhere else
./install.sh --extract             # unpacked directory instead of the AppImage
./install.sh --uninstall           # removes what was installed
```

The installer creates symlinks `frama-c`, `ivette`, `z3`, `cvc4` (and `cvc5`, `alt-ergo` when they are bundled). All of them point to the same AppImage, which picks the tool to run from the name it was called under.

**Without FUSE.** An AppImage mounts itself with FUSE. When FUSE is not available, `install.sh` switches to `--extract` automatically. You can also run the AppImage without installing it:

* `./Frama-C-*.AppImage --appimage-extract` unpacks it into `squashfs-root/`. That directory can be moved anywhere, and `squashfs-root/AppRun` works like the AppImage.
* `APPIMAGE_EXTRACT_AND_RUN=1 ./Frama-C-*.AppImage …` unpacks it on every run. This is slower.

**Without installing.** Pass the command name as the first argument:

```sh
./Frama-C-*.AppImage -wp -wp-prover z3,cvc4 file.c   # frama-c is the default command
./Frama-C-*.AppImage z3 --version
./Frama-C-*.AppImage --fcai-info    # versions, required glibc
./Frama-C-*.AppImage --fcai-help
```

## How provers are configured

On every start, the bundle writes a `why3.conf` that points at the provers inside the current location of the bundle. It goes to `$XDG_RUNTIME_DIR/fcai-<uid>/`, or to `/tmp/fcai-<uid>/` if that is not available. Frama-C/WP is started with `WHY3CONFIG`, `WHY3DATA` and `WHY3LIB` set to these bundled files, so `~/.why3.conf` is not read and not modified. To use your own configuration instead, set `FCAI_WHY3CONFIG=/path/to/why3.conf`.

C files are preprocessed with the bundled `gcc -E`, using Frama-C's own libc headers. To use the host's gcc instead, set `FCAI_HOST_CPP=1`.

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

The script needs no network access. It writes `fcai-test-report-<host>-<date>.txt` in the current directory.
