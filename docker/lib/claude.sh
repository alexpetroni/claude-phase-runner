# shellcheck shell=bash
# Launching Claude Code per role, with a stall watchdog and transient-failure
# retries. Sourced by driver.sh.
#
# Roles and what they get:
#   build / fix      edit tools, structured end report (status done|blocked)
#   review           NO edit tools, structured verdict (PASS|FAIL + DoD table + findings)
#   preflight        NO edit tools, returns a Markdown report the driver writes out
#   final-review     NO edit tools, returns a Markdown report the driver writes out
# Every role runs with the guard hook (docker/guard.sh) unless GUARD=0.
#
# Retry policy — "the API stopped responding", two detectable shapes:
#   1. claude exits non-zero and the log tail looks like a transient API/network
#      error (5xx, 429, overloaded, connection reset, …).
#   2. claude produces NO output for STALL_TIMEOUT seconds — the watchdog kills it.
# Both retry on the escalating RETRY_SCHEDULE; the schedule's length IS the
# retry count. Retries resume the SAME session by id (never "the most recent
# conversation", which could belong to another phase), so in-flight context is
# kept. A clean non-transient failure is never retried into submission.

read -r -a SCHEDULE <<< "${RETRY_SCHEDULE:-30 300 3600 10800}"
STALL_TIMEOUT="${STALL_TIMEOUT:-1800}"
STALL_POLL="${STALL_POLL:-30}"
GUARD="${GUARD:-1}"

EDIT_TOOLS="Edit,Write,MultiEdit,NotebookEdit"

REPORT_SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["done","blocked"]},"summary":{"type":"string"},"commits":{"type":"array","items":{"type":"string"}},"blockers":{"type":"string"}},"required":["status","summary"]}'

VERDICT_SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]},"summary":{"type":"string"},"dod":{"type":"array","items":{"type":"object","properties":{"item":{"type":"string"},"verdict":{"type":"string","enum":["PASS","FAIL"]},"evidence":{"type":"string"}},"required":["item","verdict","evidence"]}},"findings":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["critical","high","medium","low"]},"file":{"type":"string"},"line":{"type":"integer"},"what":{"type":"string"},"fix":{"type":"string"}},"required":["severity","file","what","fix"]}}},"required":["verdict","summary","dod","findings"]}'

REPORT_ONLY_SCHEMA='{"type":"object","properties":{"report":{"type":"string"}},"required":["report"]}'

guard_settings() {
  [[ "$GUARD" == "1" ]] || return 0
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash|Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash %s/docker/guard.sh"}]}]}}' "$RUNNER_HOME"
}

# Fills ROLE_ARGS (a global; bash functions cannot return arrays).
role_args() {
  ROLE_ARGS=()
  local model effort budget settings
  case "$1" in
    review|final-review|preflight)
      model="${REVIEW_MODEL:-${CLAUDE_MODEL:-}}"
      effort="${REVIEW_EFFORT:-${CLAUDE_EFFORT:-}}"
      budget="${REVIEW_BUDGET_USD:-}"
      ;;
    *)
      model="${BUILD_MODEL:-${CLAUDE_MODEL:-}}"
      effort="${BUILD_EFFORT:-${CLAUDE_EFFORT:-}}"
      budget="${BUILD_BUDGET_USD:-}"
      ;;
  esac
  [[ -n "$model" ]]  && ROLE_ARGS+=(--model "$model")
  [[ -n "$effort" ]] && ROLE_ARGS+=(--effort "$effort")
  [[ -n "$budget" ]] && ROLE_ARGS+=(--max-budget-usd "$budget")
  case "$1" in
    build|fix)             ROLE_ARGS+=(--json-schema "$REPORT_SCHEMA") ;;
    review)                ROLE_ARGS+=(--disallowedTools "$EDIT_TOOLS" --json-schema "$VERDICT_SCHEMA") ;;
    preflight|final-review) ROLE_ARGS+=(--disallowedTools "$EDIT_TOOLS" --json-schema "$REPORT_ONLY_SCHEMA") ;;
  esac
  settings="$(guard_settings)"
  [[ -n "$settings" ]] && ROLE_ARGS+=(--settings "$settings")
  return 0
}

# run_claude LOGFILE ROLE SESSION PROMPT     SESSION = new:<uuid> | resume:<uuid>
# stream-json keeps the log moving on every agent event, which is what lets the
# watchdog distinguish "thinking about a long build" from "API went dark".
run_claude() {
  local logfile="$1" role="$2" session="$3" prompt="$4" rc pid watchdog
  role_args "$role"
  local args=(--dangerously-skip-permissions --output-format stream-json --verbose "${ROLE_ARGS[@]}")
  case "$session" in
    new:*)    args+=(--session-id "${session#new:}") ;;
    resume:*) args+=(--resume "${session#resume:}") ;;
  esac

  PHASE_RUNNER_ROLE="$role" PHASE_RUNNER_PROTECTED="${PROTECTED_PATHS:-}" PROJECT_DIR="$PROJECT_DIR" \
    claude "${args[@]}" -p "$prompt" >>"$logfile" 2>&1 &
  pid=$!

  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep "$STALL_POLL"
      age=$(( $(date +%s) - $(stat -c %Y "$logfile" 2>/dev/null || date +%s) ))
      if (( age > STALL_TIMEOUT )); then
        echo "RUNNER-STALL: no agent output for ${age}s (limit ${STALL_TIMEOUT}s) — killing" >>"$logfile"
        kill "$pid" 2>/dev/null
        sleep 10
        kill -9 "$pid" 2>/dev/null
        break
      fi
    done
  ) &
  watchdog=$!

  wait "$pid"; rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

is_transient() {
  tail -8 "$1" | grep -qiE \
    'RUNNER-STALL|unable to connect|connection ?refused|connection ?reset|econnreset|econnrefused|etimedout|fetch failed|socket hang up|network error|overloaded|rate.?limit|api error.*(5[0-9][0-9]|429)|(5[0-9][0-9]|429).*api error'
}

no_session() {
  tail -8 "$1" | grep -qiE 'no conversation (found|to continue)|session .* not found'
}

# What a non-zero, non-transient exit most likely was — for the abort message.
failure_hint() {
  local tail8; tail8="$(tail -8 "$1")"
  if grep -qiE 'budget' <<<"$tail8"; then echo "the run hit its --max-budget-usd cap"
  elif grep -qiE 'max.?turns' <<<"$tail8"; then echo "the run hit its max-turns cap"
  elif grep -qiE 'authentication|unauthorized|invalid.*token|401' <<<"$tail8"; then echo "authentication failed — check credentials.env"
  else echo "not a transient API error, so it is not retried"
  fi
}

# run_agent LOGFILE ROLE PROMPT → exit status of the last attempt.
run_agent() {
  local logfile="$1" role="$2" prompt="$3"
  local max_attempts=$(( ${#SCHEDULE[@]} + 1 ))
  local attempt rc sid delay
  sid="$(new_uuid)"

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    if (( attempt == 1 )); then
      run_claude "$logfile" "$role" "new:$sid" "$prompt"; rc=$?
    else
      log "Retry $((attempt-1))/${#SCHEDULE[@]} ($role): resuming session ${sid:0:8}"
      run_claude "$logfile" "$role" "resume:$sid" "$(render_prompt continue)"; rc=$?
      if (( rc != 0 )) && no_session "$logfile"; then
        log "No session to resume — restarting the $role prompt from scratch"
        sid="$(new_uuid)"
        run_claude "$logfile" "$role" "new:$sid" "$prompt"; rc=$?
      fi
    fi
    (( rc == 0 )) && return 0

    if (( attempt < max_attempts )) && is_transient "$logfile"; then
      delay="${SCHEDULE[$((attempt-1))]}"
      log "Transient API failure ($role, attempt $attempt/$max_attempts, rc=$rc) — retrying in ${delay}s"
      sleep "$delay"
      continue
    fi
    return "$rc"
  done
  return 1
}
