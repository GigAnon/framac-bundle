# Frama-C 34.0 beta offline bundle — `34.0-beta-1.0` (draft)

A **beta**: Frama-C 34.0~beta "Selenium" (released 2026-11-13) with MetAcsl 0.12-beta, packaged the same way as the 33.0 bundles (one self-contained AppImage for Linux x86_64, no network, no root, any directory). Use 33.0 for production work.

## Differences from the 33.0 bundles

- **Frama-C 34.0~beta.** The upstream Changelog lists the changes; Frama-C 34 needs OCaml ≥ 5.2, and the bundle is built with OCaml 5.5.0, as Frama-C 34 itself recommends.
- **MetAcsl 0.12-beta**, built from its git tag (not yet in opam); new options `-meta-fold` and `-meta-quantify-range`.
- **Alt-Ergo 2.6.4**; Why3 stays 1.8.x, and Z3 4.13.0, CVC4 1.8 and cvc5 1.2.1 are unchanged.
- **`frama-c-script list-functions` works** (it failed in 33.0-1.0 and 1.1; also fixed in 33.0-1.2).
- Everything else as in 33.0-1.1: Ivette, Eva's Apron domains, the ZeroMQ server (`tests/zmq_client.py`), `frama-c-script` with its bundled Python 3.12 and PyYAML, bash completion, `install.sh` / `setup_completion.sh`, glibc ≥ 2.31 on the target.

## Install

```sh
tar xf frama-c-34.0-beta-1.0-offline-x86_64.tar && cd frama-c-34.0-beta-1.0-offline-x86_64
sha256sum -c SHA256SUMS
./run-tests.sh
./install.sh        # ~/.local/opt/frama-c-34.0-beta-1.0 (root: /opt/...), next to any 33.0 install
```

## Tested

To be filled in from the first real build and its test reports.

## Known limitations

As in 33.0: no spaces in the install path, `-wp-detect` does not exist, Ivette is large. Alt-Ergo is under the OCamlPro non-commercial licence.
