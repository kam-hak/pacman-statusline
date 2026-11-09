#!/usr/bin/env bash

SL="$(cd "$(dirname "$0")/.." && pwd)/statusline-command.sh"

fix() {
  local u7=$1 tl7=$2 ctx=${3:-47} model=${4:-sonnet} cwd=${5:-/Users/kamran} cl=${6:-none} ttl=${7:-1h}
  local now; now=$(date +%s)
  local size=200000 id name
  [[ "$model" == *-1m ]] && { size=1000000; model=${model%-1m}; }
  case "$model" in
    unknown) id=""; name="Claude Pro" ;;
    *)       id="claude-${model}-5-5"; name="$(tr '[:lower:]' '[:upper:]' <<< "${model:0:1}")${model:1}" ;;
  esac
  local cache=""
  if [ "$cl" != none ]; then
    local warm=true; (( cl <= 0 )) && warm=false
    cache=$(printf ',"prompt_cache":{"caching_observed":true,"warm":%s,"ttl":"%s","expires_at":%s}' \
      "$warm" "$ttl" $(( now + cl )))
  fi
  printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"seven_day":{"used_percentage":%s,"resets_at":%s}},"context_window":{"remaining_percentage":%s,"context_window_size":%s},"model":{"id":"%s","display_name":"%s"},"effort":{"level":"high"}%s}' \
    "$cwd" "$u7" $(( now + tl7 )) "$ctx" "$size" "$id" "$name" "$cache"
}

row() {
  local label=$1; shift
  printf '%-40s' "$label"
  fix "$@" | bash "$SL"
}

hdr() { printf '\n\033[1;97m── %s ──\033[0m\n' "$1"; }

D=604800
HALF7=$((D/2))

hdr "7d tier sweep (mid-window)"
for u in 15 38 50 62 85; do
  row "7d used=${u}%" $u $HALF7
done

hdr "Overspend (pac past pellet)"
row "7d mild overspend (yellow)"  60 $HALF7
row "7d overspend red"            78 $HALF7
row "7d severe overspend red"     92 $HALF7
row "7d overspend late window"    95 120960

hdr "Ghost position sweep"
LATE7=$((D*30/100))
row "purple behind (late, u=45)"   45 $LATE7
row "green behind (late, u=55)"    55 $LATE7
row "neutral (no ghost, u=65)"     65 $LATE7
row "yellow ahead (early, u=75)"   75 $((D*40/100))
row "red ahead (mid, u=85)"        85 $HALF7
row "ghost hidden (deep purple)"   20 $HALF7

hdr "Context gradient (gauge held neutral)"
for c in 100 80 60 50 45 40 35 30 25 20 15 10 5 0; do
  row "ctx=${c}%"  50 $HALF7 $c
done

hdr "Model variants (gauge held neutral)"
row "fable"              50 $HALF7 47 fable
row "fable 1M"           50 $HALF7 47 fable-1m
row "opus"               50 $HALF7 47 opus
row "sonnet"             50 $HALF7 47 sonnet
row "sonnet 1M"          50 $HALF7 47 sonnet-1m
row "haiku"              50 $HALF7 47 haiku
row "unknown model"      50 $HALF7 47 unknown
row "any model, 7d red → !!" 90 $HALF7 47 sonnet

hdr "1M context (quality-budget display)"
row "1M ctx=80% (deep plenty)"  50 $HALF7 80 sonnet-1m
row "1M ctx=65% (at 350K)"      50 $HALF7 65 sonnet-1m
row "1M ctx=50% (over budget)"  50 $HALF7 50 sonnet-1m
row "1M ctx=30% (deep zone)"    50 $HALF7 30 sonnet-1m

hdr "Prompt cache (1h TTL; minutes floored, last minute reads 0m)"
for l in 3590 2400 1500 700 599 301 299 121 119 61 59 5 0; do
  row "cache left=${l}s" 50 $HALF7 47 sonnet /Users/kamran $l 1h
done

hdr "Prompt cache (5m TTL)"
for l in 250 150 119 59 29 0; do
  row "cache left=${l}s" 50 $HALF7 47 sonnet /Users/kamran $l 5m
done

hdr "Final-window sprint"
row "sprint: 7d=2h left, 40% weekly" 40 7200
row "sprint: 7d=1h left, 50% weekly" 50 3600
row "sprint: 7d=30m, 20% weekly"     20 1800
row "sprint skipped (weekly <7%)"    95 3600

hdr "Git segment (inside a repo)"
row "clean repo"         50 $HALF7 47 opus /Users/kamran/.klh_agents
row "repo deep path"     50 $HALF7 47 opus /Users/kamran/.klh_agents/rules
row "repo at ~/.claude"  50 $HALF7 47 opus /Users/kamran/.claude

hdr "Edge: timer edibility (pellet/pac at last cell)"
row "pellet at cell 9 (t=100)"    69 3600
row "pac at cell 9 (u=98)"        98 $HALF7
row "pac at cell 9 (u=100)"       100 $HALF7

hdr "Degenerate inputs"
printf '%-40s' "no rate_limits"
printf '{"workspace":{"current_dir":"/Users/kamran"},"context_window":{"remaining_percentage":47},"model":{"id":"claude-opus-5-5","display_name":"Opus"}}' | bash "$SL"
printf '%-40s' "legacy 5h-only rate_limits (ignored)"
printf '{"workspace":{"current_dir":"/Users/kamran"},"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":%s}},"model":{"id":"claude-opus-5-5","display_name":"Opus"}}' $(( $(date +%s) + 9000 )) | bash "$SL"
printf '%-40s' "no context"
printf '{"workspace":{"current_dir":"/Users/kamran"},"model":{"id":"claude-opus-5-5","display_name":"Opus"}}' | bash "$SL"
printf '%-40s' "no model"
printf '{"workspace":{"current_dir":"/Users/kamran"}}' | bash "$SL"
printf '%-40s' "cache seen but expires_at null"
printf '{"workspace":{"current_dir":"/Users/kamran"},"prompt_cache":{"caching_observed":true,"warm":false,"ttl":"1h","expires_at":null}}' | bash "$SL"
printf '%-40s' "completely empty"
printf '{}' | bash "$SL"
