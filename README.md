# pacman-statusline

A Pac-Man themed status line for [Claude Code](https://claude.com/claude-code).

![pacman-statusline in several pacing states](assets/mockup.png)

Rate-limit gauges use a Pac-Man metaphor to show where you *should* be in the
budget window versus where you actually are:

```
5h┃ 󰮯 · · ● · · · · 3h↻   7d┃  󰊠  󰮯 · ● · · · 4d↻   ctx:47%  opus·med
   │   │  │ │                 │     │                 │        │
   │   │  │ │                 │     │                 │        └─ model + effort
   │   │  │ │                 │     │                 └─ context remaining
   │   │  │ │                 │     └─ pac (you)
   │   │  │ │                 └─ ghost chasing (underspend — use it or lose it)
   │   │  │ └─ dim tail (anticipated / overspend)
   │   │  └─ power pellet (where you should be = target)
   │   └─ dots (edible budget between you and the pellet)
   └─ pac-man facing right (eating toward target)
```

When you outpace the budget, pac flips around (`󰮰`) and starts retreating past
the pellet. A ghost appears to chase or block based on how bad the pacing is.

## Segments

```
repo  branch  traffic  5h-gauge  7d-gauge  ctx  model  [git-stats]
```

- **repo** — current directory, colored by a stable hash of the repo name
- **branch** — yellow for `main`/`master`, cyan for feature branches
- **traffic** — frown face, brighter during business hours (8am–2pm Mon–Fri)
- **5h/7d gauge** — asymmetric pacing score, 10-cell pac-man bar + reset timer
- **ctx** — context window remaining, autocompact-aware, with a quality-budget
  display for 1M-context models
- **model** — opus/sonnet/haiku tier with escalating alerts when 7d is in danger
- **git-stats** — dirty counts and diffstat for the current repo (if in one)

## Install

macOS only for now. Requires [`uv`](https://docs.astral.sh/uv/) and `curl`.

**1. Patch the font.**

```bash
./install.sh
```

The installer:

- Downloads MesloLGS NF (all 4 weights) into `~/Library/Fonts/` if missing
- Backs up the pristine fonts as `*.ttf.bak`, then patches each with a
  horizontally-mirrored pac-man glyph inserted at the first free PUA-A
  codepoint above U+F1000
- Writes the chosen codepoint to `~/.config/pacman-statusline/config`

Restart your terminal afterwards so the patched font reloads.

**2. Point Claude Code at the script.**

In Claude Code, run:

```
/statusline
```

and paste the absolute path to `statusline-command.sh` in this repo. Claude
Code records the path in `~/.claude/settings.json` and picks up edits to the
script live — no copy or symlink required.

### Font

The right-facing pac-man (`󰮯`, U+F0BAF) and ghost (`󰊠`, U+F02A0) are native
to Nerd Fonts. The left-facing pac-man does not exist upstream — `install.sh`
generates it by reflecting U+F0BAF across its advance width and inserting the
result at a free codepoint picked per-machine (stored in the config above).

Reference glyphs extracted from a live patched font live in `assets/` for
documentation; the installer reproduces them from scratch and does not
consume them.

## Tests

`tests/matrix.sh` renders the statusline under ~80 synthetic JSON fixtures —
tier matrix, overspend, ghost positions, context gradient, model variants,
final-window sprint, git states, and degenerate inputs. Run it to eyeball the
full visual state space after any change:

```bash
bash tests/matrix.sh
```

## Architecture

The script is organized into "types," each owning a namespaced state prefix
and a family of functions:

| Type      | State prefix | Responsibility                                      |
|-----------|--------------|-----------------------------------------------------|
| `Input`   | `IN_*`       | Parse JSON once, narrow into typed fields           |
| `Repo`    | `REPO_*`     | Location, branch, hashed color                      |
| `Traffic` | —            | Business-hours frown                                |
| `Window`  | `W5_*`/`W7_*`| Asymmetric pacing + 5h adjustments (inherit/sprint) |
| `Gauge`   | —            | Stateless pac-man bar renderer                      |
| `Context` | `CTX_*`      | Autocompact-aware meter + quality budget            |
| `Model`   | `MODEL_*`    | Tier, 1M flag, effort, opus alert escalation        |
| `Git`     | `GIT_*`      | Dirty counts and diffstat                           |

`main()` at the bottom reads like prose: parse → compute → render.

## License

MIT — see [LICENSE](LICENSE).
