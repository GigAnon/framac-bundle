# CLAUDE.md: maintainer and agent notes

Read this before changing anything. `README.md` is the user-facing overview, and `delivery/README-offline.md` ships in the archive. This file holds the *why*, the facts learned from real builds, and the working process.

## Goal and constraints (from the owner)

- **Goal.** Frama-C, Why3 and the provers Z3 and CVC4 (plus cvc5, Alt-Ergo, the MetAcsl plug-in and the Ivette GUI) packaged as a **standalone, fully offline, path-independent** AppImage, with an extractable directory form.
- **Path independence.** The bundle must work from any directory, after being copied or renamed, and with the build machine's paths absent. The owner's warning: opam bakes absolute paths into everything, and that is the whole reason for this project.
- **Option A was chosen.** Frama-C is **one executable with every plug-in statically linked** (`-linkall`, `-no-autoload-plugins`). There is no dynlink, findlib or `OCAMLPATH` at run time.
- **Build machine.** Online. The owner's machine runs Debian 13 and has Docker. A Docker build is fine (`build-in-container.sh`, `ubuntu:22.04` → glibc ≥ 2.35 on targets).
- **Target machine.** Offline, **no Docker**, no root, distro unknown. Installing must be trivial: `./install.sh`.
- **Ivette is required.** The GTK GUI is gone in Frama-C 33. Ivette is built from `ivette/` in the Frama-C sources.
- **MetAcsl is required.** `frama-c-metacsl.0.11`, built inside the Frama-C tree.
- **E-ACSL is not needed.** It is excluded from the static link.
- **Logs are cleared at the start of each build**, at the owner's request. `KEEP_LOGS=1` keeps them.

## How work is done (the loop)

1. The agent edits scripts **and runs `dev/mock/run-mock.sh`**. All of it must pass before anything is handed over.
2. The owner runs `./build-in-container.sh` on the build machine. On failure, everything needed is in `dist/logs/` (build log, test report, `ivette-*.log`, `plugins.txt`, `why3-provers.txt`, `relo-parse.txt`, `embedded-build-paths.txt`). The owner pastes the console tail or attaches files.
3. The agent diagnoses from the logs, fixes the cause, extends the mock so it **reproduces** the observed failure, re-runs the mock, and hands over.
4. Once the build is green, the owner copies `dist/frama-c-33.0-offline-x86_64.tar` to the offline target and runs `./run-tests.sh` there. The `fcai-test-report-*.txt` comes back.

**Messages to the owner.** Keep them short: what failed, the cause, what changed, what to run, what to send back. The owner is technical. Be precise; skip the tutorials.

**The agent's workspace network may be restricted.** In the first session opam.ocaml.org, frama-c.com, git.frama-c.com and nodejs.org were blocked, while GitHub release assets were reachable. A real build was therefore impossible there, which is why the mock exists. Check what is reachable before relying on it. Never try to get around a proxy refusal.

## Pipeline (`build.sh`)

Each step is stamped in `$BUILD_ROOT/stamps`; `FORCE=step` or `FORCE=all` reruns.

| # | Step | Notes |
|---|---|---|
| 0 | system-packages | apt inside the container (not stamped there). Electron runtime libraries + Xvfb when `WITH_IVETTE=1`. |
| 1 | opam binary (pinned SHA256), `opam-init`, `opam-switch` (OCaml 4.14.2), `opam-deps` | Installs `ALTERGO_PKG` first, then `--deps-only frama-c.33.0`. |
| 2 | `framac-source` | `opam source frama-c.33.0`. |
| 2b | vendoring (not stamped) | `EXTRA_PLUGINS` (MetAcsl) is copied into `src/plugins/fcai-extra-<pkg>/` with `opam source`. The `.fcai-<pkg>` marker forces a rebuild when the list changes. |
| 3 | `framac-build` | `dune build --release @install`. Checks that each vendored plug-in registered a dune-site plug-in META. |
| 4 | `framac-static` | `lib/gen_static_exe.py` finds the `frama-c` executable stanza, reads the plug-in libraries from `_build/install/default/lib/frama-c/plugins/*/META`, and writes `src/init/boot/fcai_static/dune`. It then builds and runs `dune install --release --relocatable --prefix $STAGE`. |
| 5 | downloads | Z3 4.13.0 (glibc-2.31 build), CVC4 1.8 (static, CVC4-archived repo), cvc5 1.2.1 (static), appimagetool 1.9.0, type2 runtime 20251108. All pinned by SHA256. |
| 6 | AppDir | The static `frama-c`, `share/`, empty plug-in site dirs, Why3 data and helper programs, provers, the gcc preprocessor (`gcc-real` + a `-nostdinc` wrapper + `cc1`), `bundle_libs.py`, and the `usr$STAGE → usr` symlink. |
| 7 | relocation check | Writes `usr/share/fcai/dune-dir-locations`. Moves a copy; **every** `-print-share-path` entry must exist and contain `libc/`. Parses a C file with `#include`s while the original AppDir is moved away. Runs `-plugins`. |
| 8 | why3.conf template | `why3 config detect` against the bundled provers (`PATH=usr/bin` only). The AppDir path is replaced by `@APPDIR@`, and `datadir`/`libdir` lines are dropped. |
| 8b | Ivette | Node 22.22.2 (checked against nodejs.org SHASUMS) + corepack/yarn 1. Runs `make -C ivette api` then `make -C ivette dist`. The resulting `dist/linux-unpacked` is imported; `IVETTE_PREBUILT` overrides. |
| 9 | build-info | Versions, `GLIBC_REQUIRED`, `BUILD_ROOTS` (used by the strace test), and a strings scan of embedded build paths (informational only). |
| 10 | self-test | `run-tests.sh` on the AppDir, using a clean `PATH`, from `/tmp`. If only `ivette-*` tests fail, the build still packages, with a warning. |
| 11–12 | AppImage + delivery tar | The tar contains: AppImage, `install.sh`, `run-tests.sh`, `tests/`, `README.md`, `build-info.txt`, `SHA256SUMS`. |

## Real-build facts (verified on the owner's machine, Frama-C 33.0)

Do not "fix" these back. Each one was observed in a real log.

- **opam resolution.** It picks dune 3.24.2, why3 1.8.2 and alt-ergo 2.6.2. It downgrades ppxlib to 0.35 for Frama-C (fine).
- **The `frama-c` executable stanza** is in `src/init/boot/dune`: `(executable (name empty_file) (public_name frama-c) (modes byte (best exe)) (modules empty_file) (flags :standard -open Frama_c_kernel -linkall) (libraries frama-c.kernel frama-c.init frama-c.boot))`.
  - `empty_file.ml` is **generated by a rule**, so `gen_static_exe.py` copies it from `_build/default/src/init/boot/`.
  - The main program is the `frama-c.boot` library, so the plug-in libraries are inserted **before** `frama-c.boot`.
- **Plug-ins linked statically.** ACSL importer, Alias, Aorai, Callgraph, Dive, Eva, From, Impact, Inout, Instantiate, Loop, Markdown report, MetAcsl, Metrics, Mthread, Nonterm, Obfuscator, Occurrence, Pdg, Reduction, Region, Report, RteGen, Scope, Security-slicing, Semantic Constant Folding, Server, Server TypeScript API, Slicing, Sparecode, Studia, Volatile, WP.
- **`dune install --relocatable` does NOT produce relative paths.** It bakes `<exe>/../` + the absolute `--prefix` path (`/fcai-build/stage/share/frama-c`), so `-print-share-path` prints two lines. Hence:
  - `DUNE_DIR_LOCATIONS` (always set by `AppRun`, searched first);
  - the symlink alias `usr/fcai-build/stage → ..`, because Frama-C builds the libc `-I` path from the *baked* entry (it failed until the alias was added).
- **`DUNE_DIR_LOCATIONS` format.** `pkg:section:dir` triples joined by `:`, so bundle paths cannot contain `:`. dune-site prepends env entries before the encoded one. An unset `DUNE_OCAML_HARDCODED` is only a problem if plug-ins are dynlinked, which they never are here.
- **Why3 runs provers through `$WHY3LIB/why3server`.** It is ENOENT if not shipped. `WHY3DATA`/`WHY3LIB` env vars override Why3's `Config`. The `why3` CLI is **not** shipped: its subcommands are dynlinked `.cmxs` files from the absolute opam `Config.libdir`. The prover config is a template instead.
- **`why3 config detect`** lists Alt-Ergo 2.6.2, CVC4 1.8, CVC5 1.2.1 and Z3 4.13.0 (plus their variants).
- **`-wp-detect` does not exist in Frama-C 33.** The test SKIPs it.
- **WP on `delivery/tests/wp_ok.c`, run with `-wp-rte`:**
  - Alt-Ergo: 50/50.
  - Z3: 49/50 (one timeout on `array_max` loop invariant 2).
  - CVC4/cvc5: 44/50 (Unknown on the quantified/`\exists` goals).
  - All provers together: 50/50.
  - So the per-prover pass rule is "proved ≥ 1 non-Qed goal, no prover error", and `wp-all` must be complete.
- **Frama-C does not quote its own libc `-I` path** in the cpp command. A bundle *directory* whose path contains spaces breaks preprocessing; this is a WARN, documented, and the AppImage mount path never has spaces. `install.sh` warns about spaces too.
- **The preprocessor read `/usr/include/stdc-predef.h`** until the `-nostdinc` wrapper was added. The strace test catches this.
- **Ivette 33:**
  - `ivette/api.sh` uses `../bin/frama-c` unless `DUNE_WS` is set; our `$BUILD_ROOT/wrap/frama-c` → AppRun is on `PATH` and works.
  - `make -C ivette dist` → `electron-builder --dir` (electron 40.0.0, downloaded from GitHub) → `dist/linux-unpacked/frama-c-gui` (~520 MB).
  - The tarball **lacks** `src/frama-c/plugins/region/api`, which `make api` generates.
  - At run time Ivette starts `frama-c -server-socket /tmp/ivette.frama-c.<pid>.io -then <args>` from `PATH`, so the bundle wrapper `usr/lib/fcai-wrappers/frama-c` comes first.
  - Its config goes to `~/.config/Frama-C GUI/`. D-Bus errors under Xvfb are harmless.
- **`AppRun` must `unset ARGV0`** after reading it. Otherwise Ivette → wrapper → AppRun re-dispatches to `ivette` (an infinite GUI loop).
- **In the container:** no FUSE, no unprivileged `unshare`. Those tests SKIP in the self-test and run on the target.

## Design invariants

- **Nothing at run time may point into the build machine.** The checks are:
  - `run-tests.sh`'s strace check FAILs on *successful* accesses to `BUILD_ROOTS`, a host gcc/cpp/include or host provers/why3/frama-c;
  - accesses to ancestors of the bundle root are allowed;
  - the strings scan is informational only: `frama-c`, `alt-ergo`, `why3server`, `why3cpulimit` and `Makefile.config` still contain build paths that are never used.
- **Only glibc comes from the host** for the CLI tools. Ivette/Electron takes the desktop libraries (GTK, NSS, …) from the host, like any Electron app.
- **Checks must be strict.** "Starts with the bundle root" is not proof: check that the path exists and has the expected content. A prefix-only check once hid the broken share path.
- **Test pass criteria** must test that a component *works*, not prover strength.
- **All downloads are pinned** (SHA256, or nodejs.org's SHASUMS). New versions: update the version and the hash together.

## Mock harness (`dev/mock/`)

`run-mock.sh [WORKDIR]` stamps steps 0–4 as done, installs a fake `opam`, and fakes:
- the stage (`frama-c-static.in`: mimics `-print-share-path` with the baked second entry, `DUNE_DIR_LOCATIONS` handling, libc taken from the *baked* entry, the why3server requirement, prover calls through `PATH`);
- the Why3 CLI (`why3.in`);
- `alt-ergo`;
- Ivette (`mock-ivette.c`: an ELF that starts `frama-c -server-socket` from `PATH`; `IVETTE_MOCK=bad` gives one that never does).

It then runs the real `build.sh` and `run-tests.sh` on the untarred AppImage, with real Z3/CVC4/cvc5, real gcc relocation and real appimagetool. Expect: build passes, ~96 PASS on the target run, no FAIL. **When a real build reveals a new behaviour, encode it in the mock first.**

## Open items / next steps

1. **The last real build had not finished green.** The fixes for the per-prover criteria and log clearing went out after the 44/50 report; they were validated by the mock only. Next: the owner rebuilds and expects a green self-test, then tests on the offline target.
2. **Target-side checks not yet run on a real offline machine:** FUSE mount, `unshare -rn`, Ivette with a real display, glibc of the target.
3. **Possible improvements, not requested:**
   - flambda (`OCAML_FLAMBDA=1`);
   - SWI-Prolog for MetAcsl deduction (`conf-swi-prolog`);
   - shrinking the AppImage (Ivette is ~520 MB unpacked);
   - quoting the libc path upstream.
