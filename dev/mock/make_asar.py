#!/usr/bin/env python3
"""make_asar.py OUT.asar -- a small Electron asar like Ivette's: compiled JS
under out/, node_modules, and *.map source maps, with integrity hashes."""
import hashlib, json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from asar_prune import encode_header  # noqa: E402

FILES = {
    "package.json": b'{"name":"frama-c-gui","main":"out/main/index.js"}',
    "out/main/index.js": b"require('lodash');\n//# sourceMappingURL=index.js.map\n",
    "out/main/index.js.map": b'{"version":3,"mappings":"AAAA"}' * 50,
    "out/renderer/index.html": b"<html>ivette</html>",
    "out/renderer/assets/index.js": b"console.log('renderer');" * 100,
    "out/renderer/assets/index.js.map": b'{"version":3}' * 400,
    "node_modules/lodash/lodash.js": b"module.exports={};" * 30,
    "node_modules/d3-graphviz/build/d3-graphviz.js.map": b"{}" * 1000,
}
BS = 4 * 1024 * 1024


def tree():
    root = {"files": {}}
    for path, data in FILES.items():
        node = root
        parts = path.split("/")
        for d in parts[:-1]:
            node = node["files"].setdefault(d, {"files": {}})
        node["files"][parts[-1]] = {"size": len(data), "integrity": {
            "algorithm": "SHA256", "hash": hashlib.sha256(data).hexdigest(), "blockSize": BS,
            "blocks": [hashlib.sha256(data).hexdigest()]}}
    return root


def main():
    root = tree()
    off = 0
    order = []

    def walk(n, pre=""):
        for k, v in n["files"].items():
            if "files" in v:
                walk(v, pre + k + "/")
            else:
                order.append((pre + k, v))
    walk(root)
    for path, v in order:
        v["offset"] = str(off); off += len(FILES[path])
    with open(sys.argv[1], "wb") as f:
        f.write(encode_header(root))
        for path, _ in order:
            f.write(FILES[path])


main()
