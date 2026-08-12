#!/usr/bin/env python3
"""Fail-closed verification that Excalidraw is the accessible reproducible source."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAGRAMS = ROOT / "docs" / "diagrams"
EXPORTER = ROOT / "scripts" / "export-diagrams.py"
BACKGROUND = "#020617"
REQUIRED_ROLES = {"title", "subtitle", "section", "edge-label", "node-label", "provenance"}
MIN_FONT_SIZE = {
    "title": 20,
    "subtitle": 16,
    "section": 12,
    "edge-label": 14,
    "node-label": 16,
    "provenance": 12,
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def luminance(color: str) -> float:
    require(bool(re.fullmatch(r"#[0-9a-fA-F]{6}", color)), f"unsupported color: {color!r}")
    values = [int(color[index : index + 2], 16) / 255 for index in (1, 3, 5)]
    values = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in values]
    return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]


def contrast(foreground: str, background: str) -> float:
    high, low = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def contains(rectangle: dict, text: dict) -> bool:
    center_x = float(text["x"]) + float(text.get("width", 0)) / 2
    center_y = float(text["y"]) + float(text.get("height", 0)) / 2
    return (
        float(rectangle["x"]) <= center_x <= float(rectangle["x"]) + float(rectangle["width"])
        and float(rectangle["y"]) <= center_y <= float(rectangle["y"]) + float(rectangle["height"])
    )


def effective_background(text: dict, rectangles: list[dict]) -> str:
    candidates = [rectangle for rectangle in rectangles if contains(rectangle, text)]
    if not candidates:
        return BACKGROUND
    # The smallest containing rectangle is the topmost semantic node rather than
    # a larger section background behind it.
    rectangle = min(candidates, key=lambda item: float(item["width"]) * float(item["height"]))
    return rectangle.get("backgroundColor") or BACKGROUND


def check_scene(scene: Path, data: dict) -> None:
    elements = [element for element in data["elements"] if not element.get("isDeleted", False)]
    ids = [str(element.get("id", "")) for element in elements]
    require(all(ids), f"{scene.name}: every visible element needs an ID")
    require(len(ids) == len(set(ids)), f"{scene.name}: duplicate source element ID")

    roles = {element.get("role") for element in elements}
    missing = REQUIRED_ROLES - roles
    require(not missing, f"{scene.name}: missing complete-source roles: {sorted(missing)}")

    rectangles = [element for element in elements if element["type"] == "rectangle"]
    texts = [element for element in elements if element["type"] == "text"]
    arrows = [element for element in elements if element["type"] == "arrow"]
    edge_labels = [element for element in texts if element.get("role") == "edge-label"]
    require(bool(arrows), f"{scene.name}: no arrows")
    arrow_ids = {arrow["id"] for arrow in arrows}
    label_edge_ids = [label.get("edgeId") for label in edge_labels]
    require(
        all(label_edge_ids),
        f"{scene.name}: every edge label must declare its arrow edgeId",
    )
    require(
        len(label_edge_ids) == len(set(label_edge_ids)),
        f"{scene.name}: duplicate edge-label mapping",
    )
    require(
        set(label_edge_ids) == arrow_ids,
        f"{scene.name}: edge labels do not map one-to-one to arrows",
    )

    for text in texts:
        role = text.get("role")
        require(role in MIN_FONT_SIZE, f"{scene.name}:{text['id']}: unknown text role {role!r}")
        size = int(text.get("fontSize", 0))
        require(size >= MIN_FONT_SIZE[role], f"{scene.name}:{text['id']}: {role} font size {size} is too small")
        require(int(text.get("opacity", 100)) == 100, f"{scene.name}:{text['id']}: text must be fully opaque")
        foreground = text.get("strokeColor")
        background = effective_background(text, rectangles)
        ratio = contrast(foreground, background)
        require(ratio >= 4.5, f"{scene.name}:{text['id']}: contrast {ratio:.2f} below AA on {background}")

    for arrow in arrows:
        require(arrow.get("endArrowhead") in {"arrow", "triangle"}, f"{scene.name}:{arrow['id']}: missing visible arrowhead")
        require(float(arrow.get("strokeWidth", 0)) >= 2, f"{scene.name}:{arrow['id']}: arrow stroke below 2 px")
        require(int(arrow.get("opacity", 100)) == 100, f"{scene.name}:{arrow['id']}: arrow must be fully opaque")
        ratio = contrast(arrow.get("strokeColor"), BACKGROUND)
        require(ratio >= 4.5, f"{scene.name}:{arrow['id']}: arrow contrast {ratio:.2f} below AA")


def check_svg(scene: Path, svg: str) -> None:
    require('role="img"' in svg, f"{scene.name}: SVG lacks role=img")
    require('aria-labelledby="svg-title svg-desc"' in svg, f"{scene.name}: invalid ARIA label references")
    ids = re.findall(r'\bid="([^"]+)"', svg)
    require(len(ids) == len(set(ids)), f"{scene.name}: duplicate exported SVG ID")
    require(ids.count("svg-title") == 1, f"{scene.name}: SVG title metadata missing or duplicated")
    require(ids.count("svg-desc") == 1, f"{scene.name}: SVG description metadata missing or duplicated")
    require(ids.count("svg-arrowhead") == 1, f"{scene.name}: arrow marker missing or duplicated")
    require(svg.count('marker-end="url(#svg-arrowhead)"') > 0, f"{scene.name}: exported arrows lack marker references")


def main() -> None:
    scenes = sorted(DIAGRAMS.glob("*.excalidraw"))
    require(len(scenes) == 3, f"expected 3 scenes, found {len(scenes)}")

    with tempfile.TemporaryDirectory(prefix="sprucegoose-diagrams-") as directory:
        temporary = Path(directory)
        copied = []
        for scene in scenes:
            data = json.loads(scene.read_text())
            check_scene(scene, data)
            target = temporary / scene.name
            shutil.copy2(scene, target)
            copied.append(target)

        subprocess.run([sys.executable, str(EXPORTER), *map(str, copied)], check=True, cwd=ROOT)
        for scene in scenes:
            for suffix in (".svg", ".png"):
                committed = scene.with_suffix(suffix)
                regenerated = temporary / committed.name
                require(committed.read_bytes() == regenerated.read_bytes(), f"derived drift: {committed}")
            check_svg(scene, scene.with_suffix(".svg").read_text())

    print("diagram_source_export_parity=PASS scenes=3 exports=6 renderer=cairosvg-2.8.2 contrast=AA")


if __name__ == "__main__":
    main()
