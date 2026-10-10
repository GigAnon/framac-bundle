#!/usr/bin/env python3
"""zmq_client.py LIBZMQ URL -- one request to a Frama-C ZeroMQ server.
   zmq_client.py --load-only LIB -- only load LIB (and its dependencies)

Uses only the standard library: libzmq (the one bundled with Frama-C) is
called through ctypes.  Protocol (Frama-C server_zmq.md): a REQ socket sends
multi-part messages; GET(id, request, json) is answered with DATA(id, json),
possibly after POLLs while the server is busy ("NONE").  Sends
kernel.services.getConfig, prints the reply, then SHUTDOWN.  Exit 0 iff a
DATA reply with a "version" field came back.

The bundled shared libraries carry no search path of their own (only the
bundle's executables do), so a library's dependencies, which sit next to
it, are not found when it is dlopen()ed by path from another program.
load() preloads each missing dependency from the library's directory, as
the loader names it, and retries; no LD_LIBRARY_PATH is needed.
"""
import ctypes
import json
import os
import re
import sys
import time

ZMQ_REQ, ZMQ_SNDMORE, ZMQ_RCVMORE, ZMQ_RCVTIMEO, ZMQ_LINGER = 3, 2, 13, 27, 17


def load(path):
    here = os.path.dirname(os.path.abspath(path))
    preloaded = []
    for _ in range(64):
        try:
            return ctypes.CDLL(path)
        except OSError as e:
            m = re.match(r"([^:]+): cannot open shared object file", str(e))
            dep = m and os.path.join(here, os.path.basename(m.group(1)))
            if not dep or not os.path.exists(dep) or dep in preloaded:
                raise
            load(dep) if False else None
            try:
                ctypes.CDLL(dep, mode=ctypes.RTLD_GLOBAL)
            except OSError:
                # the dependency has missing dependencies of its own
                load(dep)
                ctypes.CDLL(dep, mode=ctypes.RTLD_GLOBAL)
            preloaded.append(dep)
    raise OSError("too many dependencies to preload for " + path)


def main():
    if sys.argv[1] == "--load-only":
        load(sys.argv[2])
        print("loaded:", sys.argv[2])
        return
    lib = load(sys.argv[1])
    url = sys.argv[2].encode()
    vp, sz = ctypes.c_void_p, ctypes.c_size_t
    lib.zmq_ctx_new.restype = vp
    lib.zmq_socket.restype, lib.zmq_socket.argtypes = vp, [vp, ctypes.c_int]
    lib.zmq_connect.argtypes = [vp, ctypes.c_char_p]
    lib.zmq_setsockopt.argtypes = [vp, ctypes.c_int, vp, sz]
    lib.zmq_getsockopt.argtypes = [vp, ctypes.c_int, vp, ctypes.POINTER(sz)]
    lib.zmq_send.argtypes = [vp, ctypes.c_char_p, sz, ctypes.c_int]
    lib.zmq_msg_init.argtypes = [vp]
    lib.zmq_msg_recv.argtypes = [vp, vp, ctypes.c_int]
    lib.zmq_msg_data.restype, lib.zmq_msg_data.argtypes = vp, [vp]
    lib.zmq_msg_size.restype, lib.zmq_msg_size.argtypes = sz, [vp]
    lib.zmq_msg_close.argtypes = [vp]
    lib.zmq_close.argtypes = [vp]

    ctx = lib.zmq_ctx_new()
    sock = lib.zmq_socket(ctx, ZMQ_REQ)
    tmo = ctypes.c_int(15000)
    lib.zmq_setsockopt(sock, ZMQ_RCVTIMEO, ctypes.byref(tmo), ctypes.sizeof(tmo))
    zero = ctypes.c_int(0)
    lib.zmq_setsockopt(sock, ZMQ_LINGER, ctypes.byref(zero), ctypes.sizeof(zero))
    if lib.zmq_connect(sock, url) != 0:
        sys.exit("zmq_connect failed")

    def send(parts):
        for i, p in enumerate(parts):
            b = p.encode()
            if lib.zmq_send(sock, b, len(b), ZMQ_SNDMORE if i < len(parts) - 1 else 0) < 0:
                sys.exit("zmq_send failed")

    def recv():
        parts = []
        while True:
            msg = ctypes.create_string_buffer(64)        # zmq_msg_t
            lib.zmq_msg_init(msg)
            if lib.zmq_msg_recv(msg, sock, 0) < 0:
                sys.exit("no reply from the server (timeout)")
            parts.append(ctypes.string_at(lib.zmq_msg_data(msg), lib.zmq_msg_size(msg)).decode())
            lib.zmq_msg_close(msg)
            more, n = ctypes.c_int(0), sz(ctypes.sizeof(ctypes.c_int))
            lib.zmq_getsockopt(sock, ZMQ_RCVMORE, ctypes.byref(more), ctypes.byref(n))
            if not more.value:
                return parts

    send(["GET", "fcai-1", "kernel.services.getConfig", "null"])
    reply = recv()
    for _ in range(100):
        if reply and reply[0] in ("DATA", "ERROR", "WRONG", "REJECTED"):
            break
        time.sleep(0.1)
        send(["POLL"])
        reply = recv()
    print("reply:", reply)
    ok = False
    if len(reply) >= 3 and reply[0] == "DATA" and reply[1] == "fcai-1":
        data = json.loads(reply[2])
        ok = isinstance(data, dict) and "version" in data
        print("version:", data.get("version") if isinstance(data, dict) else None)
    send(["SHUTDOWN"])
    try:
        tmo.value = 2000
        lib.zmq_setsockopt(sock, ZMQ_RCVTIMEO, ctypes.byref(tmo), ctypes.sizeof(tmo))
        recv()
    except SystemExit:
        pass
    lib.zmq_close(sock)
    sys.exit(0 if ok else 1)


main()
