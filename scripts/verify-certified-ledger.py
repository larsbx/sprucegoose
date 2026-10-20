#!/usr/bin/env python3
"""Verify an exported SpruceGoose certified ledger without the BEAM.

Reads the JSONL written by `sprucegoose ledger export PATH`. For every event in
the jcs-v1 canonical form it recomputes the identity as SHA-256 over the RFC
8785 canonicalisation of {event_type, idempotency_key, payload, roots, stream}
and compares it with the recorded identity. It also checks that every stream's
positions are contiguous from 1. Legacy etf-v1 events are counted, not
recomputed: their identity needs Erlang External Term Format.

Exit status 0 means every checked identity and every stream order held.
"""
import hashlib
import json
import sys

MAX_SAFE = 2**53 - 1


def jcs(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        if abs(value) > MAX_SAFE:
            raise ValueError("integer outside the canonical range")
        return str(value)
    if isinstance(value, float):
        raise ValueError("floats are not canonical in this ledger")
    if isinstance(value, str):
        return '"' + escape(value) + '"'
    if isinstance(value, list):
        return "[" + ",".join(jcs(v) for v in value) + "]"
    if isinstance(value, dict):
        pairs = sorted(value.items(), key=lambda kv: kv[0].encode("utf-16-be"))
        return "{" + ",".join('"' + escape(k) + '":' + jcs(v) for k, v in pairs) + "}"
    raise ValueError(f"unsupported type {type(value).__name__}")


def escape(text):
    out = []
    for ch in text:
        code = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif code == 8:
            out.append("\\b")
        elif code == 12:
            out.append("\\f")
        elif code == 10:
            out.append("\\n")
        elif code == 13:
            out.append("\\r")
        elif code == 9:
            out.append("\\t")
        elif code < 0x20:
            out.append("\\u%04x" % code)
        else:
            out.append(ch)
    return "".join(out)


def main(path):
    with open(path, "r", encoding="utf-8") as handle:
        lines = [line for line in handle.read().split("\n") if line]
    header = json.loads(lines[0])
    if header.get("schema") != "sprucegoose-certified-ledger-export-v1":
        print("unknown export schema", file=sys.stderr)
        return 2
    events = [json.loads(line) for line in lines[1:]]
    if len(events) != header.get("events"):
        print(f"header says {header.get('events')} events, file has {len(events)}", file=sys.stderr)
        return 2

    verified = legacy = failed = 0
    positions = {}
    for event in events:
        expected = positions.get(event["stream"], 0) + 1
        if event["stream_position"] != expected:
            print(f"stream {event['stream']} position {event['stream_position']}, expected {expected}", file=sys.stderr)
            failed += 1
        positions[event["stream"]] = event["stream_position"]

        if event["canonical_form"] != "jcs-v1":
            legacy += 1
            continue
        subject = {k: event[k] for k in ("event_type", "idempotency_key", "payload", "roots", "stream")}
        digest = hashlib.sha256(jcs(subject).encode("utf-8")).hexdigest()
        if "sha256:" + digest == event["identity"]:
            verified += 1
        else:
            failed += 1
            print(f"sequence {event['sequence']}: identity mismatch", file=sys.stderr)

    print(f"events={len(events)} verified={verified} legacy={legacy} failed={failed} streams={len(positions)}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: verify-certified-ledger.py EXPORT.jsonl", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
