#!/usr/bin/env python3
"""Patch a Nerd Font TTF to add a horizontally-mirrored pac-man glyph.

Reads the right-facing pac-man at U+F0BAF, mirrors its outline across the
advance width, and inserts the result at the first free PUA-A codepoint
above U+F1000 (or at ``--target-codepoint`` if specified).

Prints the chosen codepoint (as ``0xXXXXX``) on the last line of stdout so
the installer can capture it via ``tail -n1``.

Intended to run via ``uv run --with fonttools python3 scripts/patch-font.py``.
"""
from __future__ import annotations

import argparse
import sys

from fontTools.misc.transform import Transform
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

SOURCE_CP = 0xF0BAF
SCAN_START = 0xF1000
SCAN_END = 0xF1FFF


def find_free_codepoint(font: TTFont) -> int:
    cmap = font.getBestCmap()
    for cp in range(SCAN_START, SCAN_END + 1):
        if cp not in cmap:
            return cp
    raise RuntimeError(f"no free codepoint in U+{SCAN_START:X}..U+{SCAN_END:X}")


def build_mirrored_glyph(font: TTFont, source_cp: int):
    cmap = font.getBestCmap()
    if source_cp not in cmap:
        raise RuntimeError(f"source glyph U+{source_cp:X} not found in font")
    source_name = cmap[source_cp]

    glyph_set = font.getGlyphSet()
    source = glyph_set[source_name]
    advance = source.width

    pen = TTGlyphPen(glyph_set)
    # x' = advance - x  ↔  scale(-1, 1) then translate(advance, 0)
    source.draw(TransformPen(pen, Transform(-1, 0, 0, 1, advance, 0)))
    return pen.glyph(), advance


def install_glyph(font: TTFont, glyph, advance: int, target_cp: int) -> str:
    name = f"uni{target_cp:04X}"

    glyf = font["glyf"]
    glyf[name] = glyph
    glyph.recalcBounds(glyf)

    lsb = glyph.xMin if getattr(glyph, "numberOfContours", 0) > 0 else 0
    font["hmtx"][name] = (advance, lsb)

    if name not in font.getGlyphOrder():
        font.glyphOrder.append(name)

    # Format 4 cmap subtables are BMP-only (<= U+FFFF). Anything in the
    # supplementary planes must go into a format 12/13 subtable.
    for subtable in font["cmap"].tables:
        if not subtable.isUnicode():
            continue
        if target_cp > 0xFFFF and subtable.format not in (12, 13):
            continue
        subtable.cmap[target_cp] = name

    return name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="input TTF path (pristine font)")
    ap.add_argument(
        "-o", "--output",
        help="output TTF path (default: overwrite input in place)",
    )
    ap.add_argument(
        "--target-codepoint",
        type=lambda s: int(s, 0),
        help="use this codepoint instead of scanning (hex like 0xF1000 or decimal)",
    )
    args = ap.parse_args()

    font = TTFont(args.input)

    if args.target_codepoint is not None:
        target = args.target_codepoint
        if target in font.getBestCmap():
            print(
                f"error: target U+{target:X} is already mapped in {args.input}",
                file=sys.stderr,
            )
            return 2
    else:
        target = find_free_codepoint(font)

    glyph, advance = build_mirrored_glyph(font, SOURCE_CP)
    install_glyph(font, glyph, advance, target)

    font.save(args.output or args.input)

    print(f"0x{target:X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
