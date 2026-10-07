#!/usr/bin/env python3
"""mpv_ipc.py — send unpause command to mpv via Unix socket IPC."""
import socket, json, time, traceback

sock_path = "/tmp/mpv.sock"
last_err = None
for i in range(10):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(sock_path)
        s.sendall(json.dumps({"command": ["set_property", "pause", False]}).encode() + b"\n")
        resp = s.recv(4096)
        print(f"mpv: {resp.decode().strip()}")
        s.close()
        break
    except Exception as e:
        last_err = e
        time.sleep(0.2)
else:
    print(f"ERROR: could not connect to {sock_path}: {last_err}", file=__import__('sys').stderr)
    traceback.print_exc()
    __import__('sys').exit(1)