"""Acceptance gate for the complete Hex 2.5.1 human audit report.

Protocol sources and operator instructions: docs/dependency-audit.md.
Only Python's standard library is used; no application is started.
"""

import datetime as dt
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

HEX_VERSION = "2.5.1"
CLEAN = "No retired or security advisory packages found"
COMPLETE = "Found packages with security advisories"
IDENTIFIER = r"[A-Za-z0-9][A-Za-z0-9._:-]*"
HEADER = re.compile(
    rf"  ([a-z_0-9]+) ([^ \t]+) - ({IDENTIFIER})"
    r"(?: \((NONE|LOW|MEDIUM|HIGH|CRITICAL)\))?"
)
ANSI = re.compile(r"\x1b\[[0-9;]*m")


class AuditError(ValueError):
    pass


def parse_allowlist(text, today):
    entries = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split(maxsplit=3)
        if len(parts) != 4:
            raise AuditError(f"allowlist line {number}: ID, expiry, owner and rationale required")
        identifier, expiry, owner, rationale = parts
        if not re.fullmatch(IDENTIFIER, identifier) or identifier in entries:
            raise AuditError(f"allowlist line {number}: invalid or duplicate advisory ID")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", expiry):
            raise AuditError(f"allowlist line {number}: invalid expiry")
        try:
            expires = dt.date.fromisoformat(expiry)
        except ValueError as error:
            raise AuditError(f"allowlist line {number}: invalid calendar date") from error
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@/-]*", owner) or not rationale.strip():
            raise AuditError(f"allowlist line {number}: owner and rationale required")
        if today > expires:
            raise AuditError(f"{identifier}: acceptance expired {expiry} ({owner})")
        entries[identifier] = (expiry, owner)
    return entries


def parse_report(output, status):
    # Only Hex.Shell color escapes are permitted, not arbitrary controls.
    output = ANSI.sub("", output)
    if any(ord(c) < 32 and c not in "\n\r\t" for c in output):
        raise AuditError("audit report contains unsupported control characters")
    lines = output.splitlines()
    while lines and lines[-1] == "":
        lines.pop()
    if status == 0 and lines == [CLEAN]:
        return []
    if status != 1 or not lines or lines[0] != "Advisories:":
        raise AuditError(f"incomplete or unsupported audit report (exit {status})")
    if lines[-1] != COMPLETE:
        raise AuditError("audit report is missing its completion marker")
    body = lines[1:-1]
    findings = []
    index = 0
    while index < len(body):
        if body[index] == "":
            index += 1
            continue
        match = HEADER.fullmatch(body[index])
        if not match:
            raise AuditError("unsupported advisory section or row")
        package, version, identifier, severity = match.groups()
        index += 1
        # Aliases are presentation only: acceptance is by exact primary ID.
        if index < len(body) and body[index].startswith("    aka: "):
            aliases = body[index][9:].split(", ")
            if not aliases or not all(re.fullmatch(IDENTIFIER, a) for a in aliases):
                raise AuditError("malformed advisory aliases")
            index += 1
        if (
            index >= len(body)
            or not re.fullmatch(r"    \S.*", body[index])
            or re.fullmatch(r"    https?://\S+", body[index])
        ):
            raise AuditError("advisory summary missing")
        index += 1
        if index < len(body) and re.fullmatch(r"    https?://\S+", body[index]):
            index += 1
        if index < len(body) and body[index] != "":
            raise AuditError("unexpected output following advisory")
        findings.append((identifier, package, version, severity or "UNKNOWN"))
    if not findings:
        raise AuditError("empty advisory report with nonzero status")
    return findings


def run(command, *, env=None):
    try:
        return subprocess.run(
            command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env, timeout=120, check=False,
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        raise AuditError(f"unable to complete {command[0]} command") from error


def main():
    root = run(["git", "rev-parse", "--show-toplevel"])
    if root.returncode:
        raise AuditError("not a git worktree")
    os.chdir(root.stdout.strip())
    allowlist = Path(os.environ.get("HEX_AUDIT_ALLOWLIST") or ".hex-audit-allowlist")
    lock = Path("mix.lock")
    lock_bytes = lock.read_bytes()
    allowlist_bytes = allowlist.read_bytes()
    today = dt.datetime.now(dt.timezone.utc).date()
    entries = parse_allowlist(allowlist_bytes.decode("utf-8"), today)
    version = run(["mix", "hex.info"])
    if version.returncode or not re.search(
        rf"^Hex:\s+{re.escape(HEX_VERSION)}\s*$", version.stdout, re.MULTILINE
    ):
        raise AuditError(f"Hex {HEX_VERSION} required; unsupported or unavailable Hex")
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    audit = run(["mix", "hex.audit"], env=env)
    # Preserve the diagnostic stream before interpreting its status.
    print(audit.stdout, end="" if audit.stdout.endswith("\n") else "\n")
    findings = parse_report(audit.stdout, audit.returncode)
    if lock.read_bytes() != lock_bytes or allowlist.read_bytes() != allowlist_bytes:
        raise AuditError("lockfile or allowlist changed during audit")
    # Re-evaluate expiry if the audit crossed UTC midnight.
    today = dt.datetime.now(dt.timezone.utc).date()
    entries = parse_allowlist(allowlist_bytes.decode("utf-8"), today)
    print(f"hex-version={HEX_VERSION} audit-exit={audit.returncode} audit-date={today}")
    print(f"mix-lock-sha256={hashlib.sha256(lock_bytes).hexdigest()}")
    print(f"allowlist-sha256={hashlib.sha256(allowlist_bytes).hexdigest()}")
    blocked = []
    for identifier, package, version, severity in findings:
        if identifier not in entries:
            blocked.append(identifier)
            print(f"BLOCKED {identifier} {package} {version} ({severity}): not accepted")
        else:
            expiry, owner = entries[identifier]
            print(f"ACCEPTED {identifier} {package} {version}: owner={owner} expires={expiry}")
    if blocked:
        raise AuditError("unaccepted dependency advisories")
    print(f"dependency-audit=PASS ({len(findings)} accepted, 0 blocking)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AuditError, OSError, UnicodeError) as error:
        print(f"dependency-audit=FAIL: {error}", file=sys.stderr)
        sys.exit(1)
