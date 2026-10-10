# Frama-C 33.0 offline bundle — 1.1 (`33.0-1.1`)

## Changes since 1.0

- **Eva Apron domains:** `apron-octagon`, `apron-box`, `apron-polka-loose`, `apron-polka-strict` and `apron-polka-equality` (`-eva-domains …`). They are experimental upstream. Eva's built-in `octagon` domain was already there.
- **ZeroMQ server:** `-server-zmq <url>` and `-server-gui <cmd>`. For example, `frama-c file.c -eva -then -server-zmq ipc:///tmp/fc.io` keeps the analysed project available to ZeroMQ clients until they send `SHUTDOWN`. `tests/zmq_client.py` is a minimal client.
- `build-info.txt` records the repository commit the bundle was built from (1.0 said `unknown`).

## About the bundle

Frama-C 33.0 (Arsenic) with its GUI, Why3 and four SMT provers, packaged as one self-contained AppImage for Linux x86_64. It needs no network access, no root and no installation beyond copying files, and it works from any directory.

**Download:** `frama-c-33.0-1.1-offline-x86_64.tar` (~255 MB). Check it with `sha256sum -c SHA256SUMS` once unpacked.

## What's inside

| Component | Version | Notes |
|---|---|---|
| Frama-C | 33.0 (Arsenic) | One executable with every plug-in linked in: Eva, WP, RTE, Aorai, Dive, Metrics, Slicing, Studia, … (full list: `--fcai-info`). E-ACSL is not included. |
| MetAcsl | 0.11 | Linked into Frama-C like the built-in plug-ins. |
| Ivette | from Frama-C 33.0 (Electron 40) | The graphical interface: `ivette file.c -eva`. |
| `frama-c-script` | from Frama-C 33.0 | Comes with its own Python 3.12.14 and PyYAML 6.0.3, so the host's Python is never used. |
| Why3 | 1.8.2 | Used by WP, and available as the `why3` command. |
| Alt-Ergo | 2.6.2 | OCamlPro licence: free for non-commercial use only. |
| Z3 | 4.13.0 | |
| CVC4 | 1.8 | |
| cvc5 | 1.2.1 | |
| Apron | opam `apron` (C libraries bundled) | Eva's `apron-*` domains. |
| ZeroMQ | libzmq 4.3 (bundled) + opam `zmq` | `-server-zmq`. |
| C preprocessor | gcc 9.4 (`cpp` only) | Only Frama-C's own libc headers are searched, never the host's. |

The provers come pre-configured for WP and Why3, whatever directory the bundle is in.

## Requirements on the target

- Linux x86_64 with **glibc ≥ 2.31**: RHEL/Rocky/Alma 9, Debian 11+, Ubuntu 20.04+. Older systems get a clear error message instead of a loader failure.
- `/bin/sh` and basic coreutils.
- **Ivette only:** a graphical session and the usual desktop libraries (GTK 3, NSS, …), as for any Electron application.
- Running the AppImage directly needs FUSE. Without FUSE, use `install.sh --extract` or `--appimage-extract`.

## Install

```sh
tar xf frama-c-33.0-1.1-offline-x86_64.tar && cd frama-c-33.0-1.1-offline-x86_64
./run-tests.sh      # optional: acceptance tests, writes fcai-test-report-<host>-<date>.txt
./install.sh        # user: ~/.local/opt/frama-c-33.0-1.1 + ~/.local/bin
                    # root: /opt/frama-c-33.0-1.1 + /usr/local/bin
```

**Commands installed:** `frama-c`, `frama-c-script`, `ivette`, `why3`, `z3`, `cvc4`, `cvc5`, `alt-ergo`, `setup_completion.sh`.

- **Bash completion.** Each user who wants it runs `setup_completion.sh` once; root can run `setup_completion.sh --system` for everybody. `install.sh` never writes into anyone's home directory. Completion covers options, values such as `-wp-prover`, message and warning keys and machdeps, `frama-c-script` commands and `why3` commands.
- **Your own Why3 configuration.** Set `WHY3CONFIG` (or `FCAI_WHY3CONFIG`) and it is used instead of the bundled configuration.
- **Without installing.** `./Frama-C-33.0-1.1-x86_64.AppImage <frama-c arguments>` runs Frama-C directly.
- **Version and build details.** `--fcai-version` prints the bundle version and `--fcai-info` the build details.

## Tested

The shipped `run-tests.sh` checks:
- WP with each prover and with all of them, Eva, `frama-c-script`, the `why3` command, Ivette and completion;
- relocation (copied, renamed, original deleted);
- running without network;
- an `strace` check that nothing from the build machine or the host toolchain is used.

| Machine | Result |
|---|---|
| Ubuntu 24.04 (glibc 2.39) | 110 PASS, 0 FAIL. WP on the sample file: Alt-Ergo 50/50, Z3 49/50, CVC4/cvc5 44/50, all provers together 50/50. |
| RHEL 9.8 (glibc 2.34) | Frama-C, `frama-c-script`, bash completion and Ivette (real display) confirmed working. |

## Known limitations

- **No spaces in the install path.** Frama-C does not quote its own libc include path when it calls the preprocessor, so a bundle *directory* whose path contains a space cannot preprocess C files. The AppImage itself is unaffected, because its mount point never contains spaces. `install.sh` warns about this.
- **`-wp-detect` does not exist in Frama-C 33.** Use `why3 config list-provers` to see the configured provers.
- **Ivette is large** (~450 MB unpacked), most of it the Electron runtime.

## Licences

Each component keeps its own licence. The texts are in `usr/share/fcai/licenses/` inside the bundle (`--appimage-extract` to browse). Frama-C and MetAcsl are LGPL 2.1; Why3 is LGPL 2.1; Z3 is MIT; CVC4 and cvc5 are BSD 3-Clause; Alt-Ergo is under the OCamlPro Non-Commercial License; Python is under the PSF licence; PyYAML is MIT; gcc is GPL 3 with the runtime exception; Electron/Chromium is MIT plus third-party licences.
