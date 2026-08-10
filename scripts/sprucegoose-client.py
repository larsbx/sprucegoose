#!/usr/bin/env python3
"""Thin SpruceGoose CLI client for the persistent local Unix-socket service."""

import hashlib
import json
import os
import re
import shlex
import socket
import stat
import subprocess
import sys
from pathlib import Path
from typing import NoReturn


_AUTHORITY_KEYS = {"canonical_path", "authority_host", "authority_path"}
_HOST = re.compile(r"^[A-Za-z0-9._-]{1,253}$")
_DIGEST = re.compile(r"^([0-9a-f]{64})\s+")
_MAX_SOP_BYTES = 5 * 1024 * 1024


def fail(message: str) -> NoReturn:
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")), file=sys.stderr)
    raise SystemExit(2)


def file_digest(path):
    try:
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode):
            fail("configured canonical Systemwide SOP must be a regular file")
        if metadata.st_size <= 0 or metadata.st_size > _MAX_SOP_BYTES:
            fail("configured canonical Systemwide SOP has an invalid size")
        digest = hashlib.sha256()
        with open(path, "rb") as source:
            for chunk in iter(lambda: source.read(65_536), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as error:
        fail(f"cannot read configured canonical Systemwide SOP: {error}")


def authority_preflight():
    configured = os.environ.get(
        "SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG",
        str(Path.home() / ".config/sprucegoose/sop-authority.json"),
    )
    if not os.path.exists(configured):
        if "SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG" in os.environ:
            fail("configured Systemwide SOP authority policy is unavailable")
        return

    try:
        if os.lstat(configured).st_size > 4096:
            fail("Systemwide SOP authority policy is too large")
        with open(configured, encoding="utf-8") as source:
            policy = json.load(source)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        fail(f"cannot read Systemwide SOP authority policy: {error}")

    if not isinstance(policy, dict) or set(policy) != _AUTHORITY_KEYS:
        fail("Systemwide SOP authority policy must contain exactly canonical_path, authority_host, and authority_path")

    canonical_path = policy["canonical_path"]
    authority_host = policy["authority_host"]
    authority_path = policy["authority_path"]
    if not all(isinstance(value, str) for value in policy.values()):
        fail("Systemwide SOP authority policy values must be strings")
    if not os.path.isabs(canonical_path) or not os.path.isabs(authority_path):
        fail("Systemwide SOP authority paths must be absolute")
    if not _HOST.fullmatch(authority_host):
        fail("Systemwide SOP authority host is invalid")

    canonical_digest = file_digest(canonical_path)
    command = f"sha256sum -- {shlex.quote(authority_path)}"
    try:
        result = subprocess.run(
            [
                "ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "--",
                authority_host,
                command,
            ],
            capture_output=True,
            text=True,
            timeout=7,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"cannot verify Systemwide SOP authority: {error}")

    match = _DIGEST.match(result.stdout)
    if result.returncode != 0 or match is None:
        fail("cannot verify Systemwide SOP authority digest")
    if match.group(1) != canonical_digest:
        fail("Systemwide SOP authority mismatch; refusing command before socket access")


def main():
    if len(sys.argv) > 129 or any(len(arg.encode()) > 4096 for arg in sys.argv[1:]):
        fail("invalid arguments")

    authority_preflight()

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
