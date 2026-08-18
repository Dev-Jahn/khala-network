#!/usr/bin/env python3
"""Test-only khala channel Unix socket listener."""

import argparse
import json
import os
import signal
import socket


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("socket_path")
    parser.add_argument("output_path")
    parser.add_argument("ready_path")
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.socket_path), mode=0o700, exist_ok=True)
    os.chmod(os.path.dirname(args.socket_path), 0o700)
    try:
        os.unlink(args.socket_path)
    except FileNotFoundError:
        pass

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(args.socket_path)
    listener.listen(16)
    listener.settimeout(0.2)
    open(args.ready_path, "w", encoding="utf-8").close()

    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    with open(args.output_path, "a", encoding="utf-8", buffering=1) as output:
        while not stopping:
            try:
                connection, _ = listener.accept()
            except TimeoutError:
                continue
            with connection:
                payload = b""
                while b"\n" not in payload:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    payload += chunk
                try:
                    request = json.loads(payload.split(b"\n", 1)[0])
                    output.write(json.dumps(request, separators=(",", ":")) + "\n")
                    response = {"ok": True}
                except Exception as error:  # test peer must expose protocol errors
                    response = {"ok": False, "error": str(error)}
                connection.sendall(json.dumps(response).encode("utf-8") + b"\n")

    listener.close()
    try:
        os.unlink(args.socket_path)
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    main()
