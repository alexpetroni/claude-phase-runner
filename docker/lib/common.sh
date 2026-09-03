# shellcheck shell=bash
# Shared helpers for the phase driver. Sourced by driver.sh, never executed.
#
# Expects these globals from the driver: PROJECT_DIR STATE LOGS REVIEWS
# DONE_FILE RUNS_FILE BLOCKED_FILE GIT_BRANCH.

# bash 5.2 treats `&` in ${var//pat/rep} replacements specially; prompts
# contain `&&` (gate commands), so make replacements literal again.
shopt -u patsub_replacement 2>/dev/null || true

RUNNER_HOME="${PHASE_RUNNER_HOME:-/opt/phase-runner}"
PROMPTS_DIR="$RUNNER_HOME/prompts"
LIB_DIR="$RUNNER_HOME/docker/lib"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*" >&2; }
die()  {
  printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2
  write_summary "FAILED" "$*"
  exit 1
}

# Project-relative form of an absolute path, for log lines.
rel() { printf '%s' "${1#"$PROJECT_DIR"/}"; }

phase_slug() { basename "$1" | tr -cd 'A-Za-z0-9._-'; }

new_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen; }

# ── Prompt templates ────────────────────────────────────────────────────────
# render_prompt NAME KEY=VALUE ...  → prompts/NAME.md with {{KEY}} substituted.
# Values may span many lines (entry files, diffs, verdicts).
render_prompt() {
  local tpl kv key val
  tpl="$(<"$PROMPTS_DIR/$1.md")"
  shift
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    tpl="${tpl//"{{$key}}"/$val}"
  done
  printf '%s\n' "$tpl"
}

# ── stream-json helpers ─────────────────────────────────────────────────────
# The agent log is one JSON object per line plus the occasional plain-text
# warning from the CLI; `fromjson?` skips anything that is not JSON.
last_result() { jq -R -c 'fromjson? | select(.type=="result")' "$1" 2>/dev/null | tail -1; }

# The structured report/verdict the agent returned (--json-schema), or empty.
structured_output() {
  last_result "$1" | jq -c '.structured_output // (.result | fromjson?) // empty' 2>/dev/null
}

# Human-readable transcript next to the raw log: foo.log → foo.txt
render_log() {
  [[ -f "$1" ]] || return 0
  jq -R -r -f "$LIB_DIR/render.jq" "$1" > "${1%.log}.txt" 2>/dev/null || true
}

# ── runs.tsv — one row per agent run / gate / push, read by `status` ────────
# record_run PHASE ROLE ROUND OUTCOME LOGFILE [NOTE] [SECONDS]
# Cost and turns are summed over every result event in LOGFILE (retries append
# to the same file). SECONDS is wall time measured by the caller.
record_run() {
  local phase="$1" role="$2" round="$3" outcome="$4" logfile="$5" note="${6:-}" secs="${7:-}"
  local cost="" turns=""
  if [[ -n "$logfile" && -f "$logfile" ]]; then
    read -r cost turns < <(jq -R -c 'fromjson? | select(.type=="result")' "$logfile" 2>/dev/null \
      | jq -s -r '[(map(.total_cost_usd // 0) | add // 0 | . * 100 | round / 100), (map(.num_turns // 0) | add // 0)] | @tsv' 2>/dev/null)
  fi
  [[ -f "$RUNS_FILE" ]] || printf 'ts\tphase\trole\tround\toutcome\tseconds\tcost_usd\tturns\tnote\n' > "$RUNS_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" "$phase" "$role" "$round" "$outcome" "${secs:-}" "${cost:-}" "${turns:-}" \
    "$(printf '%s' "$note" | tr '\t\n' '  ')" >> "$RUNS_FILE"
}

# ── SUMMARY.md ──────────────────────────────────────────────────────────────
write_summary() {  # write_summary STATUS [TEXT]
  {
    echo "# Phase run — $1 — $(date -u +%FT%TZ)"
    echo
    [[ -n "${2:-}" ]] && { echo "$2"; echo; }
    echo "Branch: ${GIT_BRANCH:-?}"
    echo
    echo "Completed phases:"
    if [[ -s "$DONE_FILE" ]]; then sed 's/^/  - /' "$DONE_FILE"; else echo "  (none)"; fi
    if [[ -s "$BLOCKED_FILE" ]]; then
      echo
      echo "Blocked:"
      awk -F'\t' '{ print "  - " $1 " — " $2 }' "$BLOCKED_FILE"
    fi
    echo
    echo "Per-phase cost, rounds and verdicts: \`phase-runner status\`. Logs: \`$(rel "$LOGS")/\`, verdicts: \`$(rel "$REVIEWS")/\`."
    echo
    echo '```'
    git log --oneline -15 2>/dev/null
    echo '```'
  } > "$STATE/SUMMARY.md" 2>/dev/null || true
}
