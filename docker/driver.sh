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
# shellcheck disable=SC2034  # read by record_run in lib/common.sh
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
# One header per start in state/logs/driver.log, so consecutive runs can be
# told apart in a file that is appended to across runs (not on the terminal).
driver_log INFO "=== driver start: mode $MODE, branch $GIT_BRANCH, Claude Code $(claude --version 2>/dev/null | head -1), pid $$"
PUSH="${PUSH:-1}"
GATE_CMD="${GATE_CMD:-}"
GATE_TIMEOUT="${GATE_TIMEOUT:-3600}"   # seconds; the gate is not an agent, so the stall watchdog does not cover it
PHASE_REVIEW="${PHASE_REVIEW:-1}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-2}"
COMMIT_REVIEWS="${COMMIT_REVIEWS:-0}"
REVIEWS_DIR="${REVIEWS_DIR:-docs/verification}"
# fresh = every fix round starts a new context; resume = continue the builder's
# own session (cheaper while its prompt cache is warm, see README "Cost").
FIX_CONTEXT="${FIX_CONTEXT:-fresh}"
# The phases manifest also carries per-phase options (`path model=… effort=…`).
MANIFEST="${RUNNER_MANIFEST:-$PROJECT_DIR/.phase-runner/phases}"
# Per-phase progress markers: a run interrupted after the builder finished
# resumes at the gate instead of paying for the builder again.
PROGRESS="$STATE/progress"
mkdir -p "$PROGRESS"
# 1 = the host Docker socket is mounted (bin/phase-runner decides the mount);
# 0 = no daemon, and the builder is told so instead of hunting for one.
DOCKER_SOCKET="${DOCKER_SOCKET:-1}"
# Model/effort for every role unless runner.env overrides them (BUILD_*/REVIEW_* per role).
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-fable-5-1}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-xhigh}"

[[ -f "$ENTRY_FILE" ]] || die "entry file not found: $ENTRY_FILE (path is relative to the project root)"
for p in "${PHASES[@]}"; do
  [[ -f "$p" ]] || die "phase file not found: $p (paths are relative to the project root)"
done
resolve_bash_settings   # validates explicit BASH_TIMEOUT / BASH_TIMEOUT_MAX / BACKGROUND_TASKS before any agent runs

# Paths the agent may read but never modify (enforced by docker/guard.sh).
# shellcheck disable=SC2034  # read by run_claude in lib/claude.sh, which hands it to the guard
PROTECTED_PATHS="$ENTRY_FILE:$(IFS=:; printf '%s' "${PHASES[*]}"):.phase-runner"
ensure_exclude

phase_done() { grep -qxF "$1" "$DONE_FILE"; }
onoff() { [[ "$1" == "1" ]] && echo on || echo off; }

# Per-phase options from the manifest line `path key=value …`. Sets the PHASE_*
# globals that lib/claude.sh consults before the per-role and global settings.
# Keys: model effort fix_model fix_effort review_model review_effort.
phase_opts() {  # phase_opts PHASE
  PHASE_MODEL=""; PHASE_EFFORT=""; PHASE_FIX_MODEL=""; PHASE_FIX_EFFORT=""; PHASE_REVIEW_MODEL=""; PHASE_REVIEW_EFFORT=""
  [[ -f "$MANIFEST" ]] || return 0
  local opts kv
  opts="$(sed -e 's/#.*//' "$MANIFEST" | awk -v p="$1" '$1 == p { $1 = ""; print; exit }')"
  for kv in $opts; do
    # shellcheck disable=SC2034  # the PHASE_* globals are read by role_model/role_effort in lib/claude.sh
    case "${kv%%=*}" in
      model)         PHASE_MODEL="${kv#*=}" ;;
      effort)        PHASE_EFFORT="${kv#*=}" ;;
      fix_model)     PHASE_FIX_MODEL="${kv#*=}" ;;
      fix_effort)    PHASE_FIX_EFFORT="${kv#*=}" ;;
      review_model)  PHASE_REVIEW_MODEL="${kv#*=}" ;;
      review_effort) PHASE_REVIEW_EFFORT="${kv#*=}" ;;
      *) warn "phases manifest: unknown option '$kv' on $1 — ignored" ;;
    esac
  done
}
roles_desc() { printf 'builder %s · fix %s · reviewer %s' "$(role_desc build)" "$(role_desc fix)" "$(role_desc review)"; }

# progress/<slug>: written after every successful builder or fix run, removed
# when the phase is done or blocked. Keys: base (HEAD before the builder),
# round (last completed fix round), sid (that run's session, for FIX_CONTEXT=resume).
save_progress()  { printf 'base=%s\nround=%s\nsid=%s\n' "$2" "$3" "$4" > "$PROGRESS/$1"; }
clear_progress() { rm -f "$PROGRESS/$1"; }
load_progress()  {  # load_progress SLUG → sets P_BASE P_ROUND P_SID; 1 when absent or unusable
  local f="$PROGRESS/$1"
  [[ -f "$f" ]] || return 1
  P_BASE="$(sed -n 's/^base=//p' "$f")"; P_ROUND="$(sed -n 's/^round=//p' "$f")"; P_SID="$(sed -n 's/^sid=//p' "$f")"
  [[ "$P_ROUND" =~ ^[0-9]+$ ]] && git cat-file -e "$P_BASE^{commit}" 2>/dev/null
}

# ── Prompts ───────────────────────────────────────────────────────────────────
entry_text() { cat "$ENTRY_FILE"; }
rules_text() {
  render_prompt rules ENTRY_FILE="$ENTRY_FILE" BASH_MAX_MINUTES="$(( BASH_TIMEOUT_MAX / 60 ))"
  [[ "$DOCKER_SOCKET" == "1" ]] || { echo; render_prompt no-docker; }
}

build_prompt() {  # build_prompt PHASE
  render_prompt build ENTRY="$(entry_text)" PHASE_FILE="$1" RULES="$(rules_text)"
}

fix_prompt() {  # fix_prompt PHASE ROUND DIFF_RANGE REASON
  render_prompt fix ENTRY="$(entry_text)" PHASE_FILE="$1" ROUND="$2" MAX_ROUNDS="$MAX_FIX_ROUNDS" \
    DIFF_RANGE="$3" REASON="$4" RULES="$(rules_text)"
}

# The lean variant for FIX_CONTEXT=resume: entry file and rules are already in the session.
fix_resume_prompt() {  # fix_resume_prompt PHASE ROUND REASON
  render_prompt fix-resume PHASE_FILE="$1" ROUND="$2" MAX_ROUNDS="$MAX_FIX_ROUNDS" REASON="$3"
}

review_prompt() {  # review_prompt PHASE BASE GATE_LOG
  local commits diffstat gate
  commits="$(git log --oneline "$2..HEAD" 2>/dev/null)"
  [[ -n "$commits" ]] || commits="(no commits — the builder committed nothing in this phase)"
  diffstat="$(git diff --stat "$2..HEAD" 2>/dev/null | tail -40)"
  [[ -n "$diffstat" ]] || diffstat="(empty diff)"
  if [[ -n "$3" && -f "$3" ]]; then
    # The reviewer only runs after a green gate: that run is the runner's own
    # evidence, so the reviewer should not pay to repeat it.
    gate="The runner itself ran the gate command \`$GATE_CMD\` on this exact commit and it passed; last lines of its output:"$'\n\n```\n'"$(tail -40 "$3")"$'\n```\n\n'"That gate run is the runner's own execution, not the builder's claim: take it as proof that the suite is green and do not re-run the whole gate or the full build. Your job is what a green suite cannot prove — that the tests actually test the Definition of Done and that the code is correct."
  else
    gate="No gate command is configured for this project, so nothing has verified the suite yet: run the project's own checks yourself (tests, type check, lint, build — as the entry prompt describes them), once, and treat their output as your evidence."
  fi
  render_prompt review ENTRY="$(entry_text)" PHASE_FILE="$1" DIFF_RANGE="${2:0:12}..HEAD" \
    COMMITS="$commits" DIFFSTAT="$diffstat" GATE_SECTION="$gate" BASH_MAX_MINUTES="$(( BASH_TIMEOUT_MAX / 60 ))"
}

preflight_prompt() {
  render_prompt preflight ENTRY="$(entry_text)" PHASE_LIST="$(printf '  - %s\n' "${PHASES[@]}")"
}

final_review_prompt() {
  local body="${REVIEW_PROMPT:-Make an adversarial evaluation of what can be improved, simplified, and made more resilient. Do it thoroughly.}"
  render_prompt final-review ENTRY="$(entry_text)" REVIEW_BODY="$body" PHASE_LIST="$(printf '  - %s\n' "${PHASES[@]}")"
}

# ── Roles ─────────────────────────────────────────────────────────────────────
# run_builder PHASE ROLE ROUND LOGFILE PROMPT [RESUME_SID] → 0 done, 1 blocked,
# 3 the session to resume is gone (nothing recorded); dies on infra failure
run_builder() {
  local phase="$1" role="$2" round="$3" logfile="$4" prompt="$5" resume="${6:-}"
  local t0 rc status summary
  t0=$(date +%s)
  run_agent "$logfile" "$role" "$prompt" "$resume"; rc=$?
  (( rc == 3 )) && return 3
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

# run_fix PHASE SLUG ROUND LOGFILE REASON BASE → run_builder's result for the fix role.
# FIX_CONTEXT=resume continues the previous builder/fix session (BUILD_SID) and
# falls back to a fresh context when that session no longer exists.
run_fix() {
  local phase="$1" slug="$2" round="$3" logfile="$4" reason="$5" base="$6" rc
  if [[ "$FIX_CONTEXT" == "resume" && -n "${BUILD_SID:-}" ]]; then
    log "Phase $phase: FIX round $round/$MAX_FIX_ROUNDS — resuming the builder's session ${BUILD_SID:0:8} (log: $(rel "$logfile"))"
    run_builder "$phase" fix "$round" "$logfile" "$(fix_resume_prompt "$phase" "$round" "$reason")" "$BUILD_SID"; rc=$?
    (( rc == 3 )) || return "$rc"
    warn "session ${BUILD_SID:0:8} cannot be resumed — running the fix round with a fresh context"
  fi
  log "Phase $phase: FIX round $round/$MAX_FIX_ROUNDS — builder with a fresh context (log: $(rel "$logfile"))"
  run_builder "$phase" fix "$round" "$logfile" "$(fix_prompt "$phase" "$round" "${base:0:12}..HEAD" "$reason")"
}

# run_gate PHASE SLUG ROUND → 0 green / 1 red; sets GATE_LOG
# stdin is /dev/null: the gate is unattended, and a tool that asks a question
# (corepack's download prompt, a "continue? [Y/n]") must fail, not wait forever
# on the driver's terminal. GATE_TIMEOUT caps the whole command.
run_gate() {
  GATE_LOG=""
  [[ -n "$GATE_CMD" ]] || return 0
  GATE_LOG="$LOGS/$2.gate.r$3.log"
  local t0 rc; t0=$(date +%s)
  log "Gate (round $3): $GATE_CMD"
  # The gate executes code the builder just wrote: like the agents, it runs without the SSH agent.
  timeout --kill-after=30 "$GATE_TIMEOUT" env -u SSH_AUTH_SOCK bash -c "$GATE_CMD" >"$GATE_LOG" 2>&1 </dev/null; rc=$?
  if (( rc == 0 )); then
    record_run "$1" gate "$3" green "" "" $(( $(date +%s) - t0 ))
    log "Gate GREEN"
    return 0
  fi
  if (( rc == 124 || rc == 137 )); then
    echo "RUNNER-GATE-TIMEOUT: gate command exceeded GATE_TIMEOUT=${GATE_TIMEOUT}s and was killed (rc=$rc)" >>"$GATE_LOG"
  fi
  record_run "$1" gate "$3" red "" "see $(rel "$GATE_LOG")" $(( $(date +%s) - t0 ))
  warn "Gate RED (rc=$rc, log: $(rel "$GATE_LOG"))"
  return 1
}

# run_review PHASE SLUG BASE ROUND → sets VERDICT (PASS|FAIL) and VERDICT_MD; dies on infra failure
run_review() {
  local phase="$1" slug="$2" base="$3" round="$4"
  local logfile="$LOGS/$slug.review.r$round.log" t0 rc json jf mf counts
  t0=$(date +%s)
  log "Reviewer (round $round): fresh read-only context (log: $(rel "$logfile"))"
  snapshot_tree
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
  clear_progress "$(phase_slug "$phase")"   # a re-run after the human intervenes restarts from the builder prompt
  checkpoint_commit "chore(runner): checkpoint work after blocked $(basename "$phase")"
  push_branch || warn "push failed — the work is committed locally; fix credentials and re-run"
  die "phase $phase BLOCKED — $reason"
}

# blocked_or_verify PHASE SLUG SINCE REASON — a builder said "blocked". With no
# new commits since SINCE that is an honest stop. With commits, the claim is not
# authoritative: builders routinely finish the work, start the test suite in
# the background, report "verification still running" as a blocker and end the
# turn. The gate and the reviewer decide whether the work is done; a genuine
# blocker shows up as a FAIL verdict and, at worst, one more blocked report
# from the fix round with nothing new committed.
blocked_or_verify() {
  local phase="$1" slug="$2" since="$3" reason="$4"
  [[ "$(git rev-parse HEAD)" != "$since" ]] || mark_blocked "$phase" "$reason"
  BLOCKED_NOTE="$(cat "$REVIEWS/$slug.blocked.md" 2>/dev/null || true)"
  warn "builder reported blocked but committed $(git rev-list --count "$since..HEAD") commit(s) — the gate and the reviewer decide, not the builder (its report: $(rel "$REVIEWS")/$slug.blocked.md)"
}

unblock() {
  [[ -f "$BLOCKED_FILE" ]] || return 0
  { grep -vF "$1"$'\t' "$BLOCKED_FILE" || true; } > "$BLOCKED_FILE.tmp"
  mv "$BLOCKED_FILE.tmp" "$BLOCKED_FILE"
}

# ── One phase ─────────────────────────────────────────────────────────────────
run_phase() {
  local phase="$1" slug base round=0 reason logfile head_before
  slug="$(phase_slug "$phase")"
  phase_opts "$phase"
  VERDICT=""; VERDICT_MD=""; BUILD_SID=""; BLOCKED_NOTE=""
  log "Phase $phase: $(roles_desc)"

  if load_progress "$slug"; then
    base="$P_BASE"; round="$P_ROUND"; BUILD_SID="$P_SID"
    log "Phase $phase: the builder already finished in an earlier run (base ${base:0:12}, round $round) — skipping straight to gate and review"
    checkpoint_commit "chore(runner): checkpoint work left by an interrupted run of $(basename "$phase")"
  else
    base="$(git rev-parse HEAD)"
    logfile="$LOGS/$slug.build.log"
    log "Phase $phase: BUILDER starting (log: $(rel "$logfile"))"
    run_builder "$phase" build 0 "$logfile" "$(build_prompt "$phase")" \
      || blocked_or_verify "$phase" "$slug" "$base" "builder reported blocked: $(jq -r '.summary // ""' <<<"$BUILDER_JSON" | head -c 300) — see $(rel "$REVIEWS")/$slug.blocked.md"
    BUILD_SID="$LAST_SESSION_ID"
    save_progress "$slug" "$base" 0 "$BUILD_SID"
  fi

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
    if [[ -n "${BLOCKED_NOTE:-}" ]]; then
      reason+=$'\n\n'"The previous builder ended its run reporting itself blocked. Its report follows; treat its claims as claims, not findings:"$'\n\n'"$BLOCKED_NOTE"
      BLOCKED_NOTE=""
    fi

    round=$(( round + 1 ))
    if (( round > MAX_FIX_ROUNDS )); then
      publish_review "$slug"
      mark_blocked "$phase" "still failing after $MAX_FIX_ROUNDS fix round(s) (last: ${VERDICT:-gate red}) — see $(rel "$REVIEWS")/$slug.md"
    fi
    logfile="$LOGS/$slug.fix.r$round.log"
    head_before="$(git rev-parse HEAD)"
    run_fix "$phase" "$slug" "$round" "$logfile" "$reason" "$base" \
      || blocked_or_verify "$phase" "$slug" "$head_before" "builder reported blocked in fix round $round: $(jq -r '.summary // ""' <<<"$BUILDER_JSON" | head -c 300)"
    BUILD_SID="$LAST_SESSION_ID"
    save_progress "$slug" "$base" "$round" "$BUILD_SID"
  done

  publish_review "$slug"
  unblock "$phase"
  clear_progress "$slug"
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
  snapshot_tree
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

# ── Push access ───────────────────────────────────────────────────────────────
# The runner, not the agent, holds the push credentials, so the runner checks
# them: one read-only contact with the push remote before the first agent is
# launched turns "push failed 3 times" after the first phase into a warning in
# the first minute. Only a warning — the work is committed locally either way
# and the next run pushes the backlog.
check_push_access() {
  [[ "$PUSH" == "1" ]] || return 0
  case "$MODE" in build|preflight) ;; *) return 0 ;; esac
  local url
  url="$(git remote get-url "$GIT_REMOTE" 2>/dev/null || echo "?")"
  # Under `docker compose run` the driver has a terminal, and a remote without
  # usable credentials would sit on git's `Username for …` prompt until the
  # cap kills it: prompts off and stdin closed (as for the gate), so git fails
  # at once and push.log holds its own error.
  if GIT_TERMINAL_PROMPT=0 timeout --kill-after=10 30 git ls-remote "$GIT_REMOTE" HEAD >>"$LOGS/push.log" 2>&1 </dev/null; then
    log "Push remote $GIT_REMOTE ($url) is reachable"
  else
    warn "Push remote $GIT_REMOTE ($url) is NOT reachable (logs/push.log) — pushing will fail. Usual causes: no SSH agent forwarded (eval \$(ssh-agent); ssh-add on the host) or a bad token in an HTTPS remote URL. The run continues: work is committed locally and the next run pushes the backlog."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "Phase runner ($MODE) in $PROJECT_DIR — branch $GIT_BRANCH, remote $GIT_REMOTE"
log "Phases: ${PHASES[*]}"
log "Builder: $(role_desc build)${BUILD_BUDGET_USD:+, budget \$$BUILD_BUDGET_USD} · Fix rounds (≤ $MAX_FIX_ROUNDS, $FIX_CONTEXT context): $(role_desc fix) · Reviewer: $(onoff "$PHASE_REVIEW"), $(role_desc review)${REVIEW_BUDGET_USD:+, budget \$$REVIEW_BUDGET_USD} · gate: ${GATE_CMD:-none}"
log "Subagents: ${SUBAGENT_MODEL:-inherit the parent model} · inline Bash output ≤ ${BASH_OUTPUT_MAX_CHARS:-30000 (Claude Code default)} chars · per-phase overrides: $([[ -f "$MANIFEST" ]] && echo "$(rel "$MANIFEST")" || echo none)"
log "Retry schedule: ${SCHEDULE[*]}s; stall timeout: ${STALL_TIMEOUT}s; guard hook: $(onoff "$GUARD"); docker socket: $(onoff "$DOCKER_SOCKET")"
log "Bash tool: default timeout ${BASH_TIMEOUT}s, maximum ${BASH_TIMEOUT_MAX}s; background tasks: $(onoff "$BACKGROUND_TASKS")"
check_push_access

case "$MODE" in
  dry-run)
    for p in "${PHASES[@]}"; do
      phase_done "$p" && { log "Phase $p: already done — would skip"; continue; }
      phase_opts "$p"
      log "Phase $p: $(roles_desc)"
      load_progress "$(phase_slug "$p")" && log "Phase $p: builder already finished (progress marker) — a real run would skip straight to gate and review"
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
