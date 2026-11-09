#!/usr/bin/env python3
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

D = 604_800


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
    root = subprocess.run(
        ["git", "-C", str(FAKE_REPO), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return root


def fixture(cwd: str, u7: int, tl7: int, ctx: int, model: str,
            cache_left: int | None = None, ttl: str = "1h",
            ctx_size: int = 200_000, effort: str = "high") -> str:
    now = int(time.time())
    data = {
        "workspace": {"current_dir": cwd},
        "rate_limits": {
            "seven_day": {"used_percentage": u7, "resets_at": now + tl7},
        },
        "context_window": {"remaining_percentage": ctx,
                           "context_window_size": ctx_size},
        "model": {"id": f"claude-{model.lower()}-5-5", "display_name": model},
        "effort": {"level": effort},
    }
    if cache_left is not None:
        data["prompt_cache"] = {
            "caching_observed": True, "warm": cache_left > 0, "ttl": ttl,
            "expires_at": now + cache_left,
        }
    return json.dumps(data)


def run_statusline(fixture_json: str) -> str:
    result = subprocess.run(
        ["bash", str(SL)],
        input=fixture_json, capture_output=True, text=True, check=True,
    )
    return result.stdout.rstrip("\n")


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
    fg, dim, bold, bg = "#cccccc", False, False, None
    parts = ANSI_RE.split(text)
    for i, part in enumerate(parts):
        if i % 2 == 0:
            if part:
                yield part, fg, dim, bold, bg
            continue
        codes = [int(c) for c in part.split(";") if c] or [0]
        j = 0
        while j < len(codes):
            c = codes[j]
            if c == 0:
                fg, dim, bold, bg = "#cccccc", False, False, None
            elif c == 1:
                bold = True
            elif c == 2:
                dim = True
            elif c == 22:
                dim = bold = False
            elif 30 <= c <= 37 or 90 <= c <= 97:
                fg = ANSI_16.get(c, "#cccccc")
            elif c in (38, 48) and j + 1 < len(codes):
                mode = codes[j + 1]
                color = None
                if mode == 5 and j + 2 < len(codes):
                    color = xterm256_to_hex(codes[j + 2])
                    j += 2
                elif mode == 2 and j + 4 < len(codes):
                    r, g, b = codes[j + 2], codes[j + 3], codes[j + 4]
                    color = f"#{r:02x}{g:02x}{b:02x}"
                    j += 4
                if color:
                    if c == 38:
                        fg = color
                    else:
                        bg = color
            j += 1


def xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def row_to_tspans(text: str) -> str:
    rects, spans, col = [], [], 0
    for s, fg, dim, bold, bg in parse_ansi(text):
        color = dim_hex(fg) if dim else fg
        weight = ' font-weight="bold"' if bold else ""
        spans.append(f'<tspan fill="{color}"{weight}>{xml_escape(s)}</tspan>')
        if bg:
            rects.append((col, len(s), bg))
        col += len(s)
    return rects, "".join(spans)


def build_configs(cwd: str):
    mid7 = D // 2
    return [
        ("on pace — fable 1M, cache fresh",
         fixture(cwd, u7=48, tl7=mid7, ctx=80, model="Fable", cache_left=3500,
                 ctx_size=1_000_000)),

        ("under-pacing — green, plenty of budget",
         fixture(cwd, u7=32, tl7=mid7, ctx=72, model="Opus", cache_left=2400)),

        ("deep underspend — purple, ghost chasing",
         fixture(cwd, u7=18, tl7=mid7, ctx=80, model="Sonnet", cache_left=1500)),

        ("mild overspend — yellow, cache cooling (<10m)",
         fixture(cwd, u7=62, tl7=mid7, ctx=40, model="Opus", cache_left=420)),

        ("red alert — 7d burning, ctx tightening, last cache minute",
         fixture(cwd, u7=82, tl7=mid7, ctx=22, model="Opus", cache_left=45)),

        ("final-window sprint — 7d resets in 1h, cache cold",
         fixture(cwd, u7=65, tl7=3600, ctx=48, model="Fable", cache_left=0)),

        ("haiku — calm, low pacing pressure",
         fixture(cwd, u7=30, tl7=mid7, ctx=88, model="Haiku", cache_left=2000)),
    ]


SVG_BG = "#161622"
SVG_FG_CAPTION = "#6e6a86"
FONT_SIZE = 20
CELL_W = FONT_SIZE * 0.602
CAPTION_SIZE = 11
ROW_GAP = 18
ROW_BLOCK = FONT_SIZE + CAPTION_SIZE + 8 + ROW_GAP
PAD_X = 36
PAD_Y = 36


def build_svg(rows) -> str:
    if not FONT.exists():
        sys.exit(f"error: font not found at {FONT}")
    font_b64 = base64.b64encode(FONT.read_bytes()).decode()

    width = 1060
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
    for caption, (rects, tspans) in rows:
        out.append(
            f'<text x="{PAD_X}" y="{y}" class="caption">'
            f'{xml_escape(caption.upper())}</text>'
        )
        for col, n, bg in rects:
            out.append(
                f'<rect x="{PAD_X + col * CELL_W:.1f}" y="{y + 10}" '
                f'width="{n * CELL_W:.1f}" height="{FONT_SIZE + 1}" fill="{bg}"/>'
            )
        out.append(
            f'<text x="{PAD_X}" y="{y + FONT_SIZE + 6}" class="mono" '
            f'xml:space="preserve">{tspans}</text>'
        )
        y += ROW_BLOCK

    out.append("</svg>")
    return "\n".join(out)


def rasterize_to_png() -> None:
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
