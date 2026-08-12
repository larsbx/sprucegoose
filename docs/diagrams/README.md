# SpruceGoose diagram source and export contract

The three `*.excalidraw` scenes in this directory are the authoritative visual sources. The adjacent SVG and PNG files are derived artifacts and must never be edited directly.

## Deterministic regeneration

Use exactly CairoSVG 2.8.2 through `uv`; the exporter deliberately rejects other versions and does not fall back to `rsvg-convert`:

```sh
~/.local/bin/uv run --with cairosvg==2.8.2 \
  python scripts/export-diagrams.py docs/diagrams/*.excalidraw
```

## Verification gates

Run all three gates before publishing or recording an immutable identity:

```sh
~/.local/bin/uv run --with cairosvg==2.8.2 \
  python scripts/check-diagram-parity.py

PYTHONOPTIMIZE=1 ~/.local/bin/uv run --with cairosvg==2.8.2 \
  python -O scripts/check-diagram-parity.py

~/.local/bin/uv run --with cairosvg==2.8.2 \
  python test/scripts/test-diagram-parity.py
```

The checker fails closed on source incompleteness, missing or duplicate one-to-one arrow/edge-label mappings, duplicate IDs, invalid ARIA references, undersized text, insufficient text or arrow contrast, missing arrowheads, non-opaque visual elements, derived-byte drift, and renderer-version drift. The negative regression deliberately corrupts an SVG and removes an edge label, proving both normal and optimized-Python checkers return nonzero.
