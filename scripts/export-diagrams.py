#!/usr/bin/env python3
"""Deterministically export SpruceGoose Excalidraw scenes to accessible SVG/PNG.

The .excalidraw scene is the sole visual source. Supported scene elements are
rectangle, text, and arrow; fail closed on any other visible element.
"""
from __future__ import annotations

import argparse
import html
import json
from pathlib import Path

BACKGROUND = "#020617"
DEFAULT_STROKE = "#94a3b8"
DEFAULT_TEXT = "#e2e8f0"
FONT = "Inter, ui-sans-serif, system-ui, sans-serif"
CAIROSVG_VERSION = "2.8.2"


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def opacity(element: dict) -> float:
    return max(0, min(100, int(element.get("opacity", 100) or 100))) / 100


def render_text(element: dict) -> str:
    x = float(element["x"])
    y = float(element["y"])
    width = float(element.get("width", 0))
    size = int(element.get("fontSize", 18))
    align = element.get("textAlign", "left")
    anchor = {"left": "start", "center": "middle", "right": "end"}.get(align, "start")
    if anchor == "middle":
        x += width / 2
    elif anchor == "end":
        x += width
    color = element.get("strokeColor") or DEFAULT_TEXT
    weight = 700 if element.get("role") in {"title", "section"} else 500
    lines = str(element.get("text", "")).splitlines() or [""]
    spans = []
    for index, line in enumerate(lines):
        dy = size if index == 0 else round(size * 1.25, 2)
        spans.append(f'<tspan x="{x:g}" dy="{dy:g}">{esc(line)}</tspan>')
    return (
        f'<text id="scene-{esc(element["id"])}" x="{x:g}" y="{y:g}" '
        f'fill="{esc(color)}" font-family="{FONT}" font-size="{size}" '
        f'font-weight="{weight}" text-anchor="{anchor}" opacity="{opacity(element):g}">'
        + "".join(spans)
        + "</text>"
    )


def render_rectangle(element: dict) -> str:
    fill = element.get("backgroundColor") or "none"
    stroke = element.get("strokeColor") or DEFAULT_STROKE
    radius = min(16, float(element.get("roundness", {}).get("value", 12) if isinstance(element.get("roundness"), dict) else 12))
    return (
        f'<rect id="scene-{esc(element["id"])}" x="{float(element["x"]):g}" '
        f'y="{float(element["y"]):g}" width="{float(element["width"]):g}" '
        f'height="{float(element["height"]):g}" rx="{radius:g}" fill="{esc(fill)}" '
        f'stroke="{esc(stroke)}" stroke-width="{float(element.get("strokeWidth", 2) or 2):g}" '
        f'opacity="{opacity(element):g}"/>'
    )


def render_arrow(element: dict) -> str:
    x = float(element["x"])
    y = float(element["y"])
    points = element.get("points") or [[0, 0], [element.get("width", 0), element.get("height", 0)]]
    coords = " ".join(f"{x + float(px):g},{y + float(py):g}" for px, py in points)
    stroke = element.get("strokeColor") or DEFAULT_STROKE
    return (
        f'<polyline id="scene-{esc(element["id"])}" points="{coords}" fill="none" '
        f'stroke="{esc(stroke)}" stroke-width="{float(element.get("strokeWidth", 2) or 2):g}" '
        f'stroke-linecap="round" stroke-linejoin="round" marker-end="url(#svg-arrowhead)" '
        f'opacity="{opacity(element):g}"/>'
    )


def export_scene(source: Path, png: bool = True) -> tuple[Path, Path | None]:
    scene = json.loads(source.read_text())
    elements = [element for element in scene["elements"] if not element.get("isDeleted", False)]
    unsupported = sorted({element["type"] for element in elements} - {"rectangle", "text", "arrow"})
    if unsupported:
        raise SystemExit(f"unsupported Excalidraw elements in {source}: {unsupported}")
    width = int(scene.get("appState", {}).get("exportWidth", 1500))
    height = int(scene.get("appState", {}).get("exportHeight", max(e["y"] + e.get("height", 0) for e in elements) + 35))
    title = next((e["text"] for e in elements if e.get("role") == "title"), source.stem)
    subtitle = next((e["text"] for e in elements if e.get("role") == "subtitle"), "Governed SpruceGoose system diagram")
    rendered = []
    layer = {"section": 0, "arrow": 1, "rectangle": 2, "text": 3}
    elements = sorted(
        enumerate(elements),
        key=lambda item: (
            layer["section"]
            if item[1].get("role") == "section-background"
            else layer[item[1]["type"]],
            item[0],
        ),
    )
    for _index, element in elements:
        rendered.append({"rectangle": render_rectangle, "text": render_text, "arrow": render_arrow}[element["type"]](element))
    svg = source.with_suffix(".svg")
    svg.write_text(
        "\n".join(
            [
                f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="svg-title svg-desc">',
                f"<title id=\"svg-title\">{esc(title)}</title>",
                f"<desc id=\"svg-desc\">{esc(subtitle)}</desc>",
                f'<rect width="100%" height="100%" fill="{BACKGROUND}"/>',
                '<defs><marker id="svg-arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto"><polygon points="0 0, 10 3.5, 0 7" fill="#94a3b8"/></marker></defs>',
                *rendered,
                "</svg>",
            ]
        )
        + "\n"
    )
    png_path = source.with_suffix(".png") if png else None
    if png_path:
        try:
            import cairosvg
        except ImportError as error:
            raise SystemExit(
                f"PNG export requires pinned CairoSVG: uv run --with cairosvg=={CAIROSVG_VERSION} "
                "python scripts/export-diagrams.py ..."
            ) from error
        if cairosvg.__version__ != CAIROSVG_VERSION:
            raise SystemExit(
                f"CairoSVG {CAIROSVG_VERSION} required; found {cairosvg.__version__}"
            )
        cairosvg.svg2png(url=str(svg), write_to=str(png_path), output_width=width, output_height=height)
    return svg, png_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("scenes", nargs="+", type=Path)
    parser.add_argument("--no-png", action="store_true")
    args = parser.parse_args()
    for scene in args.scenes:
        svg, png = export_scene(scene, not args.no_png)
        print(svg)
        if png:
            print(png)


if __name__ == "__main__":
    main()
