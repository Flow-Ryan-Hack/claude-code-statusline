#!/usr/bin/env bash
#
# claude-statusline — a Claude Code status line built around two questions:
#   1. How expensive is this conversation getting?
#   2. How much of my rate limit is left?
#
# Line 1  model · effort · location
# Line 2  context bar · absolute tokens / window · what to do about it
# Line 3  the three thresholds, coloured by where you stand
# Line 4  what the context is made of (optional, off by default)
# Line 5  weekly limit · 5h limit · session cost
# Line 6  machine load: load/cores · free RAM · swap · headless browsers ·
#         running claude sessions (macOS, optional, off by default)
#
# Thresholds are absolute token counts, not percentages, because cost scales
# with absolute tokens: 150K tokens cost the same whether the window is 200K
# or 1M. On a small window each threshold is additionally capped at a share of
# that window, so "very expensive" still fires before the window runs out.
#
# Configure by copying statusline.conf.example to ~/.claude/statusline.conf.
# Requires: bash 3.2+ (the version macOS ships), jq.

CONFIG="${CLAUDE_STATUSLINE_CONFIG:-$HOME/.claude/statusline.conf}"

# --- Colours (available to the config file) ---
R=$'\e[0m'; DIM=$'\e[2m'; B=$'\e[1m'
GREEN=$'\e[32m'; YELLOW=$'\e[33m'; ORANGE=$'\e[38;5;208m'; RED=$'\e[31m'
BLUE=$'\e[34m'; MAG=$'\e[35m'; CYAN=$'\e[36m'

# BLUE, MAG and CYAN are never used in this file. They exist for the config
# file, which is sourced further down and documented as being able to colour
# dir_label with them. The null command marks them as read so a linter does not
# report them as dead.
: "$BLUE" "$MAG" "$CYAN"

# ---------------------------------------------------------------------------
# Defaults — override any of these in the config file
# ---------------------------------------------------------------------------

# Context thresholds: absolute tokens, each capped at a percentage of the
# model's context window so small-window models degrade sensibly.
THRESHOLD_1=100000;  THRESHOLD_1_PCT=50
THRESHOLD_2=200000;  THRESHOLD_2_PCT=75
THRESHOLD_3=400000;  THRESHOLD_3_PCT=90

BAR_WIDTH=20          # characters in the context bar
BAR_MAX_ABS=400000    # bar is full here, or at the window size if smaller
BAR_FULL="█"
BAR_EMPTY="░"

# Line 2 hints, one per band. /compact keeps the thread as a summary and is
# the cheaper first move; /clear is for when the topic is genuinely finished.
HINT_1="optimal · nothing to do"
HINT_2="ok · /compact on topic switch"
HINT_3="expensive · /compact now"
HINT_4="very expensive · /compact, or /clear if done"

# Line 3 action labels, one per threshold.
ACTION_1="keep going"
ACTION_2="/compact on switch"
ACTION_3="/compact or /clear"

SHOW_THRESHOLD_LINE=1   # line 3: threshold scale
SHOW_BREAKDOWN_LINE=0   # line 4: what the context is made of
SHOW_LIMIT_LINE=1       # line 5: rate limits and session cost
SHOW_CHURN=1            # append +added/-removed lines to the breakdown
CACHE_WARN=90           # cache hit % below this turns yellow
CACHE_CRIT=50           # ... and red
WEEK_WARN=60            # weekly usage % that turns the figure yellow
WEEK_CRIT=85            # ... and red

LABEL_WEEK="week"
LABEL_5H="5h"
LABEL_SESSION="session"

# Line 6: how hard the machine is working. Many parallel sessions are cheap on
# their own; what they launch (headless browsers, builds, sub-agents) is not.
# macOS only. Costs two pgrep calls per render, hence off by default.
SHOW_MACHINE_LINE=0
LOAD_WARN_X=1           # load above cores × this turns yellow
LOAD_CRIT_X=2           # ... and red
MEM_WARN=40             # free memory % below this turns yellow
MEM_CRIT=20             # ... and red
HEADLESS_WARN=1         # headless browser processes from here: yellow
HEADLESS_CRIT=7         # ... and red
SESSIONS_WARN=5         # running claude sessions from here: yellow
LABEL_LOAD="load"
LABEL_MEM="ram free"
LABEL_SWAP="swap"
LABEL_HEADLESS="headless"
LABEL_SESSIONS="sessions"

# Location label for line 1. Override in the config file to map your own
# directories to names and colours. $1 is the absolute working directory.
dir_label() {
  case "$1" in
    "$HOME") printf '%s' "${DIM}~${R}" ;;
    *)       printf '%s' "${DIM}${1##*/}${R}" ;;
  esac
}

# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

# ---------------------------------------------------------------------------

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '%sclaude-statusline: jq not found%s' "$RED" "$R"
  exit 0
fi

j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

MODEL=$(j '.model.display_name // "?"')
EFFORT=$(j '.effort.level // empty')
DIR=$(j '.workspace.current_dir // .cwd // ""')
IN=$(j '.context_window.total_input_tokens // 0')
OUT=$(j '.context_window.total_output_tokens // 0')
WIN=$(j '.context_window.context_window_size // 200000')
COST=$(j '.cost.total_cost_usd // 0')
CU_NEW=$(j '.context_window.current_usage.input_tokens // 0')
CU_WRITE=$(j '.context_window.current_usage.cache_creation_input_tokens // 0')
CU_READ=$(j '.context_window.current_usage.cache_read_input_tokens // 0')
ADDED=$(j '.cost.total_lines_added // 0')
REMOVED=$(j '.cost.total_lines_removed // 0')
H5=$(j '.rate_limits.five_hour.used_percentage // empty')
D7=$(j '.rate_limits.seven_day.used_percentage // empty')
D7R=$(j '.rate_limits.seven_day.resets_at // empty')

CTX=$(( ${IN:-0} + ${OUT:-0} ))

# A missing or zero window would divide by zero below.
case "$WIN" in ''|*[!0-9]*) WIN=200000 ;; esac
[ "$WIN" -le 0 ] && WIN=200000

min() { [ "$1" -lt "$2" ] && printf '%d' "$1" || printf '%d' "$2"; }

T1=$(min "$THRESHOLD_1" $(( WIN * THRESHOLD_1_PCT / 100 )))
T2=$(min "$THRESHOLD_2" $(( WIN * THRESHOLD_2_PCT / 100 )))
T3=$(min "$THRESHOLD_3" $(( WIN * THRESHOLD_3_PCT / 100 )))
BAR_MAX=$(min "$BAR_MAX_ABS" "$WIN")

# --- Context band: colour + hint ---
if   [ "$CTX" -lt "$T1" ]; then C=$GREEN;  HINT=" ${DIM}· ${HINT_1}${R}"
elif [ "$CTX" -lt "$T2" ]; then C=$YELLOW; HINT=" ${DIM}· ${HINT_2}${R}"
elif [ "$CTX" -lt "$T3" ]; then C=$ORANGE; HINT=" ${ORANGE}· ${HINT_3}${R}"
else                            C=$RED;    HINT=" ${B}${RED}· ${HINT_4}${R}"
fi

# --- Bar ---
FILL=$(( CTX * BAR_WIDTH / BAR_MAX ))
[ "$FILL" -gt "$BAR_WIDTH" ] && FILL=$BAR_WIDTH
[ "$FILL" -lt 0 ] && FILL=0
BAR=""
for ((i=0;i<BAR_WIDTH;i++)); do
  if [ "$i" -lt "$FILL" ]; then BAR="${BAR}${BAR_FULL}"; else BAR="${BAR}${BAR_EMPTY}"; fi
done

fmt() { # 123456 -> 123K
  local n=$1
  if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
  elif [ "$n" -ge 1000 ];    then printf '%dK' $((n/1000))
  else printf '%d' "$n"; fi
}

# --- Line 1: model, effort, location ---
L1="${DIM}${MODEL}${R}"
[ -n "$EFFORT" ] && L1="${L1} ${DIM}·${R} ${DIM}effort:${R}${EFFORT}"
L1="${L1} ${DIM}·${R} $(dir_label "$DIR")"

# --- Line 2: context ---
L2="${C}${BAR}${R} ${C}$(fmt "$CTX")${R}${DIM}/$(fmt "$WIN")${R}${HINT}"

# --- Line 3: threshold scale ---
# below it -> dimmed green · inside its band -> yellow · past it -> red
thr() { # $1 threshold  $2 upper bound (0 = none)  $3 action label
  local t=$1 up=$2 lbl=$3 col
  if   [ "$CTX" -lt "$t" ];                     then col="${DIM}${GREEN}"
  elif [ "$up" -ne 0 ] && [ "$CTX" -lt "$up" ]; then col="${YELLOW}"
  else                                               col="${RED}"
  fi
  printf '%s%s %s%s' "$col" "$(fmt "$t")" "$lbl" "$R"
}
L3=""
if [ "$SHOW_THRESHOLD_LINE" -eq 1 ]; then
  L3="$(thr "$T1" "$T2" "$ACTION_1") ${DIM}·${R} $(thr "$T2" "$T3" "$ACTION_2") ${DIM}·${R} $(thr "$T3" 0 "$ACTION_3")"
fi

# --- Line 4: what the context is made of ---
# These describe the context window as it stands right now, not cumulative
# session totals — the status line payload only reports the current window.
L4=""
if [ "$SHOW_BREAKDOWN_LINE" -eq 1 ]; then
  TOTAL_IN=$(( CU_NEW + CU_WRITE + CU_READ ))
  if [ "$TOTAL_IN" -gt 0 ]; then
    HIT=$(( CU_READ * 100 / TOTAL_IN ))
    if   [ "$HIT" -lt "$CACHE_CRIT" ]; then HC=$RED
    elif [ "$HIT" -lt "$CACHE_WARN" ]; then HC=$YELLOW
    else HC=$GREEN; fi
    L4="${DIM}cached${R} ${HC}${HIT}%${R}"
    L4="${L4} ${DIM}·${R} ${DIM}read${R} $(fmt "$CU_READ")"
    L4="${L4} ${DIM}·${R} ${DIM}write${R} $(fmt "$CU_WRITE")"
    L4="${L4} ${DIM}·${R} ${DIM}fresh${R} $(fmt "$CU_NEW")"
    L4="${L4} ${DIM}·${R} ${DIM}out${R} $(fmt "${OUT:-0}")"
    if [ "$SHOW_CHURN" -eq 1 ] && [ $(( ADDED + REMOVED )) -gt 0 ]; then
      L4="${L4} ${DIM}·${R} ${GREEN}+${ADDED}${R}${DIM}/${R}${RED}-${REMOVED}${R}"
    fi
  fi
fi

# --- Line 5: limits + cost ---
L5=""
if [ "$SHOW_LIMIT_LINE" -eq 1 ]; then
  if [ -n "$D7" ]; then
    D7I=${D7%.*}
    if   [ "${D7I:-0}" -ge "$WEEK_CRIT" ]; then WC=$RED
    elif [ "${D7I:-0}" -ge "$WEEK_WARN" ]; then WC=$YELLOW
    else WC=$GREEN; fi
    L5="${DIM}${LABEL_WEEK}${R} ${WC}${D7I}%${R}"
    if [ -n "$D7R" ]; then
      LEFT=$(( (D7R - $(date +%s)) / 3600 ))
      [ "$LEFT" -gt 0 ] && L5="${L5}${DIM} (${LEFT}h left)${R}"
    fi
  fi
  if [ -n "$H5" ]; then
    H5I=${H5%.*}
    [ -n "$L5" ] && L5="${L5} ${DIM}·${R} "
    L5="${L5}${DIM}${LABEL_5H}${R} ${H5I}%"
  fi
  if [ -n "$COST" ] && [ "$COST" != "0" ]; then
    [ -n "$L5" ] && L5="${L5} ${DIM}·${R} "
    L5="${L5}${DIM}${LABEL_SESSION}${R} \$$(printf '%.2f' "$COST")"
  fi
fi

# --- Line 6: machine load (macOS) ---
L6=""
if [ "$SHOW_MACHINE_LINE" -eq 1 ] && [ "$(uname)" = "Darwin" ]; then
  CORES=$(sysctl -n hw.ncpu)
  LOAD=$(sysctl -n vm.loadavg | awk '{printf "%d", $2}')
  MEMFREE=$(sysctl -n kern.memorystatus_level)
  SWAP=$(sysctl -n vm.swapusage | awk '{gsub("M","",$6); printf "%.1f", $6/1024}')
  HEADLESS=$(pgrep -f -- '--headless' | wc -l | tr -d ' ')
  SESSIONS=$(pgrep -x claude | wc -l | tr -d ' ')

  if   [ "$LOAD" -gt $(( CORES * LOAD_CRIT_X )) ]; then LC=$RED
  elif [ "$LOAD" -gt $(( CORES * LOAD_WARN_X )) ]; then LC=$YELLOW
  else LC=$GREEN; fi
  if   [ "$MEMFREE" -lt "$MEM_CRIT" ]; then MC=$RED
  elif [ "$MEMFREE" -lt "$MEM_WARN" ]; then MC=$YELLOW
  else MC=$GREEN; fi
  if   [ "$HEADLESS" -ge "$HEADLESS_CRIT" ]; then HC=$RED
  elif [ "$HEADLESS" -ge "$HEADLESS_WARN" ]; then HC=$YELLOW
  else HC=$DIM; fi
  if [ "$SESSIONS" -ge "$SESSIONS_WARN" ]; then SC=$YELLOW; else SC=$DIM; fi

  L6="${DIM}${LABEL_LOAD}${R} ${LC}${LOAD}${R}${DIM}/${CORES}${R}"
  L6="${L6} ${DIM}·${R} ${DIM}${LABEL_MEM}${R} ${MC}${MEMFREE}%${R}"
  L6="${L6} ${DIM}·${R} ${DIM}${LABEL_SWAP}${R} ${SWAP}G"
  L6="${L6} ${DIM}·${R} ${DIM}${LABEL_HEADLESS}${R} ${HC}${HEADLESS}${R}"
  L6="${L6} ${DIM}·${R} ${DIM}${LABEL_SESSIONS}${R} ${SC}${SESSIONS}${R}"
fi

OUTPUT="$L1"$'\n'"$L2"
[ -n "$L3" ] && OUTPUT="${OUTPUT}"$'\n'"$L3"
[ -n "$L4" ] && OUTPUT="${OUTPUT}"$'\n'"$L4"
[ -n "$L5" ] && OUTPUT="${OUTPUT}"$'\n'"$L5"
[ -n "$L6" ] && OUTPUT="${OUTPUT}"$'\n'"$L6"
printf '%s' "$OUTPUT"
