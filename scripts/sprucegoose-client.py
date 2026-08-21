#!/usr/bin/env python3
"""Thin SpruceGoose CLI client for the persistent local Unix-socket service.

Two client-side concerns live here, and nothing else. The service JSON contract
stays canonical; this client never invents, drops, or reorders reported data.

1. Response cap (tsk-20260819T192123Z-5435f13d)
   Each socket response is bounded at MAX_RESPONSE_BYTES. That bound is
   deliberately NOT raised: an unbounded recv is how a thin client turns a
   large corpus into a memory problem. Instead, `task list` without an explicit
   --limit/--offset is fetched page by page through the server's existing,
   stable pagination and reassembled into the exact envelope an unpaged listing
   would have returned. Every individual response stays far under the bound.

   Tradeoff, stated plainly: a paged listing is several reads rather than one,
   so a task mutated mid-walk can be observed at a page boundary. The previous
   behavior was not a consistent alternative -- it was a hard failure -- and
   any explicitly paged caller already had this property. Callers needing a
   point-in-time listing should filter the query so it fits one response.

2. Output format (tsk-20260819T192025Z-90abd50d)
   --format json|table|plain, defaulting to json. The flag is consumed here and
   never sent to the service. json is byte-identical to the previous behavior,
   so existing consumers are unaffected. table/plain are pure display
   transforms over the same rows: no filtering, reordering, or truncation.

3. Caller actor declaration (tsk-20260820T205507Z-02e575eb)
   The service resolves the actor from `--as`, then from SPRUCE_GOOSE_ACTOR in
   *its own* environment. Through this socket client the service's environment
   is the daemon's, never the caller's shell, so a caller-side
   SPRUCE_GOOSE_ACTOR silently vanished even though the service's refusal
   message tells the caller to set it. The client therefore translates the
   caller's environment into the declared form: when the caller passed no
   explicit `--as`/`--as=`, a non-empty trimmed SPRUCE_GOOSE_ACTOR is appended
   as `--as ACTOR`. An explicit flag always wins, and with neither set the
   request is sent unchanged so the service's fail-closed refusal is preserved.
"""

import json
import hashlib
import os
import shlex
import socket
import subprocess
import sys

SOP_PATH = "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"

# Per-response ceiling. Unchanged from the original client on purpose.
MAX_RESPONSE_BYTES = 1_048_576
# Rows requested per page when auto-paginating a `task list`.
DEFAULT_PAGE_SIZE = int(os.environ.get("SPRUCE_GOOSE_CLI_PAGE_SIZE", "100"))
# Absolute bounds on a reassembled listing, so pagination cannot become an
# unbounded fetch loop against a corpus that keeps growing.
MAX_TOTAL_ROWS = 100_000
MAX_TOTAL_BYTES = 64 * 1_048_576

VALID_FORMATS = ("json", "table", "plain")

# Options whose next argument is a value, not a flag. Without this, a literal
# search such as `task list --text --format` would have its search term
# swallowed by the format parser instead of reaching the service.
VALUE_OPTIONS = frozenset(
    {
        "--state",
        "--project",
        "--roadmap",
        "--workflow",
        "--type",
        "--label",
        "--assignee",
        "--priority",
        "--text",
        "--limit",
        "--offset",
        "--dod",
        "--sop",
        "--title",
        "--artifact",
        "--definition",
        "--description",
        "--kind",
        "--role",
        "--scope",
        "--after",
        "--file",
        "--target",
        "--task",
        "--digest",
        "--remove",
        "--as",
    }
)

# Response keys that carry a list of row objects, for table/plain rendering.
ROW_KEYS = (
    "tasks",
    "projects",
    "roadmaps",
    "workflows",
    "items",
    "todos",
    "boards",
    "columns",
    "filters",
    "actors",
    "grants",
    "revisions",
    "dependencies",
    "deps",
    "blockers",
    "events",
)


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


def extract_format(argv):
    """Consume --format/--format=VALUE from argv. Returns (format, remaining)."""
    fmt = "json"
    rest = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        # A value position belongs to the preceding option, never to --format.
        if index > 0 and argv[index - 1] in VALUE_OPTIONS:
            rest.append(arg)
            index += 1
            continue
        if arg == "--format":
            if index + 1 >= len(argv):
                fail("--format requires a value: json|table|plain")
            fmt = argv[index + 1]
            index += 2
            continue
        if arg.startswith("--format="):
            fmt = arg.split("=", 1)[1]
            index += 1
            continue
        rest.append(arg)
        index += 1
    if fmt not in VALID_FORMATS:
        fail(f"invalid --format value {fmt!r}: expected json|table|plain")
    return fmt, rest


def send(args, timeout, socket_path, max_bytes=MAX_RESPONSE_BYTES):
    """One request/response round trip. Returns the decoded JSON object."""
    body = json.dumps({"args": args}, separators=(",", ":")).encode()
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
        total = 0
        while True:
            chunk = client.recv(65_536)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                return {"ok": False, "error": "response too large"}
    except (OSError, TimeoutError) as error:
        fail(f"service unavailable: {error}")
    finally:
        client.close()

    response = b"".join(chunks)
    try:
        _headers, payload = response.split(b"\r\n\r\n", 1)
        return json.loads(payload)
    except (ValueError, json.JSONDecodeError):
        fail("invalid service response")


def inject_declared_actor(args, environ=os.environ):
    """Translate a caller-side SPRUCE_GOOSE_ACTOR into an explicit `--as`.

    The service reads SPRUCE_GOOSE_ACTOR from its own process environment, so
    the caller's variable never reaches it through the socket. An explicit
    `--as`/`--as=` anywhere in the vector wins unconditionally; with neither
    the vector is returned unchanged and the service refuses as before.
    """
    if any(arg == "--as" or arg.startswith("--as=") for arg in args):
        return args
    actor = environ.get("SPRUCE_GOOSE_ACTOR", "").strip()
    if not actor:
        return args
    return args + ["--as", actor]


def wants_auto_pagination(args):
    """True for a `task list` the caller did not already page itself."""
    if args[:2] != ["task", "list"]:
        return False
    for arg in args[2:]:
        if arg in ("--limit", "--offset") or arg.startswith(("--limit=", "--offset=")):
            return False
    return True


def paginated_task_list(args, timeout, socket_path):
    """Reassemble a full `task list` from bounded pages.

    The merged envelope reuses the first page's key order and scalar fields, so
    the result is shaped exactly like an unpaged listing. Rows are appended in
    server order and never filtered, deduplicated, or sorted here.
    """
    rows = []
    envelope = None
    offset = 0
    page_size = DEFAULT_PAGE_SIZE
    accumulated = 0

    while True:
        page = send(
            args + ["--limit", str(page_size), "--offset", str(offset)],
            timeout,
            socket_path,
        )
        if page.get("error") == "response too large":
            # A single page still overflowed. Shrink and retry rather than
            # raising the ceiling.
            if page_size == 1:
                return page
            page_size = max(1, page_size // 4)
            continue
        if not page.get("ok"):
            return page

        batch = page.get("tasks")
        if not isinstance(batch, list):
            return page
        if envelope is None:
            envelope = page

        rows.extend(batch)
        accumulated += len(json.dumps(batch, separators=(",", ":")))
        if len(rows) > MAX_TOTAL_ROWS or accumulated > MAX_TOTAL_BYTES:
            return {"ok": False, "error": "task list exceeds client assembly bounds; filter the query"}

        total = page.get("total")
        if not batch:
            break
        if isinstance(total, int) and len(rows) >= total:
            break
        if len(batch) < page_size:
            break
        offset += len(batch)

    if envelope is None:
        return {"ok": False, "error": "invalid service response"}

    merged = dict(envelope)
    merged["tasks"] = rows
    merged["count"] = len(rows)
    merged["offset"] = 0
    merged["limit"] = None
    return merged


def cell(value):
    """Render one value for display. Nothing is dropped or truncated."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return str(value)
    if not isinstance(value, str):
        value = json.dumps(value, separators=(",", ":"), sort_keys=True)
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def find_rows(decoded):
    """Return (key, rows) for a list-shaped response, else None."""
    for key in ROW_KEYS:
        value = decoded.get(key)
        if isinstance(value, list) and all(isinstance(row, dict) for row in value):
            return key, value
    return None


def render(decoded, fmt):
    """Render a response. Falls back to canonical JSON when there is no table."""
    canonical = json.dumps(decoded, separators=(",", ":"))
    if fmt == "json" or not decoded.get("ok"):
        return canonical

    found = find_rows(decoded)
    if found is None:
        return canonical
    _key, rows = found
    if not rows:
        return canonical

    # Column order: first row's keys, then any additional keys in the order
    # later rows introduce them. Every reported field gets a column.
    columns = []
    for row in rows:
        for name in row:
            if name not in columns:
                columns.append(name)

    table = [[cell(row.get(name)) if name in row else "" for name in columns] for row in rows]

    if fmt == "plain":
        lines = ["\t".join(columns)]
        lines.extend("\t".join(row) for row in table)
        return "\n".join(lines)

    widths = [len(name) for name in columns]
    for row in table:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def line(values):
        return "  ".join(value.ljust(widths[index]) for index, value in enumerate(values)).rstrip()

    lines = [line(columns), "  ".join("-" * width for width in widths).rstrip()]
    lines.extend(line(row) for row in table)
    return "\n".join(lines)


def main():
    fmt, args = extract_format(sys.argv[1:])
    args = inject_declared_actor(args)

    if len(args) > 128 or any(len(arg.encode()) > 4096 for arg in args):
        fail("invalid arguments")

    sop_preflight(args)

    socket_path = os.environ.get(
        "SPRUCE_GOOSE_CLI_SOCKET", f"/run/user/{os.getuid()}/sprucegoose/cli.sock"
    )
    timeout = float(os.environ.get("SPRUCE_GOOSE_CLI_CLIENT_TIMEOUT_SECONDS", "35"))

    if wants_auto_pagination(args):
        decoded = paginated_task_list(args, timeout, socket_path)
    else:
        decoded = send(args, timeout, socket_path)

    stream = sys.stdout if decoded.get("ok") else sys.stderr
    print(render(decoded, fmt), file=stream)
    raise SystemExit(0 if decoded.get("ok") else 2)


if __name__ == "__main__":
    main()
