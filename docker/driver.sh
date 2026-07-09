#!/usr/bin/env bash
# Phase driver (runs as `node` inside the runner container).
#
# For each phase file, in order: launch one Claude Code run scoped to exactly
# that phase, then (optionally) run independent gates, then ensure the work is
# committed and push it. Completed phases are recorded in /state/phases-done,
# so a crashed or interrupted run resumes where it left off.
#
# Retry policy — "the API stopped responding", two detectable shapes:
#   1. claude exits non-zero and the log tail looks like a transient
#      API/network error (5xx, 429, overloaded, connection reset, …).
#   2. claude produces NO output for STALL_TIMEOUT seconds (a true hang) —
#      a watchdog kills it and marks the log.
# Both retry on the escalating RETRY_SCHEDULE (e.g. 30s → 5m → 1h → 3h);
# the schedule's length IS the retry count. Retries resume the interrupted
# session with --continue so in-flight phase context is not lost; an honest
# agent stop (clean non-transient failure) is NEVER retried into submission.
set -uo pipefail

cd "${PROJECT_DIR:?PROJECT_DIR is not set}"

STATE="${RUNNER_STATE:-/state}"
DONE_FILE="$STATE/phases-done"
LOGS="$STATE/logs"
mkdir -p "$LOGS"
touch "$DONE_FILE"

read -r -a SCHEDULE <<< "${RETRY_SCHEDULE:-30 300 3600 10800}"
read -r -a PHASES <<< "${PHASE_FILES:?PHASE_FILES is not set (ordered, space-separated phase plan files)}"
ENTRY_FILE="${ENTRY_FILE:?ENTRY_FILE is not set (the entry/constitution prompt file)}"
STALL_TIMEOUT="${STALL_TIMEOUT:-1800}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
PUSH="${PUSH:-1}"
GATE_CMD="${GATE_CMD:-}"
PREFLIGHT="${PREFLIGHT:-0}"
REVIEW="${REVIEW:-0}"

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
die() {
  printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2
  {
    echo "FAILED: $*"
    echo "completed phases: $(tr '\n' ' ' < "$DONE_FILE")"
    echo "logs: state/logs/ — re-run to resume from the first unfinished phase"
  } > "$STATE/SUMMARY.md" 2>/dev/null
  exit 1
}

[[ -f "$ENTRY_FILE" ]] || die "entry file not found: $ENTRY_FILE (path is relative to the project root)"
for p in "${PHASES[@]}"; do
  [[ -f "$p" ]] || die "phase file not found: $p (paths are relative to the project root)"
done

phase_done() { grep -qxF "$1" "$DONE_FILE"; }
phase_slug() { basename "$1" | tr -cd 'A-Za-z0-9._-'; }

# ── Claude launch with stall watchdog ─────────────────────────────────────────
# stream-json keeps the log moving on every agent event, which is what lets the
# watchdog distinguish "thinking about a long build" from "API went dark".
run_claude() {
  local logfile="$1" prompt="$2" mode="$3" rc
  local args=(--dangerously-skip-permissions --output-format stream-json --verbose)
  [[ -n "${CLAUDE_MODEL:-}" ]] && args+=(--model "$CLAUDE_MODEL")
  [[ "$mode" == "continue" ]] && args+=(--continue)

  claude "${args[@]}" -p "$prompt" >>"$logfile" 2>&1 &
  local pid=$!

  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep 30
      local age=$(( $(date +%s) - $(stat -c %Y "$logfile" 2>/dev/null || date +%s) ))
      if (( age > STALL_TIMEOUT )); then
        echo "RUNNER-STALL: no agent output for ${age}s (limit ${STALL_TIMEOUT}s) — killing" >>"$logfile"
        kill "$pid" 2>/dev/null
        break
      fi
    done
  ) &
  local watchdog=$!

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
  tail -8 "$1" | grep -qiE 'no conversation (found|to continue)'
}

# ── Retry loop around one agent objective ─────────────────────────────────────
run_agent() {
  local logfile="$1" prompt="$2"
  local max_attempts=$(( ${#SCHEDULE[@]} + 1 ))
  local attempt rc

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    if (( attempt == 1 )); then
      run_claude "$logfile" "$prompt" fresh
      rc=$?
    else
      log "Retry $((attempt-1))/${#SCHEDULE[@]}: resuming interrupted session (--continue)"
      run_claude "$logfile" \
        "The previous run was interrupted by an API failure. Inspect the repo state and continue the same phase from where it stopped. The original instructions still apply in full." \
        continue
      rc=$?
      if (( rc != 0 )) && no_session "$logfile"; then
        log "No session to continue — restarting the phase prompt from scratch"
        run_claude "$logfile" "$prompt" fresh
        rc=$?
      fi
    fi
    (( rc == 0 )) && return 0

    if (( attempt < max_attempts )) && is_transient "$logfile"; then
      local delay="${SCHEDULE[$((attempt-1))]}"
      log "Transient API failure (attempt $attempt/$max_attempts, rc=$rc) — retrying in ${delay}s"
      sleep "$delay"
      continue
    fi
    return "$rc"
  done
  return 1
}

# ── Commit + push ─────────────────────────────────────────────────────────────
checkpoint_commit() {
  local phase_file="$1"
  git add -A
  if ! git diff --cached --quiet; then
    # The agent should have committed itself; this makes sure nothing in-flight
    # is ever lost between phases.
    git commit -m "chore(runner): checkpoint uncommitted work after $(basename "$phase_file")" \
      || die "checkpoint commit failed"
    log "Checkpoint commit created for leftover working-tree changes"
  fi
}

push_branch() {
  [[ "$PUSH" == "1" ]] || { log "PUSH=0 — skipping push"; return 0; }
  local try
  for try in 1 2 3; do
    if git push -u "$GIT_REMOTE" "$GIT_BRANCH" >>"$LOGS/push.log" 2>&1; then
      log "Pushed $GIT_BRANCH to $GIT_REMOTE"
      return 0
    fi
    log "Push failed (attempt $try/3) — retrying in 30s"
    sleep 30
  done
  die "push to $GIT_REMOTE/$GIT_BRANCH failed 3 times (state/logs/push.log) — completed phases stay recorded; fix credentials and re-run to push the backlog"
}

# ── Prompts ───────────────────────────────────────────────────────────────────
preflight_prompt() {
  cat <<EOF
$(cat "$ENTRY_FILE")

The phase plan for this project, in execution order:
$(for p in "${PHASES[@]}"; do echo "  - $p"; done)

PRE-FLIGHT TOOLING ASSESSMENT — this runs BEFORE any building. Read the entry
prompt above and every phase file listed, then assess what TOOLING would make
this build faster and more reliable: Claude Code skills, MCP servers, plugins,
system/apt packages, and external services or credentials the phases will need.

For each recommendation state: what it is, which phase(s) need it, why, and
exactly how the human provisions it here (add a secret to credentials.env, add a
package to EXTRA_APT_PACKAGES, mount a skill/plugin, configure an MCP server,
etc.). Flag anything requiring secrets or OAuth up front — the unattended runner
cannot authenticate mid-build, so those must be in place before launch.

This is a REPORT-ONLY pass. Do NOT modify the project in any way. Write ONLY the
report, to the absolute path ${STATE}/TOOLING.md. Do not commit and do not push.
EOF
}

phase_prompt() {
  cat <<EOF
$(cat "$ENTRY_FILE")

CURRENT SCOPE — this run must execute exactly ONE phase.
Read ${1} fully and execute only that phase, honoring everything above.
Stop when that phase's Definition of Done holds and all work is committed with
conventional-commit messages. Do not start any other phase. Do not push — the
runner pushes after every phase. If the DoD is unreachable, stop honestly with
a clear blocker report (what failed, what you tried, what is needed); never
fake a green result.
EOF
}

remediation_prompt() {
  cat <<EOF
You are the same agent, in the same repository. The phase defined in ${1} was
executed, but the runner's independent gate command FAILED afterwards:

  $GATE_CMD

Last 60 lines of gate output:

$(tail -60 "$LOGS/gates-$(phase_slug "$1").log")

Re-read ${1}, fix forward until the gate command passes, and commit the fix.
Do not fake green.
EOF
}

review_prompt() {
  # Overridable in one place: set REVIEW_PROMPT to replace the wording below.
  # The entry/constitution file is still prepended for grounding.
  local body="${REVIEW_PROMPT:-Now make an adversarial evaluation on what can be improved, simplified, made more resilient. Do it thoroughly.}"
  cat <<EOF
$(cat "$ENTRY_FILE")

FINAL ADVERSARIAL REVIEW — every planned phase is complete and committed.
$body

This is a REPORT-ONLY pass. Do NOT change the project in any way — not code,
config, docs, or git. Not even small fixes. Every improvement, however safe it
looks, goes into the report as a recommendation for the human to approve later.
Write ONLY the report, to the absolute path ${STATE}/REVIEW.md: a prioritized
list where each item states what, why it matters, severity, and the concrete
fix you would make. Do not commit and do not push.
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "Phase runner starting in $PROJECT_DIR (branch: $GIT_BRANCH, remote: $GIT_REMOTE)"
log "Phases: ${PHASES[*]}"
log "Retry schedule: ${SCHEDULE[*]}s; stall timeout: ${STALL_TIMEOUT}s"

if [[ -n "${DRY_RUN:-}" ]]; then
  log "DRY RUN: config parsed, entry + phase files exist. First phase prompt follows."
  phase_prompt "${PHASES[0]}"
  exit 0
fi

# ── Pre-flight tooling assessment (standalone; stops before building) ─────────
# Read the plan and report what skills/MCP/plugins/packages/creds to provision.
# Report-only and never touches the project or git: you read state/TOOLING.md,
# provision, then set PREFLIGHT=0 and re-run to actually build.
if [[ "$PREFLIGHT" == "1" ]]; then
  log "Pre-flight tooling assessment: launching agent (log: state/logs/preflight.log)"
  run_agent "$LOGS/preflight.log" "$(preflight_prompt)" \
    || die "pre-flight assessment agent failed (state/logs/preflight.log)"
  log "Assessment written to state/TOOLING.md — review it, provision tooling, then re-run to build."
  exit 0
fi

# ── Final adversarial review (standalone; report-only) ────────────────────────
# Run after the build (`run.sh review`): evaluate the finished project and write
# a prioritized report. Changes nothing — you read state/REVIEW.md and give the
# green light for improvements yourself.
if [[ "$REVIEW" == "1" ]]; then
  log "Final adversarial review: launching agent (log: state/logs/review.log)"
  run_agent "$LOGS/review.log" "$(review_prompt)" \
    || die "final adversarial review agent failed (state/logs/review.log)"
  log "Review written to state/REVIEW.md — read it, then give the green light for improvements."
  exit 0
fi

# Push any backlog a previous run left behind (e.g. it died on push).
if [[ "$PUSH" == "1" ]] && [[ -n "$(git log --oneline "$GIT_REMOTE/$GIT_BRANCH..HEAD" 2>/dev/null)" ]]; then
  log "Unpushed commits from a previous run detected — pushing backlog first"
  push_branch
fi

for phase_file in "${PHASES[@]}"; do
  slug="$(phase_slug "$phase_file")"
  if phase_done "$phase_file"; then
    log "Phase $phase_file: already completed in a previous run — skipping"
    continue
  fi

  log "Phase $phase_file: launching agent (log: state/logs/phase-$slug.log)"
  run_agent "$LOGS/phase-$slug.log" "$(phase_prompt "$phase_file")" \
    || die "agent failed in phase $phase_file (state/logs/phase-$slug.log)"

  if [[ -n "$GATE_CMD" ]]; then
    log "Running independent gates: $GATE_CMD"
    if ! bash -c "$GATE_CMD" >>"$LOGS/gates-$slug.log" 2>&1; then
      log "Gates RED — one remediation attempt"
      run_agent "$LOGS/phase-$slug-remediation.log" "$(remediation_prompt "$phase_file")" \
        || die "remediation agent failed in phase $phase_file"
      bash -c "$GATE_CMD" >>"$LOGS/gates-$slug-after-remediation.log" 2>&1 \
        || die "phase $phase_file still red after remediation"
    fi
  fi

  checkpoint_commit "$phase_file"
  echo "$phase_file" >> "$DONE_FILE"
  push_branch
  log "Phase $phase_file: done, committed, pushed"
done

log "All phases complete"
{
  echo "# Phase run — SUCCESS $(date -u +%FT%TZ)"
  echo
  echo "Branch: $GIT_BRANCH"
  git log --oneline -20
} > "$STATE/SUMMARY.md"
