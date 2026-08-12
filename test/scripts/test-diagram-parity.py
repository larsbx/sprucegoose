#!/usr/bin/env python3
"""Negative regressions: normal and optimized diagram gates must fail closed."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def copy_repo(parent: Path, name: str) -> Path:
    copy = parent / name
    shutil.copytree(ROOT / "docs", copy / "docs")
    shutil.copytree(ROOT / "scripts", copy / "scripts")
    return copy


def run_checker(copy: Path, optimized: bool) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    command = [sys.executable]
    if optimized:
        environment["PYTHONOPTIMIZE"] = "1"
        command.append("-O")
    command.append(str(copy / "scripts" / "check-diagram-parity.py"))
    return subprocess.run(command, cwd=copy, env=environment, capture_output=True, text=True)


def require_failure(result: subprocess.CompletedProcess[str], phrase: str) -> None:
    combined = result.stdout + result.stderr
    require(result.returncode != 0, f"checker accepted deliberate defect: {combined}")
    require(phrase in combined, f"checker failed for wrong reason: {combined}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sprucegoose-parity-negative-") as directory:
        parent = Path(directory)

        drift = copy_repo(parent, "drift")
        target = next((drift / "docs" / "diagrams").glob("*.svg"))
        target.write_bytes(target.read_bytes() + b"\n<!-- deliberate drift -->\n")
        require_failure(run_checker(drift, optimized=False), "derived drift")
        require_failure(run_checker(drift, optimized=True), "derived drift")

        missing_label = copy_repo(parent, "missing-label")
        scene = missing_label / "docs" / "diagrams" / "sprucegoose-rehearsal-workflow.excalidraw"
        data = json.loads(scene.read_text())
        removed = False
        kept = []
        for element in data["elements"]:
            if not removed and element.get("role") == "edge-label":
                removed = True
                continue
            kept.append(element)
        require(removed, "test fixture has no edge label to remove")
        data["elements"] = kept
        scene.write_text(json.dumps(data, indent=2) + "\n")
        require_failure(run_checker(missing_label, optimized=False), "one-to-one")
        require_failure(run_checker(missing_label, optimized=True), "one-to-one")

    print("diagram_normal_and_optimized_fail_closed=PASS")


if __name__ == "__main__":
    main()
