# pacman-statusline

A Pac-Man themed status line for [Claude Code](https://claude.com/claude-code).

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

## Usage

Claude Code reads its status line from `~/.claude/statusline-command.sh`. The
authoritative source of truth lives in this repo. To wire Claude Code up to
it, symlink the repo file into place:

```bash
ln -sf "$PWD/statusline-command.sh" ~/.claude/statusline-command.sh
```

After that, editing `statusline-command.sh` in this repo changes Claude Code's
status line immediately on the next render — no copy step.

### Font

The left-facing pac-man glyph (`󰮰` at U+F0BB0) is a **custom patch** on top of
MesloLGS NF. Without the patched font, overspend rendering falls back to the
default glyph at that codepoint (usually `.notdef`). The right-facing pac-man
(`󰮯`, U+F0BAF) and ghost (`󰊠`, U+F02A0) are native to Nerd Fonts.

Patching source (SVG, font-patcher config, etc.) → TBD, drop into `assets/`
if found.

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
