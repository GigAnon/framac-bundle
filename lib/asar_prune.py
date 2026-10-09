#!/usr/bin/env python3
"""
asar_prune.py ARCHIVE [--glob PATTERN ...] [--check-only]

Rewrite an Electron asar archive without the files whose path (relative to
the archive root, '/'-separated) matches one of the glob patterns (default:
'*.map', i.e. JavaScript source maps, which nothing needs at run time).

Format (as written by @electron/asar): a Chromium pickle holding the size of
a second pickle, which holds the JSON header string; file contents follow,
at header-relative "offset" (a decimal string) with "size".  Files marked
"unpacked" live in ARCHIVE.unpacked/ and have no offset; "link" entries are
symlinks.  Every other key (integrity hashes, "executable") is kept as is.

After writing, the new archive is re-read: every remaining file must match
its "integrity" hash when it has one, and otherwise the bytes of the
original.  Prints a summary; exits non-zero on any mismatch.
"""
import fnmatch
import hashlib
import json
import os
import struct
import sys


def read_header(f):
    head = f.read(16)
    if len(head) < 16:
        raise SystemExit("not an asar archive (too short)")
    size_pickle_payload, header_pickle_size = struct.unpack("<II", head[:8])
    if size_pickle_payload != 4:
        raise SystemExit("not an asar archive (bad size pickle)")
    _payload, strlen = struct.unpack("<II", head[8:16])
    header = json.loads(f.read(strlen).decode("utf-8"))
    base = 8 + header_pickle_size
    return header, base


def encode_header(header):
    s = json.dumps(header, separators=(",", ":")).encode("utf-8")
    pad = (-len(s)) % 4
    payload = struct.pack("<I", len(s)) + s + b"\0" * pad
    header_pickle = struct.pack("<I", len(payload)) + payload
    size_pickle = struct.pack("<II", 4, len(header_pickle))
    return size_pickle + header_pickle


def walk(node, prefix=""):
    for name, entry in node.get("files", {}).items():
        path = prefix + name
        if "files" in entry:
            yield from walk(entry, path + "/")
        else:
            yield path, entry


def prune(node, prefix, patterns, removed):
    files = node.get("files", {})
    for name in list(files):
        entry = files[name]
        path = prefix + name
        if "files" in entry:
            prune(entry, path + "/", patterns, removed)
        elif any(fnmatch.fnmatch(path, p) or fnmatch.fnmatch(name, p) for p in patterns):
            if entry.get("unpacked"):
                continue  # lives outside the archive: leave it alone
            removed.append((path, int(entry.get("size", 0))))
            del files[name]


def integrity_ok(entry, data):
    integ = entry.get("integrity")
    if not integ:
        return None
    if integ.get("algorithm", "SHA256").upper() != "SHA256":
        return None
    if hashlib.sha256(data).hexdigest() != integ.get("hash"):
        return False
    bs = int(integ.get("blockSize", 0) or 0)
    blocks = integ.get("blocks")
    if bs and blocks is not None:
        got = [hashlib.sha256(data[i:i + bs]).hexdigest() for i in range(0, len(data), bs)] or \
              [hashlib.sha256(b"").hexdigest()]
        if got != blocks:
            return False
    return True


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    archive = args[0]
    patterns = []
    check_only = "--check-only" in args
    i = 1
    while i < len(args):
        if args[i] == "--glob":
            patterns.append(args[i + 1]); i += 2
        else:
            i += 1
    patterns = patterns or ["*.map"]

    with open(archive, "rb") as f:
        header, base = read_header(f)
        orig = {}
        for path, entry in walk(header):
            if "offset" in entry and not entry.get("unpacked"):
                f.seek(base + int(entry["offset"]))
                orig[path] = f.read(int(entry["size"]))
    old_size = os.path.getsize(archive)

    if check_only:
        bad = [p for p, e in walk(header) if p in orig and integrity_ok(e, orig[p]) is False]
        print("asar: %d files, %d integrity mismatches" % (len(orig), len(bad)))
        return 1 if bad else 0

    removed = []
    prune(header, "", patterns, removed)
    # re-lay the contents in header order
    offset = 0
    chunks = []
    for path, entry in walk(header):
        if path in orig:
            entry["offset"] = str(offset)
            chunks.append(orig[path])
            offset += len(orig[path])
    tmp = archive + ".fcai-tmp"
    with open(tmp, "wb") as out:
        out.write(encode_header(header))
        for c in chunks:
            out.write(c)

    # verify the rewritten archive
    errors = 0
    with open(tmp, "rb") as f:
        h2, base2 = read_header(f)
        n = 0
        for path, entry in walk(h2):
            if any(fnmatch.fnmatch(path, p) or fnmatch.fnmatch(path.rsplit("/", 1)[-1], p) for p in patterns) \
                    and not entry.get("unpacked"):
                print("asar: %s still present" % path); errors += 1
            if path not in orig:
                continue
            f.seek(base2 + int(entry["offset"]))
            data = f.read(int(entry["size"]))
            n += 1
            ok = integrity_ok(entry, data)
            if ok is False or data != orig[path]:
                print("asar: content mismatch for %s" % path); errors += 1
    if errors:
        os.unlink(tmp)
        print("asar: verification failed, %s left unchanged" % archive)
        return 1
    os.replace(tmp, archive)
    new_size = os.path.getsize(archive)
    print("asar: removed %d file(s) matching %s, %.1f MB; archive %.1f -> %.1f MB; %d files verified"
          % (len(removed), " ".join(patterns), sum(s for _, s in removed) / 1e6,
             old_size / 1e6, new_size / 1e6, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
