#!/usr/bin/env python3
"""Thin SpruceGoose CLI client for the persistent local Unix-socket service."""

import json
import os
import socket
import sys


def fail(message):
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")), file=sys.stderr)
    raise SystemExit(2)


def main():
    if len(sys.argv) > 129 or any(len(arg.encode()) > 4096 for arg in sys.argv[1:]):
        fail("invalid arguments")

    socket_path = os.environ.get(
        "SPRUCE_GOOSE_CLI_SOCKET", f"/run/user/{os.getuid()}/sprucegoose/cli.sock"
    )
    timeout = float(os.environ.get("SPRUCE_GOOSE_CLI_CLIENT_TIMEOUT_SECONDS", "35"))
    body = json.dumps({"args": sys.argv[1:]}, separators=(",", ":")).encode()
    request = (
        b"POST /v1/cli HTTP/1.1\r\n"
        b"Host: localhost\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + b"Connection: close\r\n\r\n"
        + body
    )

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(socket_path)
        client.sendall(request)
        chunks = []
        while True:
            chunk = client.recv(65_536)
            if not chunk:
                break
            chunks.append(chunk)
            if sum(map(len, chunks)) > 1_048_576:
                fail("response too large")
    except (OSError, TimeoutError) as error:
        fail(f"service unavailable: {error}")
    finally:
        client.close()

    response = b"".join(chunks)
    try:
        _headers, payload = response.split(b"\r\n\r\n", 1)
        decoded = json.loads(payload)
    except (ValueError, json.JSONDecodeError):
        fail("invalid service response")

    output = json.dumps(decoded, separators=(",", ":"))
    stream = sys.stdout if decoded.get("ok") else sys.stderr
    print(output, file=stream)
    raise SystemExit(0 if decoded.get("ok") else 2)


if __name__ == "__main__":
    main()
