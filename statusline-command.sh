#!/usr/bin/env bash

input=$(cat)

C_PUR="38;5;99"
C_GRN=32
C_WHT=37
C_YEL=33
C_RED=31
C_DIM=90
C_BRT=97
C_CYN=36

T_RED=0; T_YELLOW=1; T_NEUTRAL=2; T_GREEN=3; T_PURPLE=4

_PAC_R=$'\xf3\xb0\xae\xaf'
_PAC_L=$'\xf3\xb0\xae\xb0'
_GHOST=$'\xf3\xb0\x8a\xa0'
_DOT=$'\xc2\xb7'
_PELLET=$'\xe2\x97\x8f'
_BAR=$'\xe2\x94\x82'
_RESET=$'\xe2\x86\xbb'
_CUP=$'\xf3\xb0\x85\xb6'
_WT=$'\xe2\x8e\x87'
_OCTO=$'\xef\x84\x93'

_pml_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pacman-statusline/config"
if [[ -f "$_pml_cfg" ]]; then
  # shellcheck source=/dev/null
  . "$_pml_cfg"
  if [[ -n "${PAC_L_CODEPOINT:-}" ]]; then
    _cp=$(( PAC_L_CODEPOINT ))
    if (( _cp >= 0x10000 )); then
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

ftime() {
  local s=$1
  if   (( s <= 0 ));    then echo "now"
  elif (( s < 5940 ));  then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 86400 )); then echo "$(( (s + 1800) / 3600 ))h"
  else                       echo "$(( (s + 43200) / 86400 ))d"
  fi
}

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

IN_cwd=""; IN_rl7_used=""; IN_rl7_reset=""
IN_ctx=""; IN_ctx_size=""; IN_model_id=""; IN_model_name=""; IN_effort=""
IN_cache_seen=""; IN_cache_warm=""; IN_cache_ttl=""; IN_cache_expires=""
IN_autocompact=""; IN_now=0

input_parse() {
  IFS=$'\x1f' read -r IN_cwd IN_rl7_used IN_rl7_reset IN_ctx IN_ctx_size \
    IN_model_id IN_model_name IN_effort \
    IN_cache_seen IN_cache_warm IN_cache_ttl IN_cache_expires \
    < <(echo "$input" | jq -r '[
      (.workspace.current_dir // .cwd // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.context_window.remaining_percentage // ""),
      (.context_window.context_window_size // ""),
      (.model.id // ""),
      (.model.display_name // ""),
      (.effort.level // ""),
      (.prompt_cache.caching_observed // ""),
      (.prompt_cache.warm // ""),
      (.prompt_cache.ttl // ""),
      (.prompt_cache.expires_at // "")
    ] | map(tostring) | join("\u001f")' 2>/dev/null)
  IN_autocompact=$(jq -r '.autoCompact // "unset"' "$HOME/.claude/settings.json" 2>/dev/null)
  IN_now=$(date +%s)
}

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

repo_segment_branch() {
  [ -z "$REPO_branch" ] && return
  case "$REPO_branch" in
    main|master) printf " \033[${C_YEL}m%s\033[0m" "$REPO_branch" ;;
    *)           printf " \033[${C_CYN}m%s\033[0m" "$REPO_branch" ;;
  esac
}

W7_used=0; W7_target=0; W7_time_left=0; W7_score=0; W7_present=0

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

window7_parse() {
  if [ -z "$IN_rl7_used" ] || [ "$IN_rl7_used" = "null" ]; then return; fi
  W7_present=1
  W7_used=$(printf '%.0f' "$IN_rl7_used" 2>/dev/null) || W7_used=0
  if [ -z "$IN_rl7_reset" ] || [ "$IN_rl7_reset" = "null" ]; then return; fi
  read -r W7_score W7_target W7_time_left \
    <<< "$(_window_compute "$W7_used" "$IN_rl7_reset" 604800)"
}

PAC7_score=0; PAC7_color=$C_WHT; PAC7_dir=$_PAC_R

_pacman_dir_for_tier() {
  (( $1 <= T_YELLOW )) && echo "$_PAC_L" || echo "$_PAC_R"
}

pacman_parse() {
  local t7
  (( W7_present )) || return
  PAC7_score=$W7_score
  t7=$(tier_of "$W7_score")
  PAC7_color=$(tier_color "$t7")
  PAC7_dir=$(_pacman_dir_for_tier "$t7")
}

gauge_render() {
  local used=$1 target=$2 color=$3 pac=$4 score=$5 width=${6:-10}

  local ppos=$(( used * width / 100 ))
  local tpos=$(( target * width / 100 ))
  (( ppos >= width )) && ppos=$(( width - 1 ))
  (( ppos < 0 ))      && ppos=0
  (( tpos >= width )) && tpos=$(( width - 1 ))
  (( tpos < 0 ))      && tpos=0

  local gpos
  gpos=$(_gauge_ghost_pos "$ppos" "$score" "$width")

  local i
  for (( i=0; i<width; i++ )); do
    _gauge_cell "$i" "$ppos" "$tpos" "$gpos" "$color" "$pac"
  done
}

_gauge_ghost_pos() {
  local ppos=$1 score=$2 width=$3
  local abs=${score#-}
  local gap gpos=-1

  if   (( score < -20 )); then
    gap=$(( 3 - (abs - 20) / 10 ))
    (( gap < 1 )) && gap=1
    gpos=$(( ppos - gap ))
  elif (( score <  -6 )); then
    gap=$(( 4 - (abs -  7) /  7 ))
    (( gap < 3 )) && gap=3
    gpos=$(( ppos - gap ))
  elif (( score >  15 )); then
    gpos=$(( ppos + 1 ))
  elif (( score >   6 )); then
    gap=$(( 3 - (score - 6) / 4 ))
    (( gap < 1 )) && gap=1
    gpos=$(( ppos + gap ))
  fi

  (( gpos < 0 || gpos >= width )) && gpos=-1
  echo "$gpos"
}

_gauge_cell() {
  local i=$1 ppos=$2 tpos=$3 gpos=$4 c=$5 pac=$6
  if   (( i == ppos )); then
    printf "\033[${c}m%s\033[0m" "$pac"
  elif (( gpos >= 0 && i == gpos )); then
    printf "\033[${c}m%s\033[0m" "$_GHOST"
  elif (( i == tpos && ppos <= tpos )); then
    printf "\033[${c}m%s\033[0m" "$_PELLET"
  elif (( i < ppos )); then
    printf " "
  elif (( i > ppos && i < tpos )); then
    printf "\033[${c}m%s\033[0m" "$_DOT"
  else
    printf "\033[${C_DIM}m%s\033[0m" "$_DOT"
  fi
}

_gauge_timer_edible() {
  local used=$1 target=$2 w=10
  local pp=$(( used * w / 100 ))
  local tp=$(( target * w / 100 ))
  (( pp > w-1 )) && pp=$(( w-1 ))
  (( tp > w-1 )) && tp=$(( w-1 ))
  (( pp == w-1 )) || (( tp == w-1 && pp <= tp ))
}

window_gauge_segment() {
  local label=$1 used=$2 target=$3 time_left=$4
  local pac_color=$5 pac_dir=$6 pac_score=$7
  local tc

  printf "  \033[${C_DIM}m%s%s\033[0m" "$label" "$_BAR"
  gauge_render "$used" "$target" "$pac_color" "$pac_dir" "$pac_score"

  (( time_left <= 0 )) && return
  if _gauge_timer_edible "$used" "$target"; then tc=$C_WHT; else tc=$C_DIM; fi
  printf "\033[${tc}m%s%s\033[0m" "$(ftime $time_left)" "$_RESET"
}

CTX_present=0; CTX_raw=0; CTX_effective=0; CTX_budget=0

ctx_parse() {
  if [ -z "$IN_ctx" ] || [ "$IN_ctx" = "null" ]; then return; fi
  CTX_present=1
  CTX_raw=$(printf '%.0f' "$IN_ctx" 2>/dev/null) || CTX_raw=0
  CTX_effective=$(_ctx_autocompact_scale "$CTX_raw")
  CTX_budget=$(_ctx_quality_budget "$CTX_raw")
}

_ctx_autocompact_on() {
  [ "$IN_autocompact" != "false" ]
}

_ctx_compact_buffer() {
  if $MODEL_is_1m; then echo 17; else echo 15; fi
}

_ctx_autocompact_scale() {
  local raw=$1
  _ctx_autocompact_on || { echo "$raw"; return; }

  local buf; buf=$(_ctx_compact_buffer)
  local ci=$(( (raw - buf) * 100 / (100 - buf) ))
  (( ci < 0 ))   && ci=0
  (( ci > 100 )) && ci=100
  echo "$ci"
}

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

_ctx_gradient() {
  local pct=$1 r g b t tf
  (( pct > 100 )) && pct=100
  (( pct <   0 )) && pct=0

  if (( pct >= 50 )); then
    r=34; g=197; b=94
  elif (( pct >= 20 )); then
    t=$(( (50 - pct) * 100 / 30 ))
    tf=$(( t * (200 - t) / 100 ))
    r=$(( 34  + 200 * tf / 100 ))
    g=$(( 197 - 109 * tf / 100 ))
    b=$(( 94  -  82 * tf / 100 ))
  else
    t=$(( (20 - pct) * 100 / 20 ))
    r=$(( 234 -  15 * t / 100 ))
    g=$(( 88  -  20 * t / 100 ))
    b=$(( 12  +  56 * t / 100 ))
  fi
  printf "38;2;%d;%d;%d" "$r" "$g" "$b"
}

ctx_segment() {
  (( CTX_present )) || return
  if (( CTX_effective <= 10 )); then
    printf "  \033[38;2;239;68;68mctx:%d%%\033[0m" "$CTX_budget"
  else
    printf "  \033[%smctx:%d%%\033[0m" "$(_ctx_gradient "$CTX_budget")" "$CTX_budget"
  fi
}

CACHE_present=0; CACHE_warm=0; CACHE_left=0
CACHE_T_amber=1800; CACHE_T_blue=600; CACHE_T_block=300; CACHE_T_bang=120

cache_parse() {
  [ "$IN_cache_seen" = "true" ] || return
  CACHE_present=1
  [ "$IN_cache_warm" = "true" ] || return
  [[ "$IN_cache_expires" =~ ^[0-9]+$ ]] || return
  CACHE_left=$(( IN_cache_expires - IN_now ))
  (( CACHE_left > 0 )) && CACHE_warm=1
  if [ "$IN_cache_ttl" = "5m" ]; then
    CACHE_T_amber=180; CACHE_T_blue=120; CACHE_T_block=60; CACHE_T_bang=30
  fi
}

cache_segment() {
  (( CACHE_present )) || return
  if (( ! CACHE_warm )); then
    printf "  \033[${C_DIM}m%s\033[0m" "$_CUP"
    return
  fi
  local mins=$(( CACHE_left / 60 ))
  if   (( CACHE_left < CACHE_T_bang )); then
    printf "  \033[1;97;48;5;27m %s \033[0m\033[${C_RED}m!!\033[0m \033[1;${C_RED}m%dm\033[0m" "$_CUP" "$mins"
  elif (( CACHE_left <= CACHE_T_block )); then
    printf "  \033[1;97;48;5;27m %s \033[0m \033[1;${C_BRT}m%dm\033[0m" "$_CUP" "$mins"
  elif (( CACHE_left <= CACHE_T_blue )); then
    printf "  \033[1;38;5;39m%s\033[0m \033[1;${C_BRT}m%dm\033[0m" "$_CUP" "$mins"
  elif (( CACHE_left <= CACHE_T_amber )); then
    printf "  \033[38;5;178m%s\033[0m \033[${C_DIM}m%dm\033[0m" "$_CUP" "$mins"
  else
    printf "  \033[38;5;136m%s\033[0m \033[${C_DIM}m%dm\033[0m" "$_CUP" "$mins"
  fi
}

MODEL_name=""; MODEL_tier=""; MODEL_effort=""; MODEL_is_1m=false

model_parse() {
  MODEL_name="$IN_model_name"
  local key; key=$(printf '%s %s' "$IN_model_id" "$IN_model_name" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    *fable*)  MODEL_tier=fable  ;;
    *opus*)   MODEL_tier=opus   ;;
    *sonnet*) MODEL_tier=sonnet ;;
    *haiku*)  MODEL_tier=haiku  ;;
    *)        MODEL_tier=$(echo "$key" | awk '{print $1}') ;;
  esac
  MODEL_is_1m=false
  [[ "$IN_ctx_size" =~ ^[0-9]+$ ]] && (( IN_ctx_size >= 1000000 )) && MODEL_is_1m=true
  case "$IN_effort" in
    low)    MODEL_effort="lo"  ;;
    medium) MODEL_effort="med" ;;
    high)   MODEL_effort="hi"  ;;
    xhigh)  MODEL_effort="xhi" ;;
    max)    MODEL_effort="max" ;;
    *)      MODEL_effort="${IN_effort:0:3}" ;;
  esac
}

_model_color_code() {
  (( W7_score > 15 )) && { echo 196; return; }
  case "$MODEL_tier" in
    fable)  echo 177 ;;
    opus)   echo 214 ;;
    sonnet) echo 75  ;;
    haiku)  echo 71  ;;
    *)      echo 245 ;;
  esac
}

_model_alert() {
  (( W7_score > 15 )) && printf "!!"
}

model_segment() {
  [ -z "$MODEL_name" ] && return
  local c; c=$(_model_color_code)
  printf "  \033[38;5;%dm%s%s\033[0m" "$c" "$MODEL_tier" "$(_model_alert)"
  $MODEL_is_1m && printf "\033[38;5;%dm·1m\033[0m" "$c"
  [ -n "$MODEL_effort" ] && printf "\033[${C_DIM}m·%s\033[0m" "$MODEL_effort"
}

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

_git_parse_worktree() {
  local main_wt
  main_wt=$(git -C "$IN_cwd" -c gc.auto=0 worktree list --porcelain 2>/dev/null \
    | head -1 | sed 's/^worktree //')
  [ -n "$main_wt" ] && [ "$REPO_root" != "$main_wt" ] && GIT_worktree_linked=1
}

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

_git_parse_diffstat() {
  local numstat a d f
  numstat=$(git -C "$IN_cwd" -c gc.auto=0 diff HEAD --numstat 2>/dev/null)
  [ -z "$numstat" ] && return
  while IFS=$'\t' read -r a d f; do
    [ -z "$a" ] && continue
    [[ "$a" == "-" ]] && continue
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

main() {
  input_parse
  repo_parse
  model_parse
  window7_parse
  pacman_parse
  ctx_parse
  cache_parse
  git_parse

  local seg_main=""
  seg_main+=$(repo_segment_location)
  seg_main+=$(repo_segment_branch)

  if (( W7_present )); then
    seg_main+=$(window_gauge_segment "7d" "$W7_used" "$W7_target" "$W7_time_left" \
      "$PAC7_color" "$PAC7_dir" "$PAC7_score")
  fi

  seg_main+=$(ctx_segment)
  seg_main+=$(cache_segment)
  seg_main+=$(model_segment)

  printf '%s' "$seg_main"
  if (( GIT_present )); then
    printf '  %s' "$(git_segment)"
  fi
  printf '\n'
}

main
