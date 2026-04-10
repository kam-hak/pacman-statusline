#!/usr/bin/env python3
"""Render pacman-statusline in several states as a single SVG mockup.

Runs ``statusline-command.sh`` against a throwaway ``pacman-statusline``
git repo with synthetic JSON fixtures covering the interesting visual
states (normal, under-pacing, overspend, sprint, 1M context, opus alert),
then parses the ANSI output and emits an SVG with one row per state.

MesloLGS NF Regular is embedded as base64 so the Nerd Font glyphs render
for anyone viewing the SVG without the font installed locally.

Run via ``uv run python3 scripts/render-mockup.py`` — no third-party deps.
Output: ``assets/mockup.svg``.
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SL = REPO / "statusline-command.sh"
FONT = Path.home() / "Library/Fonts/MesloLGS NF Regular.ttf"
CACHE_ROOT = Path.home() / "Library/Caches/pacman-statusline-mockup"
FAKE_REPO = CACHE_ROOT / "pacman-statusline"
OUTPUT_SVG = REPO / "assets" / "mockup.svg"
OUTPUT_PNG = REPO / "assets" / "mockup.png"
PNG_WIDTH = 3000

H = 18_000        # 5h window (seconds)
D = 604_800       # 7d window (seconds)


# ─── fake repo setup ────────────────────────────────────────────────────────

def setup_fake_repo() -> str:
    if FAKE_REPO.exists():
        import shutil
        shutil.rmtree(FAKE_REPO)
    FAKE_REPO.mkdir(parents=True)
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "mock", "GIT_AUTHOR_EMAIL": "mock@local",
        "GIT_COMMITTER_NAME": "mock", "GIT_COMMITTER_EMAIL": "mock@local",
    }
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=FAKE_REPO, check=True)
    subprocess.run(
        ["git", "commit", "-q", "--allow-empty", "-m", "init"],
        cwd=FAKE_REPO, env=env, check=True,
    )
    # Canonicalize (macOS /private prefix etc.)
    root = subprocess.run(
        ["git", "-C", str(FAKE_REPO), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return root


# ─── fixture builder ────────────────────────────────────────────────────────

def fixture(cwd: str, u5: int, tl5: int, u7: int, tl7: int,
            ctx: int, model: str) -> str:
    now = int(time.time())
    return json.dumps({
        "workspace": {"current_dir": cwd},
        "rate_limits": {
            "five_hour": {"used_percentage": u5, "resets_at": now + tl5},
            "seven_day": {"used_percentage": u7, "resets_at": now + tl7},
        },
        "context_window": {"remaining_percentage": ctx},
        "model": {"display_name": model},
    })


def run_statusline(fixture_json: str) -> str:
    result = subprocess.run(
        ["bash", str(SL)],
        input=fixture_json, capture_output=True, text=True, check=True,
    )
    return result.stdout.rstrip("\n")


# ─── ANSI parser ────────────────────────────────────────────────────────────

ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")

ANSI_16 = {
    30: "#2e3436", 31: "#cc3333", 32: "#4ec9b0", 33: "#e8d166",
    34: "#3b8eea", 35: "#bc3fbc", 36: "#11a8cd", 37: "#cccccc",
    90: "#6e6a86", 91: "#f14c4c", 92: "#23d18b", 93: "#f5f543",
    94: "#3b8eea", 95: "#d670d6", 96: "#29b8db", 97: "#f5f5f5",
}


def xterm256_to_hex(n: int) -> str:
    if n < 16:
        base = 30 + n if n < 8 else 90 + (n - 8)
        return ANSI_16.get(base, "#cccccc")
    if n >= 232:
        v = 8 + (n - 232) * 10
        return f"#{v:02x}{v:02x}{v:02x}"
    n -= 16
    r = (n // 36) % 6
    g = (n // 6) % 6
    b = n % 6

    def c(x: int) -> int:
        return 0 if x == 0 else 55 + x * 40

    return f"#{c(r):02x}{c(g):02x}{c(b):02x}"


def dim_hex(hex_color: str) -> str:
    r = int(hex_color[1:3], 16) // 2
    g = int(hex_color[3:5], 16) // 2
    b = int(hex_color[5:7], 16) // 2
    return f"#{r:02x}{g:02x}{b:02x}"


def parse_ansi(text: str):
    """Yield (substring, fg_hex, dim_bool) tuples."""
    fg = "#cccccc"
    dim = False
    parts = ANSI_RE.split(text)
    for i, part in enumerate(parts):
        if i % 2 == 0:
            if part:
                yield part, fg, dim
            continue
        codes = [int(c) for c in part.split(";") if c] or [0]
        j = 0
        while j < len(codes):
            c = codes[j]
            if c == 0:
                fg, dim = "#cccccc", False
            elif c == 2:
                dim = True
            elif c == 22:
                dim = False
            elif 30 <= c <= 37 or 90 <= c <= 97:
                fg = ANSI_16.get(c, "#cccccc")
            elif c == 38 and j + 1 < len(codes):
                mode = codes[j + 1]
                if mode == 5 and j + 2 < len(codes):
                    fg = xterm256_to_hex(codes[j + 2])
                    j += 2
                elif mode == 2 and j + 4 < len(codes):
                    r, g, b = codes[j + 2], codes[j + 3], codes[j + 4]
                    fg = f"#{r:02x}{g:02x}{b:02x}"
                    j += 4
            j += 1


def xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def row_to_tspans(text: str) -> str:
    out = []
    for s, fg, dim in parse_ansi(text):
        color = dim_hex(fg) if dim else fg
        out.append(f'<tspan fill="{color}">{xml_escape(s)}</tspan>')
    return "".join(out)


# ─── configs ────────────────────────────────────────────────────────────────

def build_configs(cwd: str):
    """Each entry is (caption, fixture_json)."""
    # midwindow pacing: target = 50, score = (used - 50) * 0.875
    #   purple ≤ -20  green ≤ -6  neutral ≤ 5  yellow ≤ 15  red > 15
    mid5, mid7 = H // 2, D // 2
    return [
        ("on pace — opus, normal load",
         fixture(cwd, u5=45, tl5=mid5, u7=48, tl7=mid7, ctx=54, model="Opus 4.6")),

        ("under-pacing — green, plenty of budget",
         fixture(cwd, u5=30, tl5=mid5, u7=32, tl7=mid7, ctx=72, model="Opus 4.6")),

        ("deep underspend — purple, ghost chasing",
         fixture(cwd, u5=18, tl5=mid5, u7=18, tl7=mid7, ctx=80, model="Opus 4.6")),

        ("mild overspend — yellow, pac retreating",
         fixture(cwd, u5=55, tl5=mid5, u7=62, tl7=mid7, ctx=40, model="Opus 4.6")),

        ("red alert — opus burning, ctx tightening",
         fixture(cwd, u5=70, tl5=mid5, u7=82, tl7=mid7, ctx=22, model="Opus 4.6")),

        ("final-window sprint — 7d resets inside 5h",
         fixture(cwd, u5=55, tl5=mid5, u7=65, tl7=3600, ctx=48, model="Opus 4.6")),

        ("haiku — calm, low pacing pressure",
         fixture(cwd, u5=25, tl5=mid5, u7=30, tl7=mid7, ctx=88, model="Haiku 4.5")),
    ]


# ─── SVG assembly ───────────────────────────────────────────────────────────

SVG_BG = "#161622"
SVG_FG_CAPTION = "#6e6a86"
FONT_SIZE = 20
CAPTION_SIZE = 11
ROW_GAP = 18          # gap between rows
ROW_BLOCK = FONT_SIZE + CAPTION_SIZE + 8 + ROW_GAP
PAD_X = 36
PAD_Y = 36


def build_svg(rows) -> str:
    if not FONT.exists():
        sys.exit(f"error: font not found at {FONT}")
    font_b64 = base64.b64encode(FONT.read_bytes()).decode()

    width = 1400
    height = PAD_Y * 2 + len(rows) * ROW_BLOCK - ROW_GAP

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<defs><style>",
        "@font-face {",
        '  font-family: "MesloLGS NF";',
        f'  src: url("data:font/ttf;base64,{font_b64}") format("truetype");',
        "}",
        'text.mono { font-family: "MesloLGS NF", "Menlo", monospace;',
        f'            font-size: {FONT_SIZE}px; }}',
        "text.caption { font-family: -apple-system, BlinkMacSystemFont, "
        '"SF Pro Text", sans-serif;',
        f'            font-size: {CAPTION_SIZE}px; '
        f'fill: {SVG_FG_CAPTION}; letter-spacing: 0.5px; }}',
        "</style></defs>",
        f'<rect width="{width}" height="{height}" fill="{SVG_BG}"/>',
    ]

    y = PAD_Y + CAPTION_SIZE
    for caption, tspans in rows:
        out.append(
            f'<text x="{PAD_X}" y="{y}" class="caption">'
            f'{xml_escape(caption.upper())}</text>'
        )
        out.append(
            f'<text x="{PAD_X}" y="{y + FONT_SIZE + 6}" class="mono" '
            f'xml:space="preserve">{tspans}</text>'
        )
        y += ROW_BLOCK

    out.append("</svg>")
    return "\n".join(out)


# ─── entry ──────────────────────────────────────────────────────────────────

def rasterize_to_png() -> None:
    """Use librsvg's rsvg-convert to rasterize the SVG at PNG_WIDTH px wide.

    Height scales proportionally, preserving the SVG's aspect ratio. We moved
    off macOS qlmanage because its WebKit renderer silently drops later
    <tspan> elements in long xml:space="preserve" <text> rows that embed an
    @font-face, and because `qlmanage -s N` always produces square output.

    GitHub's Markdown sanitizer strips <style> from SVGs, which breaks the
    embedded font — so README pages need a PNG, not the SVG directly. The SVG
    stays in-repo as the high-fidelity source artifact.
    """
    subprocess.run(
        [
            "rsvg-convert",
            "-w", str(PNG_WIDTH),
            "-o", str(OUTPUT_PNG),
            str(OUTPUT_SVG),
        ],
        capture_output=True, check=True,
    )


def main() -> int:
    cwd = setup_fake_repo()
    rows = []
    for caption, fix in build_configs(cwd):
        ansi = run_statusline(fix)
        rows.append((caption, row_to_tspans(ansi)))

    svg = build_svg(rows)
    OUTPUT_SVG.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_SVG.write_text(svg)
    svg_kb = OUTPUT_SVG.stat().st_size / 1024
    print(f"wrote {OUTPUT_SVG.relative_to(REPO)} ({svg_kb:.1f} KB, {len(rows)} rows)")

    rasterize_to_png()
    png_kb = OUTPUT_PNG.stat().st_size / 1024
    print(f"wrote {OUTPUT_PNG.relative_to(REPO)} ({png_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
