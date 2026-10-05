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
# A subscription usage window is judged by the CLI's rejected rate_limit_event,
# which says when the window resets (see run_agent): waited out when the reset
# is within LIMIT_WAIT_MAX, an honest stop when it is further away.

read -r -a SCHEDULE <<< "${RETRY_SCHEDULE:-30 300 3600 10800}"
STALL_TIMEOUT="${STALL_TIMEOUT:-1800}"
STALL_POLL="${STALL_POLL:-30}"
GUARD="${GUARD:-1}"
# Model for the subagents an agent spawns (Explore, general-purpose, …) when the
# agent definition names none. Cheap exploration should not run on the flagship.
SUBAGENT_MODEL="${SUBAGENT_MODEL:-}"
# Characters of a Bash tool result that enter the context inline; the rest goes
# to a file the agent can grep. Tool output is the single largest cache-write
# cost, so keep this modest (Claude Code's default is 30000).
BASH_OUTPUT_MAX_CHARS="${BASH_OUTPUT_MAX_CHARS:-}"
# Longest wait for a subscription usage window to reset before giving up, and
# the seconds added to every such wait: the reset time is the server's and
# the clocks differ, so resuming on the dot can be rejected once more.
LIMIT_WAIT_MAX="${LIMIT_WAIT_MAX:-21600}"
LIMIT_WAIT_GRACE="${LIMIT_WAIT_GRACE:-60}"
# The agent's Bash tool. A command that outruns its timeout is moved to the
# background by Claude Code, and in a headless run the agent then ends its
# turn waiting for a notification that never comes (README "What happens in a
# phase"). So: a long default timeout, a maximum that stays under the stall
# watchdog (a foreground command prints nothing while it runs), and
# background tasks off. Seconds; the explicit values are kept apart from the
# resolved ones so that only what the project set is validated.
BASH_TIMEOUT_SET="${BASH_TIMEOUT:-}"
BASH_TIMEOUT_MAX_SET="${BASH_TIMEOUT_MAX:-}"
BACKGROUND_TASKS="${BACKGROUND_TASKS:-0}"

# resolve_bash_settings — dies naming the setting, its value and the rule when
# an explicit value is invalid; fills BASH_TIMEOUT and BASH_TIMEOUT_MAX.
# Derived defaults never stop a run: BASH_TIMEOUT_MAX falls back to
# STALL_TIMEOUT - 300 (never below 120), BASH_TIMEOUT to 600 capped at the max.
resolve_bash_settings() {
  local v
  for v in BASH_TIMEOUT_SET BASH_TIMEOUT_MAX_SET; do
    [[ -z "${!v}" || "${!v}" =~ ^[1-9][0-9]*$ ]] || die "${v%_SET}=${!v}: must be a positive integer (seconds)"
  done
  [[ "$BACKGROUND_TASKS" =~ ^[01]$ ]] || die "BACKGROUND_TASKS=$BACKGROUND_TASKS: must be 0 or 1"
  if [[ -n "$BASH_TIMEOUT_MAX_SET" ]]; then
    (( BASH_TIMEOUT_MAX_SET < STALL_TIMEOUT )) || die "BASH_TIMEOUT_MAX=$BASH_TIMEOUT_MAX_SET: must be below STALL_TIMEOUT ($STALL_TIMEOUT) — the watchdog kills an agent that prints nothing for that long, and a foreground command prints nothing until it ends"
    BASH_TIMEOUT_MAX="$BASH_TIMEOUT_MAX_SET"
  else
    BASH_TIMEOUT_MAX=$(( STALL_TIMEOUT - 300 ))
    (( BASH_TIMEOUT_MAX < 120 )) && BASH_TIMEOUT_MAX=120
  fi
  if [[ -n "$BASH_TIMEOUT_SET" ]]; then
    (( BASH_TIMEOUT_SET <= BASH_TIMEOUT_MAX )) || die "BASH_TIMEOUT=$BASH_TIMEOUT_SET: must not be above BASH_TIMEOUT_MAX ($BASH_TIMEOUT_MAX)"
    BASH_TIMEOUT="$BASH_TIMEOUT_SET"
  else
    BASH_TIMEOUT=600
    (( BASH_TIMEOUT > BASH_TIMEOUT_MAX )) && BASH_TIMEOUT="$BASH_TIMEOUT_MAX"
  fi
  return 0
}

EDIT_TOOLS="Edit,Write,MultiEdit,NotebookEdit"

REPORT_SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["done","blocked"]},"summary":{"type":"string"},"commits":{"type":"array","items":{"type":"string"}},"blockers":{"type":"string"}},"required":["status","summary"]}'

VERDICT_SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]},"summary":{"type":"string"},"dod":{"type":"array","items":{"type":"object","properties":{"item":{"type":"string"},"verdict":{"type":"string","enum":["PASS","FAIL"]},"evidence":{"type":"string"}},"required":["item","verdict","evidence"]}},"findings":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["critical","high","medium","low"]},"file":{"type":"string"},"line":{"type":"integer"},"what":{"type":"string"},"fix":{"type":"string"}},"required":["severity","file","what","fix"]}}},"required":["verdict","summary","dod","findings"]}'

REPORT_ONLY_SCHEMA='{"type":"object","properties":{"report":{"type":"string"}},"required":["report"]}'

# The --settings JSON every role gets: the guard hook and the inline tool-output cap.
role_settings() {
  local parts=()
  [[ "$GUARD" == "1" ]] && parts+=("$(printf '"hooks":{"PreToolUse":[{"matcher":"Bash|Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash %s/docker/guard.sh"}]}]}' "$RUNNER_HOME")")
  [[ "$BASH_OUTPUT_MAX_CHARS" =~ ^[0-9]+$ ]] && parts+=("\"bashOutputMaxChars\":$BASH_OUTPUT_MAX_CHARS")
  (( ${#parts[@]} )) || return 0
  local IFS=,
  printf '{%s}' "${parts[*]}"
}

# Model/effort resolution, most specific first:
#   review roles   PHASE_REVIEW_MODEL → REVIEW_MODEL → CLAUDE_MODEL   (effort alike)
#   fix            PHASE_FIX_MODEL → FIX_MODEL → build's resolution
#   build          PHASE_MODEL → BUILD_MODEL → CLAUDE_MODEL
# PHASE_* come from the phase's manifest line (see driver.sh phase_opts).
role_model()  {  # role_model ROLE → model id or empty
  case "$1" in
    review|final-review|preflight) printf '%s' "${PHASE_REVIEW_MODEL:-${REVIEW_MODEL:-${CLAUDE_MODEL:-}}}" ;;
    fix) printf '%s' "${PHASE_FIX_MODEL:-${FIX_MODEL:-$(role_model build)}}" ;;
    *)   printf '%s' "${PHASE_MODEL:-${BUILD_MODEL:-${CLAUDE_MODEL:-}}}" ;;
  esac
}
role_effort() {  # role_effort ROLE → effort level or empty
  case "$1" in
    review|final-review|preflight) printf '%s' "${PHASE_REVIEW_EFFORT:-${REVIEW_EFFORT:-${CLAUDE_EFFORT:-}}}" ;;
    fix) printf '%s' "${PHASE_FIX_EFFORT:-${FIX_EFFORT:-$(role_effort build)}}" ;;
    *)   printf '%s' "${PHASE_EFFORT:-${BUILD_EFFORT:-${CLAUDE_EFFORT:-}}}" ;;
  esac
}
role_desc() { printf 'model %s, effort %s' "$(role_model "$1")" "$(role_effort "$1")"; }  # for log lines

# Fills ROLE_ARGS (a global; bash functions cannot return arrays).
role_args() {
  ROLE_ARGS=()
  local model effort budget settings
  model="$(role_model "$1")"; effort="$(role_effort "$1")"
  case "$1" in
    review|final-review|preflight) budget="${REVIEW_BUDGET_USD:-}" ;;
    *)                             budget="${BUILD_BUDGET_USD:-}" ;;
  esac
  [[ -n "$model" ]]  && ROLE_ARGS+=(--model "$model")
  [[ -n "$effort" ]] && ROLE_ARGS+=(--effort "$effort")
  [[ -n "$budget" ]] && ROLE_ARGS+=(--max-budget-usd "$budget")
  case "$1" in
    build|fix)             ROLE_ARGS+=(--json-schema "$REPORT_SCHEMA") ;;
    review)                ROLE_ARGS+=(--disallowedTools "$EDIT_TOOLS" --json-schema "$VERDICT_SCHEMA") ;;
    preflight|final-review) ROLE_ARGS+=(--disallowedTools "$EDIT_TOOLS" --json-schema "$REPORT_ONLY_SCHEMA") ;;
  esac
  settings="$(role_settings)"
  [[ -n "$settings" ]] && ROLE_ARGS+=(--settings "$settings")
  return 0
}

# run_claude LOGFILE ROLE SESSION PROMPT     SESSION = new:<uuid> | resume:<uuid>
# stream-json keeps the log moving on every agent event, which is what lets the
# watchdog distinguish "thinking about a long build" from "API went dark".
run_claude() {
  local logfile="$1" role="$2" session="$3" prompt="$4" rc pid watchdog
  ATTEMPT_START=$(stat -c %s "$logfile" 2>/dev/null || echo 0)
  role_args "$role"
  local args=(--dangerously-skip-permissions --output-format stream-json --verbose "${ROLE_ARGS[@]}")
  case "$session" in
    new:*)    args+=(--session-id "${session#new:}") ;;
    resume:*) args+=(--resume "${session#resume:}") ;;
  esac

  local env=(PHASE_RUNNER_ROLE="$role" PHASE_RUNNER_PROTECTED="${PROTECTED_PATHS:-}" PROJECT_DIR="$PROJECT_DIR")
  [[ -n "$SUBAGENT_MODEL" ]] && env+=(CLAUDE_CODE_SUBAGENT_MODEL="$SUBAGENT_MODEL")
  env+=(BASH_DEFAULT_TIMEOUT_MS=$(( BASH_TIMEOUT * 1000 )) BASH_MAX_TIMEOUT_MS=$(( BASH_TIMEOUT_MAX * 1000 )))
  [[ "$BACKGROUND_TASKS" == "0" ]] && env+=(CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1)
  # The forwarded SSH agent is the runner's push credential: only the driver's
  # own git calls get it, never an agent (of any role) and what it spawns.
  env -u SSH_AUTH_SOCK "${env[@]}" claude "${args[@]}" -p "$prompt" >>"$logfile" 2>&1 &
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

# ── Judging a failed attempt ────────────────────────────────────────────────
# Retries and re-runs append to one log file, so an event or an error text
# left by an earlier attempt or an earlier run must never decide a later
# failure: everything below reads attempt_text, what the attempt being judged
# appended. run_claude records where that starts.
ATTEMPT_START=0
attempt_text() { tail -c +$(( ATTEMPT_START + 1 )) "$1" 2>/dev/null; }
# The text of the attempt's last result event — the CLI's final error message.
result_text() { attempt_text "$1" | jq -R -c 'fromjson? | select(.type=="result")' 2>/dev/null | tail -1 | jq -r '.result // empty' 2>/dev/null; }

# The attempt's last lines plus its result text — the CLI's final error message
# may sit in either place. Buffered into a variable by the callers: with
# pipefail, `producer | grep -q` fails on SIGPIPE when grep matches early.
log_tail() { { attempt_text "$1" | tail -12; result_text "$1"; } 2>/dev/null; }

is_transient() {
  local t; t="$(log_tail "$1")"
  out_of_credits_text "$t" && return 1
  grep -qiE 'RUNNER-STALL|unable to connect|connection ?refused|connection ?reset|econnreset|econnrefused|etimedout|fetch failed|socket hang up|network error|overloaded|rate.?limit|api error.*(5[0-9][0-9]|429)|(5[0-9][0-9]|429).*api error|request timed out' <<<"$t" \
    || usage_limited_text "$t"
}

# Without a rejected event, the wording decides: a limit that was hit ("You've
# hit your session limit · resets 3:20pm") resets on its own and is transient;
# being out of usage credits is not.
usage_limited_text() { grep -qiE "hit your (session|weekly|[a-z]+) limit|usage limit" <<<"$1"; }
out_of_credits_text() { grep -qiE 'out of usage credits|insufficient credits|credit balance' <<<"$1"; }
out_of_credits() { out_of_credits_text "$(log_tail "$1")"; }

# limit_event LOGFILE → 0 and LIMIT_TYPE, LIMIT_RESET (epoch seconds) from the
# attempt's last rejected rate_limit_event that carries a usable resetsAt; 1
# when there is none. Only rate_limit_info.status says whether the request was
# rejected: a healthy run's `allowed` events carry overageStatus "rejected" and
# overageDisabledReason "out_of_credits" too — those describe the account.
# The CLI's wording varies for the same window, so the event outranks the text.
limit_event() {
  local ev
  ev="$(attempt_text "$1" | jq -R -r 'fromjson? | select(.type=="rate_limit_event" and .rate_limit_info.status=="rejected" and (.rate_limit_info.resetsAt|type)=="number") | "\(.rate_limit_info.resetsAt|floor) \(.rate_limit_info.rateLimitType // "unknown")"' 2>/dev/null | tail -1)"
  LIMIT_RESET="${ev%% *}"; LIMIT_TYPE="${ev#* }"
  [[ "$LIMIT_RESET" =~ ^[1-9][0-9]*$ ]]
}
utc_time() { date -u -d "@$1" '+%F %H:%M UTC'; }

# The abort message for a usage limit: which window, when it resets and how far
# away that is, what the CLI said, and how to continue. Reaches SUMMARY.md via die.
limit_hint() {
  local left; left=$(( LIMIT_RESET - $(date +%s) ))
  printf 'usage limit: the %s window resets at %s' "$LIMIT_TYPE" "$(utc_time "$LIMIT_RESET")"
  if (( left > 0 )); then
    printf ' (in %dh %02dm' $(( left / 3600 )) $(( left % 3600 / 60 ))
    (( left > LIMIT_WAIT_MAX )) && printf ', further away than LIMIT_WAIT_MAX=%ss' "$LIMIT_WAIT_MAX"
    printf ')'
  else
    printf ' (already passed)'
  fi
  printf '; the CLI said "%s" — re-run `phase-runner build` after that time to resume where the run stopped, or raise LIMIT_WAIT_MAX to make the runner wait instead' "$(result_text "$1")"
}

no_session() {
  local t; t="$(attempt_text "$1" | tail -8)"
  grep -qiE 'no conversation (found|to continue)|session .* not found' <<<"$t"
}

# What a non-zero, non-transient exit most likely was — for the abort message.
failure_hint() {
  local tail8; tail8="$(attempt_text "$1" | tail -8)"
  if limit_event "$1"; then limit_hint "$1"
  elif out_of_credits "$1"; then echo "the subscription is out of usage credits — top up, wait for the window, or switch to API billing"
  elif grep -qiE 'max.?budget|budget cap|exceeded.*budget' <<<"$tail8"; then echo "the run hit its --max-budget-usd cap"
  elif grep -qiE 'max.?turns' <<<"$tail8"; then echo "the run hit its max-turns cap"
  elif grep -qiE 'authentication|unauthorized|invalid.*token|401' <<<"$tail8"; then echo "authentication failed — check credentials.env"
  else echo "not a transient API error, so it is not retried"
  fi
}

# run_agent LOGFILE ROLE PROMPT [RESUME_SID] → exit status of the last attempt.
# With RESUME_SID the first attempt continues that session (FIX_CONTEXT=resume);
# returns 3 without retrying when the session no longer exists so the caller can
# fall back to a fresh context. Sets LAST_SESSION_ID to the session used.
run_agent() {
  local logfile="$1" role="$2" prompt="$3" resume="${4:-}"
  local max_attempts=$(( ${#SCHEDULE[@]} + 1 ))
  local attempt rc sid delay wait
  if [[ -n "$resume" ]]; then sid="$resume"; else sid="$(new_uuid)"; fi
  LAST_SESSION_ID="$sid"

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    if (( attempt == 1 )); then
      if [[ -n "$resume" ]]; then
        run_claude "$logfile" "$role" "resume:$sid" "$prompt"; rc=$?
        if (( rc != 0 )) && no_session "$logfile"; then return 3; fi
      else
        run_claude "$logfile" "$role" "new:$sid" "$prompt"; rc=$?
      fi
    else
      log "Retry $((attempt-1))/${#SCHEDULE[@]} ($role): resuming session ${sid:0:8}"
      run_claude "$logfile" "$role" "resume:$sid" "$(render_prompt continue)"; rc=$?
      if (( rc != 0 )) && no_session "$logfile"; then
        log "No session to resume — restarting the $role prompt from scratch"
        sid="$(new_uuid)"
        # shellcheck disable=SC2034  # read by the fix rounds in driver.sh (BUILD_SID)
        LAST_SESSION_ID="$sid"
        run_claude "$logfile" "$role" "new:$sid" "$prompt"; rc=$?
      fi
    fi
    (( rc == 0 )) && return 0

    if (( attempt < max_attempts )); then
      delay="${SCHEDULE[$((attempt-1))]}"
      if limit_event "$logfile"; then
        # The event decides. A window that resets within LIMIT_WAIT_MAX is
        # waited out; one that resets later stops the run at once (sleeping
        # LIMIT_WAIT_MAX towards a certain rejection helps nobody); one that
        # has reset already is a plain retry, whatever the text said.
        wait=$(( LIMIT_RESET - $(date +%s) ))
        (( wait > LIMIT_WAIT_MAX )) && return "$rc"
        if (( wait > 0 )); then
          delay=$(( wait + LIMIT_WAIT_GRACE ))
          log "Usage limit reached ($role, attempt $attempt/$max_attempts): the $LIMIT_TYPE window resets at $(utc_time "$LIMIT_RESET") — waiting ${delay}s, then resuming"
        else
          log "Usage window reset already ($role, attempt $attempt/$max_attempts): the $LIMIT_TYPE window reset at $(utc_time "$LIMIT_RESET") — retrying in ${delay}s"
        fi
      elif is_transient "$logfile"; then
        log "Transient API failure ($role, attempt $attempt/$max_attempts, rc=$rc) — retrying in ${delay}s"
      else
        return "$rc"
      fi
      sleep "$delay"
      continue
    fi
    return "$rc"
  done
  return 1
}
