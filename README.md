# Relocatable, offline Frama-C bundle (AppImage)

These scripts build a single AppImage containing:

* **Frama-C 33.0**, one executable with every plug-in statically linked, including MetAcsl (E-ACSL excluded);
* **`frama-c-script`**, with its Python helpers and a bundled **Python 3.12 + PyYAML**;
* **Ivette**, the Electron GUI, built from the Frama-C sources;
* **Why3 1.8.2** with the provers **Z3 4.13.0, CVC4 1.8, cvc5 1.2.1 and Alt-Ergo 2.6.2**;
* **a C preprocessor** (the `gcc` driver and `cc1`).

The AppImage:

* runs from any directory, and keeps working when copied or renamed;
* needs no network access;
* reads nothing from the machine it was built on;
* needs nothing on the target except glibc ≥ 2.31 (RHEL 9, Debian 11+, Ubuntu 20.04+), `/bin/sh` and basic coreutils. Ivette also uses the host's desktop libraries, like any Electron app.

## Build (online machine)

```sh
./build-in-container.sh          # docker or podman, ubuntu:20.04; recommended
# or natively, on Debian/Ubuntu, with the packages listed in build.sh:
./build.sh
```

Output: `dist/frama-c-33.0-offline-x86_64.tar`, plus `dist/logs/` (build log, self-test report, diagnostics). Logs are cleared at the start of each build; `KEEP_LOGS=1` keeps them.

* **First run.** About 30–60 minutes: OCaml, the opam dependencies and Frama-C are all built from source.
* **Later runs.** Incremental, because opam and the sources are kept in the `fcai-build-<image>` docker volume. `FORCE=framac-static ./build-in-container.sh` redoes one step; `FORCE=all` redoes all of them.
* **Downloads.** Everything is pinned:
  * opam, the provers, appimagetool, the AppImage runtime, patchelf and CPython (python-build-standalone): by SHA256;
  * Node.js: checked against nodejs.org's SHASUMS;
  * PyYAML: git tag, checked against its commit hash.
* **Minimum glibc on targets.** It is the glibc of the build image: `ubuntu:20.04` (the default) gives 2.31. The build fails if any bundled binary needs a glibc newer than `GLIBC_MAX` (default 2.34, i.e. RHEL 9), and lists the offending files in `logs/glibc-too-new.txt`. On a host that is too old, the bundle, `install.sh` and `run-tests.sh` stop with a clear message instead of the loader's `GLIBC_x.y not found`.
* **Ivette.** Built with `make -C ivette dist` and Node.js 22.22.2 (`NODE_VERSION`). `IVETTE_PREBUILT=<file|dir>` uses an existing Ivette AppImage or unpacked app instead, and `WITH_IVETTE=0` leaves Ivette out. The self-test starts Ivette under Xvfb and checks that it runs the bundled `frama-c` as its server.
* **Python for `frama-c-script`.** The Frama-C 33 analysis scripts need Python ≥ 3.10, but RHEL 9 ships 3.9. So the bundle carries a relocatable CPython 3.12 (python-build-standalone, needs glibc ≥ 2.17, about 76 MB) and the pure-Python part of PyYAML 6.0.3, which `make-machdep` needs. `WITH_PYTHON=0` leaves them out; `frama-c-script` then needs a host python3 ≥ 3.10 with PyYAML.
* **Alt-Ergo licence.** Alt-Ergo 2.6 is under the OCamlPro non-commercial licence. `ALTERGO_PKG=alt-ergo-free.2.4.3` uses the free version instead, and `ALTERGO_PKG=` leaves Alt-Ergo out.

## Install and test (offline machine)

```sh
tar xf frama-c-33.0-offline-x86_64.tar && cd frama-c-33.0-offline-x86_64
./run-tests.sh          # -> fcai-test-report-<host>-<date>.txt
./install.sh            # ~/.local/opt + symlinks in ~/.local/bin
```

The installed commands are `frama-c`, `frama-c-script`, `ivette`, `z3`, `cvc4`, `cvc5` and `alt-ergo`. `README.md` inside the archive has the details: `--dir`, `--bin`, `--extract` for machines without FUSE, and `--uninstall`.

## How path independence is achieved (and checked)

| Component | Problem | Solution |
|---|---|---|
| Frama-C plug-ins | loaded with dynlink through findlib, `OCAMLPATH` and absolute paths | `lib/gen_static_exe.py` generates a second executable stanza in the Frama-C source tree. It links the same libraries as `frama-c`, plus every plug-in library the normal build produced, with `-linkall`. It is run with `-no-autoload-plugins`. |
| Frama-C `share/` and `lib/` | dune-site paths are fixed at install time, and `dune install --relocatable` bakes in `<exe>/../` + the *absolute* stage path | `AppRun` always passes the bundle-relative dune-site locations through `DUNE_DIR_LOCATIONS`, which dune-site searches first. Parts of Frama-C (the libc `-I` path, `-print-lib-path`) use the baked entry, so a relative symlink `usr/<stage path> → usr` makes that entry valid too. The build checks that every `-print-share-path` entry of a moved copy exists, and parses a C file with `#include`s. |
| `frama-c-script` | runs `$(frama-c -print-lib-path)/analysis-scripts/*.py` with the host's `python3`, and reads `$(frama-c -print-share-path)`, which prints two lines in the bundle | `lib/patch_script.py` makes both substitutions keep their first line. The helpers (`usr/lib/frama-c/lib`) are shipped. `AppRun` puts the bundled Python, which includes PyYAML, first on `PATH` and clears the host's `PYTHON*` variables. |
| Why3 data | `Config.datadir` and `Config.libdir` point into the opam tree | `AppRun` sets `WHY3DATA` and `WHY3LIB`. `usr/lib/why3` holds Why3's helper programs (`why3server`, `why3cpulimit`): Why3 runs every prover through `why3server`. |
| Prover config | `why3.conf` stores absolute prover paths | At build time, `why3 config detect` is run against the bundled provers and saved as a template. `AppRun` fills it in for the current location of the bundle and points `WHY3CONFIG` at it. |
| C preprocessor | Frama-C runs `gcc -E` from `PATH` | The `gcc` driver (as `gcc-real`) and `cc1` are bundled with the same relative layout, so gcc finds `cc1` relative to itself. `gcc` is a wrapper that always adds `-nostdinc`, so the host's `/usr/include` is never searched. |
| Ivette → frama-c | Ivette starts `frama-c` from `PATH` | `usr/lib/fcai-wrappers/frama-c` comes first on `PATH` and runs `AppRun frama-c`. `AppRun` removes `ARGV0` after using it, so this inner call doesn't start Ivette again. |
| Shared libraries | libgmp and libstdc++ (Frama-C, Z3, Alt-Ergo), libmpc, libmpfr and libisl (cc1) | They are copied **unmodified** into `usr/lib`. Executables get a relative `DT_RPATH` (`$ORIGIN/...`), which glibc also uses for their libraries' dependencies. Adding a RUNPATH to old libraries makes patchelf write misaligned segments that glibc 2.31 rejects, so every patched file is checked for alignment, and `ldd` errors fail the build. Only glibc comes from the host. |
| glibc | binaries need the build image's glibc | The default build image is `ubuntu:20.04`, a `GLIBC_MAX` check runs at build time, and the bundle refuses clearly on older hosts (`FCAI_SKIP_GLIBC_CHECK=1` overrides). |

`run-tests.sh` checks all of this:

* **Prerequisites:** the host glibc.
* **WP:** each prover on its own (each must prove something Qed can't), all provers together (every goal proved), and a negative proof that must fail.
* **Other tools:** Eva with the libc headers, and `frama-c-script` (`find-fun`, plus `make-machdep --help`, which needs PyYAML).
* **Locations:** the bundle mounted, extracted, copied, renamed, from a path containing spaces, and with the original deleted.
* **Isolation:** a concurrent job, a job without network access (`unshare -rn`), and an `strace` of every file touched, which fails if anything under the build paths, or a host compiler, prover or why3/frama-c install, is used.

## Files

```
build.sh                  the build (steps are stamped and resumable)
build-in-container.sh     runs build.sh in ubuntu:20.04 via docker/podman
lib/gen_static_exe.py     generates the statically linked frama-c stanza
lib/patch_script.py       makes frama-c-script use the first -print-share/lib-path line
lib/bundle_libs.py        copies shared libraries, sets relative RPATHs on executables, checks alignment
appdir/AppRun             multi-call entry point (frama-c, frama-c-script, ivette, z3, cvc4, cvc5, alt-ergo)
appdir/fcai-wrappers/     'frama-c' as seen by Ivette
delivery/install.sh       offline installer
delivery/run-tests.sh     offline acceptance tests
delivery/README-offline.md  README shipped in the archive
delivery/tests/*.c        WP / Eva samples
dev/mock/                 mocked Frama-C build for development (see below)
CLAUDE.md                 design notes, real-build facts and workflow, for maintainers/agents
```

## Developing without a full build

`dev/mock/run-mock.sh [WORKDIR]` fakes only the network-bound parts: opam, the Frama-C build, the Why3 CLI, Alt-Ergo and Ivette. It uses the real 33.0 `frama-c-script`. It then runs the real `build.sh` from the prover downloads onwards, followed by `run-tests.sh` on the delivered AppImage. Finally it runs failure scenarios:
* a host glibc that is too old;
* a build with too low a `GLIBC_MAX`;
* a host python3 that is too old.

It takes a few minutes and needs GitHub access, gcc and python3. Run it before handing changes over for a real build.
