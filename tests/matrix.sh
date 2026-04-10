#!/usr/bin/env bash
# Combinatorial render matrix for statusline-command.sh
# Synthesizes JSON fixtures and pipes each through the statusline.

SL="$(cd "$(dirname "$0")/.." && pwd)/statusline-command.sh"

# Build a fixture JSON.
# args: u5 tl5 u7 tl7 [ctx=47] [model="Opus 4.6"] [cwd=/Users/kamran]
fix() {
  local u5=$1 tl5=$2 u7=$3 tl7=$4 ctx=${5:-47} model=${6:-"Opus 4.6"} cwd=${7:-/Users/kamran}
  local now; now=$(date +%s)
  local r5=$(( now + tl5 ))
  local r7=$(( now + tl7 ))
  printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}},"context_window":{"remaining_percentage":%s},"model":{"display_name":"%s"}}' \
    "$cwd" "$u5" "$r5" "$u7" "$r7" "$ctx" "$model"
}

row() {
  local label=$1; shift
  printf '%-40s' "$label"
  fix "$@" | bash "$SL"
}

hdr() { printf '\n\033[1;97m── %s ──\033[0m\n' "$1"; }

H=18000       # 5h window
D=604800      # 7d window
HALF5=$((H/2))
HALF7=$((D/2))

# ═══════════════════════════════════════════════════════════
# Tier math at midwindow (tl_pct=50, target=50):
#   amp = 0.5 + 1.5*0.25 = 0.875, so score ≈ (used-50)*0.875
#   purple: used≤27    green: used≤43   neutral: used≤57
#   yellow: used≤68    red:   used>68
# ═══════════════════════════════════════════════════════════

hdr "5h × 7d tier matrix (mid-window — shows adjustment effects)"
USES=(15 38 50 62 85)
NAMES=("purple " "green  " "neutral" "yellow " "red    ")
printf '                                       %s\n' "(5h input intent → actual render)"
for i in 0 1 2 3 4; do
  for j in 0 1 2 3 4; do
    row "5h=${NAMES[$i]} 7d=${NAMES[$j]}" ${USES[$i]} $HALF5 ${USES[$j]} $HALF7
  done
done

hdr "Overspend (pac past pellet) — raw 7d gauge"
# Target positions change with time-left. Using 7d since 5h is auto-adjusted.
row "7d mild overspend (yellow)"  50 $HALF5 60 $HALF7
row "7d overspend red"            50 $HALF5 78 $HALF7
row "7d severe overspend red"     50 $HALF5 92 $HALF7
row "7d overspend late window"    50 $HALF5 95 120960   # 80% elapsed

hdr "Ghost position sweep (7d gauge)"
# Late window (70% elapsed) → pac further right, ghost behind visible
LATE7=$((D*30/100))   # 30% time left
row "purple behind (late, u=45)"   50 $HALF5 45 $LATE7
row "green behind (late, u=55)"    50 $HALF5 55 $LATE7
row "neutral (no ghost, u=65)"     50 $HALF5 65 $LATE7
row "yellow ahead (early, u=75)"   50 $HALF5 75 $((D*40/100))
row "red ahead (mid, u=85)"        50 $HALF5 85 $HALF7
row "ghost hidden (deep purple)"   50 $HALF5 20 $HALF7

hdr "Context gradient (gauges held neutral)"
for c in 100 80 60 50 45 40 35 30 25 20 15 10 5 0; do
  row "ctx=${c}%"  50 $HALF5 50 $HALF7 $c
done

hdr "Model variants (gauges held neutral)"
row "sonnet"             50 $HALF5 50 $HALF7 47 "Sonnet 4.6"
row "sonnet 1M"          50 $HALF5 50 $HALF7 47 "Sonnet 4.6 (1M)"
row "haiku"              50 $HALF5 50 $HALF7 47 "Haiku 4.5"
row "opus amber default" 50 $HALF5 50 $HALF7 47 "Opus 4.6"
row "opus red day-1"     50 $HALF5 62 259200 47 "Opus 4.6"   # 3d left, over target
row "opus red + !!"      50 $HALF5 90 $HALF7 47 "Opus 4.6"   # 7d red
row "unknown model"      50 $HALF5 50 $HALF7 47 "Claude Pro"

hdr "1M context (quality-budget display)"
row "1M ctx=80% (deep plenty)"  50 $HALF5 50 $HALF7 80 "Sonnet 4.6 (1M)"
row "1M ctx=65% (at 350K)"      50 $HALF5 50 $HALF7 65 "Sonnet 4.6 (1M)"
row "1M ctx=50% (over budget)"  50 $HALF5 50 $HALF7 50 "Sonnet 4.6 (1M)"
row "1M ctx=30% (deep zone)"    50 $HALF5 50 $HALF7 30 "Sonnet 4.6 (1M)"

hdr "Final-window sprint (7d resets inside 5h)"
row "sprint: 7d=2h left, 60% weekly" 30 $HALF5 40 7200
row "sprint: 7d=1h left, 50% weekly" 20 $HALF5 50 3600
row "sprint: 7d=30m, 80% weekly"     10 $HALF5 20 1800
row "sprint skipped (weekly <7%)"    50 $HALF5 95 3600

hdr "Git segment (inside a repo)"
row "clean repo"         50 $HALF5 50 $HALF7 47 "Opus 4.6" /Users/kamran/.klh_agents
row "repo deep path"     50 $HALF5 50 $HALF7 47 "Opus 4.6" /Users/kamran/.klh_agents/rules
row "repo at ~/.claude"  50 $HALF5 50 $HALF7 47 "Opus 4.6" /Users/kamran/.claude

hdr "Edge: timer edibility (pellet/pac at last cell)"
row "pellet at cell 9 (t=100)"    50 $HALF5 69 3600    # target forced high → pellet at end
row "pac at cell 9 (u=98)"        50 $HALF5 98 $HALF7
row "pac at cell 9 (u=100)"       50 $HALF5 100 $HALF7

hdr "Degenerate inputs"
printf '%-40s' "empty rate_limits"
printf '{"workspace":{"current_dir":"/Users/kamran"},"context_window":{"remaining_percentage":47},"model":{"display_name":"Opus 4.6"}}' | bash "$SL"
printf '%-40s' "no context"
printf '{"workspace":{"current_dir":"/Users/kamran"},"model":{"display_name":"Opus 4.6"}}' | bash "$SL"
printf '%-40s' "no model"
printf '{"workspace":{"current_dir":"/Users/kamran"}}' | bash "$SL"
printf '%-40s' "completely empty"
printf '{}' | bash "$SL"
