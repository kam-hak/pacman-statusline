#!/usr/bin/env bash
# Claude Code status line — Pac-Man edition
#
# Segments: location  branch  traffic  5h-gauge  7d-gauge  ctx  model  [git]
#
# Structure (read top → bottom):
#   Constants   — colors, tiers, glyphs
#   Formatters  — ftime
#   Tier        — pacing score → semantic tier → ANSI color
#   Input       — parse JSON once, narrow into IN_* state
#   Repo        — location, branch, hashed color
#   Traffic     — business-hours frown
#   Window      — PacingWindow base + Window5h / Window7d adjustments
#   Gauge       — pac-man bar renderer (stateless, takes used/target/color/score)
#   Context     — autocompact-aware meter + quality-budget
#   Model       — tier + 1M + effort, with opus 7d-pacing alerts
#   Git         — dirty counts + diffstat
#   main        — parse → compute → render
#
# Each "type" owns a namespaced state prefix (REPO_*, W5_*, W7_*, CTX_*, MODEL_*,
# GIT_*) and a small family of functions. Downstream code reads the typed state,
# never the raw JSON. Complex logic (window5 adjustments, gauge cell dispatch)
# is broken into named helpers, one concern each.
#
# Requires: MesloLGS NF patched with left-facing pac-man at U+F0BB0.

input=$(cat)
echo "$input" > /tmp/claude-sl-debug.json

# ═══════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════

# ANSI color codes
C_PUR="38;5;99"   # purple — YOLO, way behind
C_GRN=32          # green  — headroom
C_WHT=37          # white  — on track
C_YEL=33          # yellow — outpacing / main branch
C_RED=31          # red    — danger
C_DIM=90          # dim gray
C_BRT=97          # bright white
C_CYN=36          # cyan   — feature branches

# Semantic tiers (ascending: worst → best).
# Positive states (underspending): T_NEUTRAL → T_GREEN → T_PURPLE
# Negative states (overspending):  T_NEUTRAL → T_YELLOW → T_RED
T_RED=0; T_YELLOW=1; T_NEUTRAL=2; T_GREEN=3; T_PURPLE=4

# Glyphs (UTF-8 bytes)
_PAC_R=$'\xf3\xb0\xae\xaf'    # 󰮯 right-facing pac-man
_PAC_L=$'\xf3\xb0\xae\xb0'    # 󰮰 left-facing pac-man (patched in)
_GHOST=$'\xf3\xb0\x8a\xa0'    # 󰊠 ghost
_DOT=$'\xc2\xb7'              # · middle dot
_PELLET=$'\xe2\x97\x8f'       # ● power pellet
_BAR=$'\xe2\x94\x83'          # ┃ heavy vertical
_RESET=$'\xe2\x86\xbb'        # ↻ clockwise open arrow
_FROWN=$'\xe2\x98\xb9'        # ☹ sad face
_WT=$'\xe2\x8e\x87'           # ⎇ alternative key (worktree indicator)
_OCTO=$'\xef\x84\x93'         #  github octocat (nerd font)

# Optional config override for the left-pac codepoint. install.sh scans the
# user's patched font for a free PUA slot and writes PAC_L_CODEPOINT here;
# without a config file we fall back to the hardcoded bytes above.
_pml_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pacman-statusline/config"
if [[ -f "$_pml_cfg" ]]; then
  # shellcheck source=/dev/null
  . "$_pml_cfg"
  if [[ -n "${PAC_L_CODEPOINT:-}" ]]; then
    _cp=$(( PAC_L_CODEPOINT ))
    if (( _cp >= 0x10000 )); then
      # Encode as 4-byte UTF-8. bash 3.2 has no \U escape, so we build the
      # \xNN sequence with printf and then %b-interpret it into real bytes.
      _fmt=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $(( 0xF0 | ((_cp >> 18) & 0x07) )) \
        $(( 0x80 | ((_cp >> 12) & 0x3F) )) \
        $(( 0x80 | ((_cp >>  6) & 0x3F) )) \
        $(( 0x80 |  (_cp        & 0x3F) )))
      _PAC_L=$(printf '%b' "$_fmt")
      unset _fmt
    fi
    unset _cp
  fi
fi
unset _pml_cfg

# ═══════════════════════════════════════════════════════════════════
# Formatters
# ═══════════════════════════════════════════════════════════════════

# Format seconds into compact 2-char time: 42m, 3h, 6d. Rounds at .5.
ftime() {
  local s=$1
  if   (( s <= 0 ));    then echo "now"
  elif (( s < 5940 ));  then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 86400 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                       echo "$(( (s + 43200) / 86400 ))d"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# Tier: pacing score → semantic tier → ANSI color
# ═══════════════════════════════════════════════════════════════════

tier_of() {
  local score=$1
  if   (( score <= -20 )); then echo $T_PURPLE
  elif (( score <=  -6 )); then echo $T_GREEN
  elif (( score <=   6 )); then echo $T_NEUTRAL
  elif (( score <=  15 )); then echo $T_YELLOW
  else                          echo $T_RED
  fi
}

tier_color() {
  case $1 in
    $T_PURPLE)  echo $C_PUR ;;
    $T_GREEN)   echo $C_GRN ;;
    $T_NEUTRAL) echo $C_WHT ;;
    $T_YELLOW)  echo $C_YEL ;;
    *)          echo $C_RED ;;
  esac
}

score_color() { tier_color "$(tier_of "$1")"; }

# ═══════════════════════════════════════════════════════════════════
# Input: parse JSON once, narrow into IN_* state
# ═══════════════════════════════════════════════════════════════════

IN_cwd=""; IN_rl5_used=""; IN_rl5_reset=""; IN_rl7_used=""; IN_rl7_reset=""
IN_ctx=""; IN_model_name=""; IN_effort=""; IN_autocompact=""; IN_now=0

input_parse() {
  IN_cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
  IN_rl5_used=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
  IN_rl5_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
  IN_rl7_used=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
  IN_rl7_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)
  IN_ctx=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty' 2>/dev/null)
  IN_model_name=$(echo "$input" | jq -r '.model.display_name // ""' 2>/dev/null)
  IN_effort=$(jq -r '.effortLevel // ""' "$HOME/.claude/settings.json" 2>/dev/null)
  IN_autocompact=$(jq -r '.autoCompact // "unset"' "$HOME/.claude/settings.json" 2>/dev/null)
  IN_now=$(date +%s)
}

# ═══════════════════════════════════════════════════════════════════
# Repo: location + branch + hashed color
# ═══════════════════════════════════════════════════════════════════

# Stable hash → one of 16 visually distinct 256-colors. Same repo → same color.
_REPO_COLORS=(196 202 214 226 154 46 48 51 45 39 33 99 129 163 198 205)

REPO_root=""; REPO_name=""; REPO_branch=""; REPO_location=""; REPO_color=0

repo_parse() {
  if [ -n "$IN_cwd" ] && git -C "$IN_cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_root=$(git -C "$IN_cwd" -c gc.auto=0 rev-parse --show-toplevel 2>/dev/null)
    REPO_name=$(basename "$REPO_root")
    REPO_location=$(_repo_compact_path "$IN_cwd" "$REPO_root" "$REPO_name")
    REPO_branch=$(git -C "$IN_cwd" -c gc.auto=0 symbolic-ref --short HEAD 2>/dev/null \
      || git -C "$IN_cwd" -c gc.auto=0 rev-parse --short HEAD 2>/dev/null)
  else
    REPO_location="${IN_cwd/#$HOME/~}"
  fi
  REPO_color=$(_repo_color_hash "${REPO_name:-$REPO_location}")
}

# "reponame/a/b/leaf" — intermediate dirs abbreviated to first char, leaf full.
_repo_compact_path() {
  local cwd=$1 root=$2 name=$3
  local rel="${cwd#$root}"
  rel="${rel#/}"
  [ -z "$rel" ] && { echo "$name"; return; }

  local parts loc i n
  IFS='/' read -ra parts <<< "$rel"
  n=${#parts[@]}
  loc="$name"
  for (( i=0; i < n-1; i++ )); do
    loc="$loc/${parts[$i]:0:1}"
  done
  echo "$loc/${parts[$n-1]}"
}

_repo_color_hash() {
  local h
  h=$(printf '%s' "$1" | cksum | awk '{print $1}')
  echo "${_REPO_COLORS[$(( h % ${#_REPO_COLORS[@]} ))]}"
}

repo_segment_location() {
  printf "\033[38;5;%dm%s\033[0m" "$REPO_color" "$REPO_location"
}

# Yellow for main/master (safe trunk), cyan for feature branches.
repo_segment_branch() {
  [ -z "$REPO_branch" ] && return
  case "$REPO_branch" in
    main|master) printf " \033[${C_YEL}m%s\033[0m" "$REPO_branch" ;;
    *)           printf " \033[${C_CYN}m%s\033[0m" "$REPO_branch" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════
# Traffic: business-hours frown (8am–2pm Mon–Fri)
# ═══════════════════════════════════════════════════════════════════

traffic_segment() {
  local hour dow color
  hour=$(date +%H)
  dow=$(date +%u)
  if (( 10#$dow >= 1 && 10#$dow <= 5 )) && (( 10#$hour >= 8 && 10#$hour < 14 )); then
    color="38;5;172"   # muted orange
  else
    color="$C_DIM"
  fi
  printf " \033[${color}m%s\033[0m" "$_FROWN"
}

# ═══════════════════════════════════════════════════════════════════
# Window: asymmetric pacing over a rolling window
#
# Per-window state: W{5,7}_{used,target,time_left,score,present}
# Downstream code (gauge, model alerts) reads these fields directly.
# Raw used_percentage/reset_at stays trapped inside window*_parse.
# ═══════════════════════════════════════════════════════════════════

W5_used=0; W5_target=0; W5_time_left=0; W5_score=0; W5_present=0
W7_used=0; W7_target=0; W7_time_left=0; W7_score=0; W7_present=0

# Core pacing calculation.
# Asymmetric amp — overspending is worst early (compounds), underspending is
# worst late (wasting). Squared curve: gentle midwindow, sharp at extremes.
# args: used% reset_ts window_size_secs
# echoes: "score target time_left"
_window_compute() {
  local u=$1 reset=$2 ws=$3
  local tl=$(( reset - IN_now ))
  (( tl < 0 )) && tl=0

  local tl_pct=$(( tl * 100 / ws ))
  local target=$(( 100 - tl_pct ))
  local dev=$(( u - target ))

  local amp100
  if (( dev >= 0 )); then
    amp100=$(( 50 + 150 * tl_pct * tl_pct / 10000 ))
  else
    local el_pct=$(( 100 - tl_pct ))
    amp100=$(( 50 + 150 * el_pct * el_pct / 10000 ))
  fi

  local score=$(( dev * amp100 / 100 ))
  echo "$score $target $tl"
}

# ─── Window7d: simple compute, no adjustments ───

window7_parse() {
  if [ -z "$IN_rl7_used" ] || [ "$IN_rl7_used" = "null" ]; then return; fi
  W7_present=1
  W7_used=$(printf '%.0f' "$IN_rl7_used" 2>/dev/null) || W7_used=0
  if [ -z "$IN_rl7_reset" ] || [ "$IN_rl7_reset" = "null" ]; then return; fi
  read -r W7_score W7_target W7_time_left \
    <<< "$(_window_compute "$W7_used" "$IN_rl7_reset" 604800)"
}

# ─── Window5h: compute, then apply four adjustments in order ───

window5_parse() {
  if [ -z "$IN_rl5_used" ] || [ "$IN_rl5_used" = "null" ]; then return; fi
  W5_present=1
  W5_used=$(printf '%.0f' "$IN_rl5_used" 2>/dev/null) || W5_used=0
  if [ -z "$IN_rl5_reset" ] || [ "$IN_rl5_reset" = "null" ]; then return; fi
  read -r W5_score W5_target W5_time_left \
    <<< "$(_window_compute "$W5_used" "$IN_rl5_reset" 18000)"

  _window5_inherit_from_7d
  _window5_sprint_if_final_window
  _window5_ensure_visible_dots
  _window5_cap_positive_tier
}

# 7d pressure propagates down to 5h. When weekly is behind, encourage 5h
# spending ("use it or lose it"). Otherwise clamp 5h underspend to neutral.
_window5_inherit_from_7d() {
  if (( W7_score <= -20 )); then
    local floor=$(( W7_score / 2 ))
    (( W5_score > floor )) && W5_score=$floor
  elif (( W7_score <= -6 )); then
    local floor=$(( W7_score / 3 ))
    (( W5_score > floor )) && W5_score=$floor
  elif (( W5_score < 0 )); then
    W5_score=0
  fi
}

# Final-window sprint: when 7d resets inside one 5h window, this IS the
# last 5h. Burn everything — unless weekly is already nearly empty (<7%).
# One 5h window ≈ 7% of weekly (burst cap, not linear slice).
_window5_sprint_if_final_window() {
  (( W7_time_left <= 0 || W7_time_left >= 18000 )) && return
  local weekly_remaining=$(( 100 - W7_used ))
  (( weekly_remaining < 7 )) && return

  W5_target=$(( weekly_remaining * 100 / 7 ))
  (( W5_target > 100 )) && W5_target=100
  (( W5_score > -20 )) && W5_score=-25
}

# Pellet must be ≥30% ahead of used so dots are always visible.
# 5h is "use it or lose it" — the pellet represents available budget.
_window5_ensure_visible_dots() {
  local min=$(( W5_used + 30 ))
  (( min > 100 )) && min=100
  (( W5_target < min )) && W5_target=$min
}

# 5h cannot display a better positive tier than 7d. Both pac color and
# ghost color inherit from this score, so capping here covers both.
_window5_cap_positive_tier() {
  local t5 t7
  t5=$(tier_of "$W5_score")
  t7=$(tier_of "$W7_score")
  (( t5 <= T_NEUTRAL )) && return
  (( t5 <= t7 )) && return
  case $t7 in
    $T_NEUTRAL) W5_score=-5  ;;   # just inside white (> -6 threshold)
    $T_GREEN)   W5_score=-19 ;;   # just inside green (> -20 threshold)
  esac
}

# ═══════════════════════════════════════════════════════════════════
# Gauge: pac-man pacing bar (10 cells)
#
# Actors:
#   󰮯 pac right — eating toward target (underspend/on pace)
#   󰮰 pac left  — retreating past target (overspend)
#   ● pellet    — target position (hidden when overspent)
#   · dot       — between pac and pellet (edible, in pac's color)
#   · dim dot   — beyond pellet / overspend tail (anticipated)
#   󰊠 ghost     — chases from behind or blocks ahead, distance by severity
#
# Ghost distance rules:
#   |score| < 6:    no ghost (dead zone, on pace)
#   green behind:   gap 2..4, hidden beyond
#   purple behind:  adjacent ok
#   yellow ahead:   gap ≥1, hidden if adjacent
#   red ahead:      adjacent ok
# ═══════════════════════════════════════════════════════════════════

# Stateless: all inputs explicit, all rendering self-contained.
gauge_render() {
  local used=$1 target=$2 color=$3 score=$4 width=${5:-10}

  local ppos=$(( used * width / 100 ))
  local tpos=$(( target * width / 100 ))
  (( ppos >= width )) && ppos=$(( width - 1 ))
  (( ppos < 0 ))      && ppos=0
  (( tpos >= width )) && tpos=$(( width - 1 ))
  (( tpos < 0 ))      && tpos=0

  local overspend=0
  (( ppos > tpos )) && overspend=1

  local pac="$_PAC_R"
  (( overspend )) && pac="$_PAC_L"

  local gpos
  gpos=$(_gauge_ghost_pos "$ppos" "$score" "$width")

  local i
  for (( i=0; i<width; i++ )); do
    _gauge_cell "$i" "$ppos" "$tpos" "$gpos" "$overspend" "$color" "$pac"
  done
}

# Ghost position by pacing severity. -1 = hidden.
_gauge_ghost_pos() {
  local ppos=$1 score=$2 width=$3
  local abs=${score#-}
  local gap gpos=-1

  if (( score < -20 )); then
    gap=$(( 4 - (abs - 20) / 10 ))
    (( gap < 1 )) && gap=1
    gpos=$(( ppos - gap ))
  elif (( score < -6 )); then
    gap=$(( 2 + (abs - 6) / 5 ))
    (( gap > 4 )) && { echo -1; return; }
    gpos=$(( ppos - gap ))
  elif (( score > 15 )); then
    gpos=$(( ppos + 1 ))
  elif (( score > 6 )); then
    gap=$(( 3 - (score - 6) / 4 ))
    (( gap < 1 )) && gap=1
    gpos=$(( ppos + gap ))
  fi

  (( gpos < 0 || gpos >= width )) && gpos=-1
  echo "$gpos"
}

# Dispatch one cell. Priority: pac > ghost > pellet > eaten > edible > dim.
_gauge_cell() {
  local i=$1 ppos=$2 tpos=$3 gpos=$4 overspend=$5 c=$6 pac=$7
  if   (( i == ppos )); then
    printf "\033[${c}m%s\033[0m" "$pac"
  elif (( gpos >= 0 && i == gpos )); then
    printf "\033[${c}m%s\033[0m" "$_GHOST"
  elif (( !overspend && i == tpos )); then
    printf "\033[${c}m%s\033[0m" "$_PELLET"
  elif (( i < ppos )); then
    printf " "
  elif (( !overspend && i > ppos && i < tpos )); then
    printf "\033[${c}m%s\033[0m" "$_DOT"
  else
    printf "\033[${C_DIM}m%s\033[0m" "$_DOT"
  fi
}

# Is the last gauge cell occupied by pac or pellet? Timer text brightens when so.
_gauge_timer_edible() {
  local used=$1 target=$2 w=10
  local pp=$(( used * w / 100 ))
  local tp=$(( target * w / 100 ))
  (( pp > w-1 )) && pp=$(( w-1 ))
  (( tp > w-1 )) && tp=$(( w-1 ))
  (( pp == w-1 )) || (( tp == w-1 && pp <= tp ))
}

# Render one full segment: "  <label>┃<gauge><timer>↻"
window_gauge_segment() {
  local label=$1 used=$2 target=$3 score=$4 time_left=$5
  local color tc
  color=$(score_color "$score")

  printf "  %s\033[${C_DIM}m%s\033[0m" "$label" "$_BAR"
  gauge_render "$used" "$target" "$color" "$score"

  (( time_left <= 0 )) && return
  if _gauge_timer_edible "$used" "$target"; then tc=$C_WHT; else tc=$C_DIM; fi
  printf "\033[${tc}m%s%s\033[0m" "$(ftime $time_left)" "$_RESET"
}

# ═══════════════════════════════════════════════════════════════════
# Context: autocompact-aware meter + quality-budget display
#
# Two numbers:
#   CTX_effective — autocompact-scaled (0% = compaction fires)
#   CTX_budget    — quality budget (0% = past degradation threshold)
#
# 200K models: threshold = total, so CTX_budget == CTX_effective.
# 1M models:   threshold = 350K, so CTX_budget counts against quality zone.
# ═══════════════════════════════════════════════════════════════════

CTX_present=0; CTX_raw=0; CTX_effective=0; CTX_budget=0

ctx_parse() {
  if [ -z "$IN_ctx" ] || [ "$IN_ctx" = "null" ]; then return; fi
  CTX_present=1
  CTX_raw=$(printf '%.0f' "$IN_ctx" 2>/dev/null) || CTX_raw=0
  CTX_effective=$(_ctx_autocompact_scale "$CTX_raw")
  CTX_budget=$(_ctx_quality_budget "$CTX_raw")
}

# Autocompact defaults ON unless explicitly false in settings.json.
_ctx_autocompact_on() {
  [ "$IN_autocompact" != "false" ]
}

# 200K models reserve 15% for compaction; 1M models reserve 17%.
_ctx_compact_buffer() {
  if $MODEL_is_1m; then echo 17; else echo 15; fi
}

# Rescale raw ctx% so compaction boundary reads as 0%.
# effective = (raw - buffer) / (100 - buffer) * 100, clamped [0,100].
_ctx_autocompact_scale() {
  local raw=$1
  _ctx_autocompact_on || { echo "$raw"; return; }

  local buf; buf=$(_ctx_compact_buffer)
  local ci=$(( (raw - buf) * 100 / (100 - buf) ))
  (( ci < 0 ))   && ci=0
  (( ci > 100 )) && ci=100
  echo "$ci"
}

# Quality budget: tokens used vs degradation threshold.
# 200K models: threshold equals total, so budget == effective (familiar number).
# 1M models:   threshold is 350K, budget goes negative past that.
_ctx_quality_budget() {
  local raw=$1
  if ! $MODEL_is_1m; then
    echo "$CTX_effective"
    return
  fi
  local total_K=1000 thresh_K=350
  local used_K=$(( (100 - raw) * total_K / 100 ))
  echo $(( (thresh_K - used_K) * 100 / thresh_K ))
}

# Smooth green→orange→red gradient. Solid green above 50%, ease-in toward
# vivid orange (skips chartreuse/dirty-yellow), then orange→red below 20%.
_ctx_gradient() {
  local pct=$1 r g b t tf
  (( pct > 100 )) && pct=100
  (( pct <   0 )) && pct=0

  if (( pct >= 50 )); then
    r=34; g=197; b=94                       # solid green — no drift
  elif (( pct >= 20 )); then
    t=$(( (50 - pct) * 100 / 30 ))          # 0 at 50, 100 at 20
    tf=$(( t * (200 - t) / 100 ))           # ease-in curve
    r=$(( 34  + 200 * tf / 100 ))           # 34  → 234  green→orange
    g=$(( 197 - 109 * tf / 100 ))           # 197 → 88
    b=$(( 94  -  82 * tf / 100 ))           # 94  → 12
  else
    t=$(( (20 - pct) * 100 / 20 ))          # 0 at 20, 100 at 0
    r=$(( 234 -  15 * t / 100 ))            # 234 → 219  orange→red
    g=$(( 88  -  20 * t / 100 ))            # 88  → 68
    b=$(( 12  +  56 * t / 100 ))            # 12  → 68
  fi
  printf "38;2;%d;%d;%d" "$r" "$g" "$b"
}

# Bright red when autocompact is imminent (effective ≤10), else gradient.
ctx_segment() {
  (( CTX_present )) || return
  if (( CTX_effective <= 10 )); then
    printf "  \033[38;2;239;68;68mctx:%d%%\033[0m" "$CTX_budget"
  else
    printf "  \033[%smctx:%d%%\033[0m" "$(_ctx_gradient "$CTX_budget")" "$CTX_budget"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# Model: tier + 1M + effort, with opus 7d-pacing alerts
#
# Opus eats weekly quota fast, so it gets escalating alerts tied to 7d:
#   amber   = default (opus is always worth watching)
#   red     = overpacing after day 1 (W7_time_left < 6d)
#   red+!!  = 7d is itself red — stop or downmodel
# ═══════════════════════════════════════════════════════════════════

MODEL_name=""; MODEL_tier=""; MODEL_effort=""; MODEL_is_1m=false

model_parse() {
  MODEL_name="$IN_model_name"
  MODEL_tier=$(echo "$MODEL_name" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')
  MODEL_is_1m=false
  if echo "$MODEL_name" | grep -qi "1m\|1 m\|million"; then
    MODEL_is_1m=true
  fi
  case "$IN_effort" in
    low)    MODEL_effort="lo"  ;;
    medium) MODEL_effort="med" ;;
    high)   MODEL_effort="hi"  ;;
    *)      MODEL_effort=""    ;;
  esac
}

_model_color_code() {
  case "$MODEL_tier" in
    opus)
      if   (( W7_score > 15 )); then echo 196
      elif (( W7_score > 0 && W7_time_left < 518400 )); then echo 196
      else echo 214
      fi ;;
    sonnet) echo 75  ;;   # periwinkle
    haiku)  echo 71  ;;   # muted green
    *)      echo 245 ;;   # gray
  esac
}

_model_alert() {
  [[ "$MODEL_tier" == "opus" ]] && (( W7_score > 15 )) && printf "!!"
}

model_segment() {
  [ -z "$MODEL_name" ] && return
  local c; c=$(_model_color_code)
  printf "  \033[38;5;%dm%s%s\033[0m" "$c" "$MODEL_tier" "$(_model_alert)"
  $MODEL_is_1m && printf "\033[38;5;%dm·1m\033[0m" "$c"
  [ -n "$MODEL_effort" ] && printf "\033[${C_DIM}m·%s\033[0m" "$MODEL_effort"
}

# ═══════════════════════════════════════════════════════════════════
# Git: dirty counts + diffstat (only inside a repo)
# ═══════════════════════════════════════════════════════════════════

GIT_present=0; GIT_worktree_linked=0
GIT_modified=0; GIT_untracked=0
GIT_nfiles=0;   GIT_ins=0;  GIT_del=0

git_parse() {
  [ -z "$REPO_root" ] && return
  GIT_present=1
  _git_parse_worktree
  _git_parse_dirty
  _git_parse_diffstat
}

# ⎇ only when in a linked worktree (not the main checkout).
_git_parse_worktree() {
  local main_wt
  main_wt=$(git -C "$IN_cwd" -c gc.auto=0 worktree list --porcelain 2>/dev/null \
    | head -1 | sed 's/^worktree //')
  [ -n "$main_wt" ] && [ "$REPO_root" != "$main_wt" ] && GIT_worktree_linked=1
}

# !N = modified/staged, ?N = untracked (mirrors p10k).
_git_parse_dirty() {
  local status line x y
  status=$(git -C "$IN_cwd" -c gc.auto=0 status --porcelain 2>/dev/null)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    x="${line:0:1}"; y="${line:1:1}"
    if [[ "$x" == "?" ]]; then
      ((GIT_untracked++))
    elif [[ "$x" =~ [MADRC] ]] || [[ "$y" =~ [MD] ]]; then
      ((GIT_modified++))
    fi
  done <<< "$status"
}

# Nf +N -N — how big is the uncommitted changeset vs HEAD?
_git_parse_diffstat() {
  local numstat a d f
  numstat=$(git -C "$IN_cwd" -c gc.auto=0 diff HEAD --numstat 2>/dev/null)
  [ -z "$numstat" ] && return
  while IFS=$'\t' read -r a d f; do
    [ -z "$a" ] && continue
    [[ "$a" == "-" ]] && continue   # skip binary
    ((GIT_nfiles++))
    ((GIT_ins += a))
    ((GIT_del += d))
  done <<< "$numstat"
}

git_segment() {
  (( GIT_present )) || return
  printf "\033[${C_DIM}m%s\033[0m" "$_OCTO"
  (( GIT_worktree_linked )) && printf " \033[${C_DIM}m%s\033[0m" "$_WT"
  (( GIT_modified  > 0 )) && printf " \033[${C_DIM}m!%d\033[0m" "$GIT_modified"
  (( GIT_untracked > 0 )) && printf " \033[${C_DIM}m?%d\033[0m" "$GIT_untracked"
  if (( GIT_nfiles > 0 )); then
    printf "  \033[${C_DIM}m%df\033[0m" "$GIT_nfiles"
    (( GIT_ins > 0 )) && printf " \033[2;${C_GRN}m+%d\033[0m" "$GIT_ins"
    (( GIT_del > 0 )) && printf " \033[2;${C_RED}m-%d\033[0m" "$GIT_del"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# main: parse → compute → render
#
# Claude Code doesn't expose terminal width to statusline commands
# (tput/stty/COLUMNS all fail or return 80), so we just output inline
# and let the terminal wrap naturally.
# ═══════════════════════════════════════════════════════════════════

main() {
  input_parse
  repo_parse
  model_parse       # must precede ctx_parse (MODEL_is_1m) and model_segment
  window7_parse     # must precede window5_parse (inheritance) and model_segment
  window5_parse
  ctx_parse
  git_parse

  local seg_main=""
  seg_main+=$(repo_segment_location)
  seg_main+=$(repo_segment_branch)
  seg_main+=$(traffic_segment)

  if (( W5_present )); then
    seg_main+=$(window_gauge_segment "5h" "$W5_used" "$W5_target" "$W5_score" "$W5_time_left")
  fi
  if (( W7_present )); then
    seg_main+=$(window_gauge_segment "7d" "$W7_used" "$W7_target" "$W7_score" "$W7_time_left")
  fi

  seg_main+=$(ctx_segment)
  seg_main+=$(model_segment)

  printf '%s' "$seg_main"
  if (( GIT_present )); then
    printf '  %s' "$(git_segment)"
  fi
  printf '\n'
}

main
