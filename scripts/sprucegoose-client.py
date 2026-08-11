#!/usr/bin/env python3
"""Thin SpruceGoose CLI client for the persistent local Unix-socket service."""

import json
import hashlib
import os
import shlex
import socket
import subprocess
import sys

SOP_PATH = "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"


def fail(message):
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")), file=sys.stderr)
    raise SystemExit(2)


def sop_preflight(args):
    gated = (
        args[:2] == ["task", "add"]
        or args[:2] == ["task", "start"]
        or args[:2] == ["task", "acknowledge-sop"]
    )
    if not gated:
        return
    try:
        local = hashlib.sha256(open(SOP_PATH, "rb").read()).hexdigest()
        remote = subprocess.run(
            [
                "ssh",
                "-o",
                "BatchMode=yes",
                "mama",
                f"sha256sum -- {shlex.quote(SOP_PATH)}",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        ).stdout.split()[0]
    except (OSError, subprocess.SubprocessError, IndexError) as error:
        fail(f"cannot verify Mama Systemwide SOP parity: {error}")
    if local != remote:
        fail(
            "Systemwide SOP drift between Evergreen and Mama; "
            "run scripts/sync-systemwide-sop.py --apply"
        )


def main():
    if len(sys.argv) > 129 or any(len(arg.encode()) > 4096 for arg in sys.argv[1:]):
        fail("invalid arguments")

    sop_preflight(sys.argv[1:])

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
