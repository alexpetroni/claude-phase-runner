#!/usr/bin/env bash
# Phase driver (runs as `node` inside the runner container; also runnable on the
# host for tests with a fake `claude` on PATH — see tests/run.sh).
#
# Modes (RUNNER_MODE):
#   build      for each pending phase: BUILDER → checkpoint → GATE → REVIEWER →
#              (fix rounds, capped) → record done → push. Resumes after a crash.
#   dry-run    validate, print the first pending phase's builder prompt, exit.
#   preflight  read-only tooling assessment → state/TOOLING.md
#   review     read-only adversarial review of the built project → state/REVIEW.md
#
# Separation of powers: the builder never verifies its own work. A reviewer
# with a fresh context and no edit tools audits every DoD item against the
# repository and the diff and returns a structured verdict; the builder only
# comes back (fresh context again) to fix what the reviewer or the gate found.
set -uo pipefail

RUNNER_HOME="${PHASE_RUNNER_HOME:-/opt/phase-runner}"
cd "${PROJECT_DIR:?PROJECT_DIR is not set}" || exit 1

STATE="${RUNNER_STATE:-$PROJECT_DIR/.phase-runner/state}"
LOGS="$STATE/logs"
REVIEWS="$STATE/reviews"
DONE_FILE="$STATE/phases-done"
RUNS_FILE="$STATE/runs.tsv"
BLOCKED_FILE="$STATE/blocked"
mkdir -p "$LOGS" "$REVIEWS"
touch "$DONE_FILE"

# shellcheck source=lib/common.sh
source "$RUNNER_HOME/docker/lib/common.sh"
# shellcheck source=lib/claude.sh
source "$RUNNER_HOME/docker/lib/claude.sh"
# shellcheck source=lib/git.sh
source "$RUNNER_HOME/docker/lib/git.sh"

MODE="${RUNNER_MODE:-build}"
read -r -a PHASES <<< "${PHASE_FILES:?PHASE_FILES is not set (ordered phase plan files)}"
ENTRY_FILE="${ENTRY_FILE:?ENTRY_FILE is not set (the entry/constitution prompt file)}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
PUSH="${PUSH:-1}"
GATE_CMD="${GATE_CMD:-}"
PHASE_REVIEW="${PHASE_REVIEW:-1}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-2}"
COMMIT_REVIEWS="${COMMIT_REVIEWS:-0}"
REVIEWS_DIR="${REVIEWS_DIR:-docs/verification}"
# Model/effort for every role unless runner.env overrides them (BUILD_*/REVIEW_* per role).
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-fable-5-1}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-xhigh}"

[[ -f "$ENTRY_FILE" ]] || die "entry file not found: $ENTRY_FILE (path is relative to the project root)"
for p in "${PHASES[@]}"; do
  [[ -f "$p" ]] || die "phase file not found: $p (paths are relative to the project root)"
done

# Paths the agent may read but never modify (enforced by docker/guard.sh).
PROTECTED_PATHS="$ENTRY_FILE:$(IFS=:; printf '%s' "${PHASES[*]}"):.phase-runner"
ensure_exclude

phase_done() { grep -qxF "$1" "$DONE_FILE"; }
onoff() { [[ "$1" == "1" ]] && echo on || echo off; }

# ── Prompts ───────────────────────────────────────────────────────────────────
entry_text() { cat "$ENTRY_FILE"; }
rules_text() { render_prompt rules ENTRY_FILE="$ENTRY_FILE"; }

build_prompt() {  # build_prompt PHASE
  render_prompt build ENTRY="$(entry_text)" PHASE_FILE="$1" RULES="$(rules_text)"
}

fix_prompt() {  # fix_prompt PHASE ROUND DIFF_RANGE REASON
  render_prompt fix ENTRY="$(entry_text)" PHASE_FILE="$1" ROUND="$2" MAX_ROUNDS="$MAX_FIX_ROUNDS" \
    DIFF_RANGE="$3" REASON="$4" RULES="$(rules_text)"
}

review_prompt() {  # review_prompt PHASE BASE GATE_LOG
  local commits diffstat gate_out
  commits="$(git log --oneline "$2..HEAD" 2>/dev/null)"
  [[ -n "$commits" ]] || commits="(no commits — the builder committed nothing in this phase)"
  diffstat="$(git diff --stat "$2..HEAD" 2>/dev/null | tail -40)"
  [[ -n "$diffstat" ]] || diffstat="(empty diff)"
  if [[ -n "$3" && -f "$3" ]]; then gate_out="$(tail -40 "$3")"; else gate_out="(no gate command configured — run the project's own checks yourself)"; fi
  render_prompt review ENTRY="$(entry_text)" PHASE_FILE="$1" DIFF_RANGE="${2:0:12}..HEAD" \
    COMMITS="$commits" DIFFSTAT="$diffstat" GATE_CMD="${GATE_CMD:-<none configured>}" GATE_OUTPUT="$gate_out"
}

preflight_prompt() {
  render_prompt preflight ENTRY="$(entry_text)" PHASE_LIST="$(printf '  - %s\n' "${PHASES[@]}")"
}

final_review_prompt() {
  local body="${REVIEW_PROMPT:-Make an adversarial evaluation of what can be improved, simplified, and made more resilient. Do it thoroughly.}"
  render_prompt final-review ENTRY="$(entry_text)" REVIEW_BODY="$body" PHASE_LIST="$(printf '  - %s\n' "${PHASES[@]}")"
}

# ── Roles ─────────────────────────────────────────────────────────────────────
# run_builder PHASE ROLE ROUND LOGFILE PROMPT → 0 done, 1 blocked; dies on infra failure
run_builder() {
  local phase="$1" role="$2" round="$3" logfile="$4" prompt="$5"
  local t0 rc status summary
  t0=$(date +%s)
  run_agent "$logfile" "$role" "$prompt"; rc=$?
  render_log "$logfile"
  BUILDER_JSON="$(structured_output "$logfile")"
  status="$(jq -r '.status // "unknown"' <<<"${BUILDER_JSON:-null}" 2>/dev/null)"
  (( rc == 0 )) || status="error"
  record_run "$phase" "$role" "$round" "$status" "$logfile" "$(jq -r '.summary // ""' <<<"${BUILDER_JSON:-null}" 2>/dev/null | head -c 200)" $(( $(date +%s) - t0 ))
  (( rc == 0 )) || die "$role failed in phase $phase (rc=$rc; $(failure_hint "$logfile") — log: $(rel "$logfile"))"
  checkpoint_commit "chore(runner): checkpoint uncommitted work after $(basename "$phase")"
  if [[ "$status" == "blocked" ]]; then
    summary="$(jq -r '.summary // ""' <<<"$BUILDER_JSON")"
    {
      echo "# $(basename "$phase") — builder reported BLOCKED ($(date -u +%FT%TZ))"
      echo
      echo "$summary"
      echo
      echo "## Blockers"
      echo
      jq -r '.blockers // "(none given)"' <<<"$BUILDER_JSON"
    } > "$REVIEWS/$(phase_slug "$phase").blocked.md"
    return 1
  fi
  [[ "$status" == "done" ]] || warn "$role returned no structured report (status=$status) — proceeding to gate and review"
  return 0
}

# run_gate PHASE SLUG ROUND → 0 green / 1 red; sets GATE_LOG
run_gate() {
  GATE_LOG=""
  [[ -n "$GATE_CMD" ]] || return 0
  GATE_LOG="$LOGS/$2.gate.r$3.log"
  local t0; t0=$(date +%s)
  log "Gate (round $3): $GATE_CMD"
  if bash -c "$GATE_CMD" >"$GATE_LOG" 2>&1; then
    record_run "$1" gate "$3" green "" "" $(( $(date +%s) - t0 ))
    log "Gate GREEN"
    return 0
  fi
  record_run "$1" gate "$3" red "" "see $(rel "$GATE_LOG")" $(( $(date +%s) - t0 ))
  warn "Gate RED (log: $(rel "$GATE_LOG"))"
  return 1
}

# run_review PHASE SLUG BASE ROUND → sets VERDICT (PASS|FAIL) and VERDICT_MD; dies on infra failure
run_review() {
  local phase="$1" slug="$2" base="$3" round="$4"
  local logfile="$LOGS/$slug.review.r$round.log" t0 rc json jf mf counts
  t0=$(date +%s)
  log "Reviewer (round $round): fresh read-only context (log: $(rel "$logfile"))"
  run_agent "$logfile" review "$(review_prompt "$phase" "$base" "${GATE_LOG:-}")"; rc=$?
  render_log "$logfile"
  restore_tree "The reviewer"
  json="$(structured_output "$logfile")"
  if (( rc != 0 )) || [[ -z "$json" ]]; then
    record_run "$phase" review "$round" error "$logfile" "rc=$rc, no verdict" $(( $(date +%s) - t0 ))
    die "reviewer failed in phase $phase (rc=$rc; $(failure_hint "$logfile") — log: $(rel "$logfile"))"
  fi
  VERDICT="$(jq -r '.verdict' <<<"$json")"
  jf="$REVIEWS/$slug.r$round.json"; mf="$REVIEWS/$slug.r$round.md"
  jq . <<<"$json" > "$jf"
  jq -r --arg phase "$phase" --arg round "$round" --arg when "$(date -u +%FT%TZ)" -f "$LIB_DIR/verdict.jq" "$jf" > "$mf"
  cp "$jf" "$REVIEWS/$slug.json"; cp "$mf" "$REVIEWS/$slug.md"
  VERDICT_MD="$mf"
  counts="$(jq -r '[.findings[]? | .severity] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' <<<"$json")"
  record_run "$phase" review "$round" "$VERDICT" "$logfile" "${counts:-no findings}" $(( $(date +%s) - t0 ))
  log "Reviewer verdict: $VERDICT ${counts:+($counts)} — $(rel "$mf")"
}

# COMMIT_REVIEWS=1: keep the latest verdict in the repository as well.
publish_review() {  # publish_review SLUG
  [[ "$COMMIT_REVIEWS" == "1" && -f "$REVIEWS/$1.md" ]] || return 0
  mkdir -p "$REVIEWS_DIR"
  cp "$REVIEWS/$1.md" "$REVIEWS_DIR/$1.md"
  git add "$REVIEWS_DIR/$1.md"
  git diff --cached --quiet || git commit -q -m "docs(verification): $1 — ${VERDICT:-review}"
}

# mark_blocked PHASE REASON — records, keeps the work safe (checkpoint + push), stops the run.
mark_blocked() {
  local phase="$1" reason="$2"
  { grep -vF "$phase"$'\t' "$BLOCKED_FILE" 2>/dev/null || true; } > "$BLOCKED_FILE.tmp"
  printf '%s\t%s\n' "$phase" "$(printf '%s' "$reason" | tr '\t\n' '  ')" >> "$BLOCKED_FILE.tmp"
  mv "$BLOCKED_FILE.tmp" "$BLOCKED_FILE"
  checkpoint_commit "chore(runner): checkpoint work after blocked $(basename "$phase")"
  push_branch || warn "push failed — the work is committed locally; fix credentials and re-run"
  die "phase $phase BLOCKED — $reason"
}

unblock() {
  [[ -f "$BLOCKED_FILE" ]] || return 0
  { grep -vF "$1"$'\t' "$BLOCKED_FILE" || true; } > "$BLOCKED_FILE.tmp"
  mv "$BLOCKED_FILE.tmp" "$BLOCKED_FILE"
}

# ── One phase ─────────────────────────────────────────────────────────────────
run_phase() {
  local phase="$1" slug base round=0 reason logfile
  slug="$(phase_slug "$phase")"
  base="$(git rev-parse HEAD)"
  VERDICT=""; VERDICT_MD=""

  logfile="$LOGS/$slug.build.log"
  log "Phase $phase: BUILDER starting (log: $(rel "$logfile"))"
  run_builder "$phase" build 0 "$logfile" "$(build_prompt "$phase")" \
    || mark_blocked "$phase" "builder reported blocked: $(jq -r '.summary // ""' <<<"$BUILDER_JSON" | head -c 300) — see $(rel "$REVIEWS")/$slug.blocked.md"

  while :; do
    if ! run_gate "$phase" "$slug" "$round"; then
      reason="The runner's independent gate command FAILED:"$'\n\n'"    $GATE_CMD"$'\n\n'"Last 60 lines of its output:"$'\n\n'"$(tail -60 "$GATE_LOG")"
    elif [[ "$PHASE_REVIEW" == "1" ]]; then
      run_review "$phase" "$slug" "$base" "$round"
      [[ "$VERDICT" == "PASS" ]] && break
      reason="The independent reviewer returned FAIL. Its verdict (also at $(rel "$VERDICT_MD")):"$'\n\n'"$(cat "$VERDICT_MD")"
    else
      break
    fi

    round=$(( round + 1 ))
    if (( round > MAX_FIX_ROUNDS )); then
      publish_review "$slug"
      mark_blocked "$phase" "still failing after $MAX_FIX_ROUNDS fix round(s) (last: ${VERDICT:-gate red}) — see $(rel "$REVIEWS")/$slug.md"
    fi
    logfile="$LOGS/$slug.fix.r$round.log"
    log "Phase $phase: FIX round $round/$MAX_FIX_ROUNDS — builder with a fresh context (log: $(rel "$logfile"))"
    run_builder "$phase" fix "$round" "$logfile" "$(fix_prompt "$phase" "$round" "${base:0:12}..HEAD" "$reason")" \
      || mark_blocked "$phase" "builder reported blocked in fix round $round: $(jq -r '.summary // ""' <<<"$BUILDER_JSON" | head -c 300)"
  done

  publish_review "$slug"
  unblock "$phase"
  echo "$phase" >> "$DONE_FILE"
  push_branch || die "push to $GIT_REMOTE/$GIT_BRANCH failed 3 times (logs/push.log) — the phase is recorded as done; fix credentials and re-run to push the backlog"
  log "Phase $phase: DONE — verified${GATE_CMD:+, gate green}, committed, pushed"
}

# ── Report-only passes ────────────────────────────────────────────────────────
# report_pass ROLE OUTFILE PROMPT — the agent returns Markdown; the driver writes it.
report_pass() {
  local role="$1" out="$2" prompt="$3" logfile="$LOGS/$1.log" t0 rc json
  t0=$(date +%s)
  log "$role: launching read-only agent (log: $(rel "$logfile"))"
  run_agent "$logfile" "$role" "$prompt"; rc=$?
  render_log "$logfile"
  restore_tree "The $role agent"
  json="$(structured_output "$logfile")"
  if (( rc != 0 )) || [[ -z "$json" ]]; then
    record_run "-" "$role" 0 error "$logfile" "rc=$rc" $(( $(date +%s) - t0 ))
    die "$role agent failed (rc=$rc; $(failure_hint "$logfile") — log: $(rel "$logfile"))"
  fi
  jq -r '.report' <<<"$json" > "$out"
  record_run "-" "$role" 0 ok "$logfile" "wrote $(rel "$out")" $(( $(date +%s) - t0 ))
  log "$role report written to $(rel "$out")"
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "Phase runner ($MODE) in $PROJECT_DIR — branch $GIT_BRANCH, remote $GIT_REMOTE"
log "Phases: ${PHASES[*]}"
log "Builder: model ${BUILD_MODEL:-$CLAUDE_MODEL}, effort ${BUILD_EFFORT:-$CLAUDE_EFFORT}${BUILD_BUDGET_USD:+, budget \$$BUILD_BUDGET_USD} · Reviewer: $(onoff "$PHASE_REVIEW"), model ${REVIEW_MODEL:-$CLAUDE_MODEL}, effort ${REVIEW_EFFORT:-$CLAUDE_EFFORT}${REVIEW_BUDGET_USD:+, budget \$$REVIEW_BUDGET_USD} · fix rounds ≤ $MAX_FIX_ROUNDS · gate: ${GATE_CMD:-none}"
log "Retry schedule: ${SCHEDULE[*]}s; stall timeout: ${STALL_TIMEOUT}s; guard hook: $(onoff "$GUARD")"

case "$MODE" in
  dry-run)
    for p in "${PHASES[@]}"; do
      phase_done "$p" && { log "Phase $p: already done — would skip"; continue; }
      log "DRY RUN — the builder prompt for the first pending phase ($p) follows. No agent is launched."
      echo
      build_prompt "$p"
      exit 0
    done
    log "DRY RUN — every phase is already done; nothing would run."
    exit 0
    ;;
  preflight)
    report_pass preflight "$STATE/TOOLING.md" "$(preflight_prompt)"
    log "Read $(rel "$STATE")/TOOLING.md, provision what it recommends, then run the build."
    exit 0
    ;;
  review)
    report_pass final-review "$STATE/REVIEW.md" "$(final_review_prompt)"
    log "Read $(rel "$STATE")/REVIEW.md and turn the findings you accept into new phase files."
    exit 0
    ;;
  build) ;;
  *) die "unknown RUNNER_MODE: $MODE" ;;
esac

if [[ "$PUSH" == "1" ]] && has_unpushed; then
  log "Unpushed commits from a previous run detected — pushing backlog first"
  push_branch || die "push to $GIT_REMOTE/$GIT_BRANCH failed 3 times (logs/push.log) — fix credentials and re-run"
fi

for phase_file in "${PHASES[@]}"; do
  if phase_done "$phase_file"; then
    log "Phase $phase_file: already completed in a previous run — skipping"
    continue
  fi
  run_phase "$phase_file"
done

log "All phases complete"
write_summary "SUCCESS"
