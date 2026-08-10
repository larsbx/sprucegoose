#!/usr/bin/env python3
"""Atomically publish Papa's canonical Systemwide SOP bytes to the Mama authority."""

import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import textwrap
from pathlib import Path
from typing import NoReturn

_AUTHORITY_KEYS = {"canonical_path", "authority_host", "authority_path"}
_HOST = re.compile(r"^[A-Za-z0-9._-]{1,253}$")
_DIGEST = re.compile(r"^([0-9a-f]{64})\s*$")
_MAX_SOP_BYTES = 5 * 1024 * 1024


def fail(message: str) -> NoReturn:
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")), file=sys.stderr)
    raise SystemExit(2)


def policy_path() -> str:
    return os.environ.get(
        "SPRUCE_GOOSE_SOP_AUTHORITY_CONFIG",
        str(Path.home() / ".config/sprucegoose/sop-authority.json"),
    )


def load_policy() -> dict[str, str]:
    path = policy_path()
    try:
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 4096:
            fail("Systemwide SOP authority policy must be a bounded regular file")
        with open(path, encoding="utf-8") as source:
            policy = json.load(source)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        fail(f"cannot read Systemwide SOP authority policy: {error}")

    if not isinstance(policy, dict) or set(policy) != _AUTHORITY_KEYS:
        fail("Systemwide SOP authority policy must contain exactly canonical_path, authority_host, and authority_path")
    if not all(isinstance(value, str) for value in policy.values()):
        fail("Systemwide SOP authority policy values must be strings")
    if not os.path.isabs(policy["canonical_path"]) or not os.path.isabs(policy["authority_path"]):
        fail("Systemwide SOP authority paths must be absolute")
    if not _HOST.fullmatch(policy["authority_host"]):
        fail("Systemwide SOP authority host is invalid")
    return policy


def canonical_bytes(path: str) -> bytes:
    try:
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode):
            fail("canonical Systemwide SOP must be a regular file")
        if metadata.st_size <= 0 or metadata.st_size > _MAX_SOP_BYTES:
            fail("canonical Systemwide SOP has an invalid size")
        with open(path, "rb") as source:
            body = source.read(_MAX_SOP_BYTES + 1)
    except OSError as error:
        fail(f"cannot read canonical Systemwide SOP: {error}")
    if len(body) != metadata.st_size:
        fail("canonical Systemwide SOP changed during publication")
    return body


def publish(policy: dict[str, str], body: bytes, digest: str) -> None:
    remote_code = textwrap.dedent(
        """
        import hashlib, os, sys, tempfile
        destination, expected = sys.argv[1], sys.argv[2]
        body = sys.stdin.buffer.read()
        if hashlib.sha256(body).hexdigest() != expected:
            raise SystemExit("received digest mismatch")
        parent = os.path.dirname(destination)
        if not os.path.isdir(parent):
            raise SystemExit("authority destination directory is unavailable")
        fd, temporary = tempfile.mkstemp(prefix=".systemwide-sop-", dir=parent)
        try:
            with os.fdopen(fd, "wb") as target:
                target.write(body)
                target.flush()
                os.fsync(target.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, destination)
            directory = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(expected)
        """
    ).strip()
    command = "python3 -c {} {} {}".format(
        shlex.quote(remote_code),
        shlex.quote(policy["authority_path"]),
        shlex.quote(digest),
    )
    try:
        result = subprocess.run(
            [
                "ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "--",
                policy["authority_host"],
                command,
            ],
            input=body,
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"cannot publish Systemwide SOP authority bytes: {error}")

    output = result.stdout.decode("utf-8", errors="replace").strip()
    if result.returncode != 0 or not _DIGEST.fullmatch(output) or output != digest:
        fail("authority did not confirm the canonical Systemwide SOP digest")


def main() -> None:
    policy = load_policy()
    body = canonical_bytes(policy["canonical_path"])
    digest = hashlib.sha256(body).hexdigest()
    publish(policy, body, digest)
    print(json.dumps({"ok": True, "sha256": digest, "bytes": len(body)}, separators=(",", ":")))


if __name__ == "__main__":
    main()
