#!/usr/bin/env bash
# Driver + CLI tests without Docker or tokens: a fake `claude` on PATH plays
# the builder and the reviewer according to a per-scenario plan.
#   bash tests/run.sh            # all scenarios + guard tests
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/phase-runner-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; CURRENT=""

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗ %s: %s\033[0m\n' "$CURRENT" "$*"; }
assert_eq()       { [[ "$1" == "$2" ]] && ok || bad "${3:-} expected '$2', got '$1'"; }
assert_file()     { [[ -e "$1" ]] && ok || bad "missing: $1"; }
assert_no_file()  { [[ ! -e "$1" ]] && ok || bad "should not exist: $1"; }
assert_grep()     { grep -qE -- "$1" "$2" 2>/dev/null && ok || bad "'$1' not found in ${2#"$TMP"/}"; }
assert_not_grep() { if grep -qE -- "$1" "$2" 2>/dev/null; then bad "'$1' unexpectedly in ${2#"$TMP"/}"; else ok; fi; }
scenario() { CURRENT="$1"; printf '\033[1;34m▶ %s\033[0m\n' "$1"; }

new_project() {
  local d="$TMP/proj-$1"
  mkdir -p "$d/plan"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.local
  git -C "$d" config user.name T
  printf '# Entry\n\nBe good. Verify with `pnpm test && pnpm lint`.\n' > "$d/plan/ENTRY.md"
  printf '# Phase A\n\n## Definition of Done\n\n- [ ] A works\n' > "$d/plan/A.md"
  printf '# Phase B\n\n## Definition of Done\n\n- [ ] B works\n' > "$d/plan/B.md"
  git -C "$d" add -A && git -C "$d" commit -q -m init
  echo "$d"
}

# run_driver PROJECT PLAN_LINE... → RC, OUT (driver output), FAKE (fake-claude records), STATE
run_driver() {
  local proj="$1"; shift
  local plan="$TMP/plan-$RANDOM$RANDOM"
  printf '%s\n' "$@" > "$plan"
  FAKE="$TMP/fake-$RANDOM$RANDOM"
  OUT="$TMP/out-$RANDOM$RANDOM.log"
  STATE="$proj/.phase-runner/state"
  ( cd "$proj" && \
    PATH="$KIT/tests/bin:$PATH" FAKE_PLAN="$plan" FAKE_LOG="$FAKE" \
    PHASE_RUNNER_HOME="$KIT" PROJECT_DIR="$proj" ENTRY_FILE=plan/ENTRY.md \
    PHASE_FILES="${PHASE_FILES:-plan/A.md}" PUSH=0 RETRY_SCHEDULE="${RETRY_SCHEDULE:-0}" \
    STALL_TIMEOUT="${STALL_TIMEOUT:-600}" STALL_POLL="${STALL_POLL:-1}" GATE_CMD="${GATE_CMD-true}" \
    GUARD=0 RUNNER_MODE="${RUNNER_MODE:-build}" PHASE_REVIEW="${PHASE_REVIEW:-1}" \
    MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-2}" COMMIT_REVIEWS="${COMMIT_REVIEWS:-0}" \
    bash "$KIT/docker/driver.sh" >"$OUT" 2>&1 )
  RC=$?
}
invocations() { find "$FAKE" -name '*.args' 2>/dev/null | wc -l; }
arg_after() {  # arg_after N FLAG → the value following FLAG in invocation N
  awk -v f="$2" '$0 == f { getline; print; exit }' "$FAKE/$1.args"
}

# ── Scenarios ────────────────────────────────────────────────────────────────
scenario "happy path: build → gate → review PASS"
p="$(new_project happy)"
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_eq "$(invocations)" 2 "invocations"
assert_eq "$(cat "$FAKE/1.role")" build "role 1"
assert_eq "$(cat "$FAKE/2.role")" review "role 2"
assert_grep 'Be good' "$FAKE/1.prompt"
assert_grep 'BUILDER for exactly one phase: `plan/A.md`' "$FAKE/1.prompt"
assert_grep 'INDEPENDENT REVIEWER' "$FAKE/2.prompt"
assert_grep 'fake work 1' "$FAKE/2.prompt"
assert_grep 'pnpm test && pnpm lint' "$FAKE/2.prompt"
assert_grep '--json-schema' "$FAKE/1.args"
assert_grep '--disallowedTools' "$FAKE/2.args"
assert_not_grep '--disallowedTools' "$FAKE/1.args"
assert_grep '--session-id' "$FAKE/1.args"
assert_eq "$(arg_after 1 --model)" claude-fable-5-1 "default builder model"
assert_eq "$(arg_after 1 --effort)" xhigh "default builder effort"
assert_eq "$(arg_after 2 --model)" claude-fable-5-1 "default reviewer model"
assert_eq "$(arg_after 2 --effort)" xhigh "default reviewer effort"
assert_grep 'Builder: model claude-fable-5-1, effort xhigh' "$OUT"
assert_file "$STATE/reviews/A.md.md"
assert_grep 'Review — plan/A.md — PASS' "$STATE/reviews/A.md.md"
assert_file "$STATE/logs/A.md.build.txt"
assert_grep 'Working on A' "$STATE/logs/A.md.build.txt"
assert_grep $'\tbuild\t0\tdone\t' "$STATE/runs.tsv"
assert_grep $'\tgate\t0\tgreen\t' "$STATE/runs.tsv"
assert_grep $'\treview\t0\tPASS\t' "$STATE/runs.tsv"
assert_grep 'SUCCESS' "$STATE/SUMMARY.md"
assert_grep '^\.phase-runner/$' "$p/.git/info/exclude"
assert_eq "$(git -C "$p" status --porcelain)" "" "tree clean (state excluded)"
assert_file "$p/built-A.txt"

scenario "review FAIL → fix round → PASS"
p="$(new_project fixpass)"
run_driver "$p" build:ok review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_eq "$(invocations)" 4 "invocations"
assert_eq "$(cat "$FAKE/3.role")" fix "role 3"
assert_grep 'fix round 1 of 2' "$FAKE/3.prompt"
assert_grep 'MARKER-FINDING-2' "$FAKE/3.prompt"
assert_grep 'src/a.ts:3' "$FAKE/3.prompt"
assert_grep 'FAIL' "$STATE/reviews/A.md.r0.md"
assert_grep 'PASS' "$STATE/reviews/A.md.r1.md"
assert_grep 'Review — plan/A.md — PASS' "$STATE/reviews/A.md.md"
assert_grep $'\tfix\t1\tdone\t' "$STATE/runs.tsv"
assert_grep $'\treview\t0\tFAIL\t.*\thigh 1$' "$STATE/runs.tsv"
FIXPASS_PROJECT="$p"

scenario "fix rounds exhausted → blocked"
p="$(new_project exhausted)"
run_driver "$p" build:ok review:FAIL fix:ok review:FAIL fix:ok review:FAIL
assert_eq "$RC" 1 "rc"
assert_not_grep 'plan/A.md' "$STATE/phases-done"
assert_grep $'^plan/A.md\t.*2 fix round' "$STATE/blocked"
assert_eq "$(invocations)" 6 "invocations"
assert_grep 'BLOCKED' "$OUT"
assert_grep 'FAILED' "$STATE/SUMMARY.md"
assert_grep 'Blocked:' "$STATE/SUMMARY.md"

scenario "gate red → fix → gate green → review PASS"
p="$(new_project gate)"
GATE_CMD="test -f gate-ok" run_driver "$p" build:ok fix:gatefix review:PASS
assert_eq "$RC" 0 "rc"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_grep 'gate command FAILED' "$FAKE/2.prompt"
assert_grep 'test -f gate-ok' "$FAKE/2.prompt"
assert_file "$STATE/logs/A.md.gate.r0.log"
assert_file "$STATE/logs/A.md.gate.r1.log"
assert_grep $'\tgate\t0\tred\t' "$STATE/runs.tsv"
assert_grep $'\tgate\t1\tgreen\t' "$STATE/runs.tsv"

scenario "gate never waits on stdin and is killed by GATE_TIMEOUT"
p="$(new_project gatestdin)"
GATE_CMD='read -r x && echo "got: $x"' PHASE_REVIEW=0 MAX_FIX_ROUNDS=0 run_driver "$p" build:ok
assert_eq "$RC" 1 "rc"
assert_grep $'\tgate\t0\tred\t' "$STATE/runs.tsv"
p="$(new_project gatetimeout)"
GATE_CMD='sleep 30' GATE_TIMEOUT=1 PHASE_REVIEW=0 MAX_FIX_ROUNDS=0 run_driver "$p" build:ok
assert_eq "$RC" 1 "rc"
assert_grep 'RUNNER-GATE-TIMEOUT' "$STATE/logs/A.md.gate.r0.log"
assert_grep $'\tgate\t0\tred\t' "$STATE/runs.tsv"

p="$(new_project gateblocked)"
GATE_CMD="false" PHASE_REVIEW=0 MAX_FIX_ROUNDS=1 run_driver "$p" build:ok fix:ok
assert_eq "$RC" 1 "rc"
assert_grep $'^plan/A.md\t' "$STATE/blocked"
assert_eq "$(invocations)" 2 "invocations"

scenario "transient API error → retry resumes the same session"
p="$(new_project transient)"
run_driver "$p" build:transient build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_eq "$(invocations)" 3 "invocations"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep 'interrupted' "$FAKE/2.prompt"
assert_grep 'Transient API failure' "$OUT"
assert_grep $'\tbuild\t0\tdone\t[0-9]*\t0.8\t5\t' "$STATE/runs.tsv"   # resumed session: last result per session, not a sum (0.3 + 0.8)

scenario "stall → watchdog kill → retry"
p="$(new_project stall)"
STALL_TIMEOUT=2 STALL_POLL=1 run_driver "$p" build:stall build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep 'RUNNER-STALL' "$STATE/logs/A.md.build.log"
assert_grep '^plan/A.md$' "$STATE/phases-done"

scenario "resume fails (no session) → fresh restart with a new session id"
p="$(new_project nosession)"
RETRY_SCHEDULE="0 0" run_driver "$p" build:transient build:nosession build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 4 "invocations"
assert_grep '--session-id' "$FAKE/3.args"
[[ "$(arg_after 3 --session-id)" != "$(arg_after 1 --session-id)" ]] && ok || bad "fresh restart reused the session id"
assert_grep 'BUILDER for exactly one phase' "$FAKE/3.prompt"

scenario "non-transient failure is not retried"
p="$(new_project fatal)"
run_driver "$p" build:fatal
assert_eq "$RC" 1 "rc"
assert_eq "$(invocations)" 1 "invocations"
assert_grep 'not a transient API error' "$OUT"
assert_grep 'FAILED' "$STATE/SUMMARY.md"

scenario "builder reports blocked → run stops, work checkpointed"
p="$(new_project blocked)"
run_driver "$p" build:blocked
assert_eq "$RC" 1 "rc"
assert_eq "$(invocations)" 1 "invocations (no review of a blocked build)"
assert_grep $'^plan/A.md\tbuilder reported blocked' "$STATE/blocked"
assert_grep 'MARKER-BLOCKER' "$STATE/reviews/A.md.blocked.md"
assert_not_grep 'plan/A.md' "$STATE/phases-done"

scenario "builder reports blocked but committed work → gate and review decide"
p="$(new_project blockedwork)"
run_driver "$p" build:blockedwork review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 2 "invocations (review ran)"
assert_grep 'the gate and the reviewer decide' "$OUT"
assert_grep 'MARKER-BLOCKER' "$STATE/reviews/A.md.blocked.md"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_not_grep 'plan/A.md' "$STATE/blocked"
p="$(new_project blockedworkfail)"
run_driver "$p" build:blockedwork review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep 'reporting itself blocked' "$FAKE/3.prompt"
assert_grep 'MARKER-BLOCKER' "$FAKE/3.prompt"
assert_not_grep 'MARKER-BLOCKER' "$FAKE/2.prompt"
p="$(new_project fixblockedwork)"
MAX_FIX_ROUNDS=1 run_driver "$p" build:ok review:FAIL fix:blockedwork review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 4 "invocations"
p="$(new_project fixblockednowork)"
run_driver "$p" build:ok review:FAIL fix:blocked
assert_eq "$RC" 1 "rc"
assert_grep $'^plan/A.md\tbuilder reported blocked in fix round 1' "$STATE/blocked"

scenario "resume skips completed phases"
p="$(new_project resume)"
mkdir -p "$p/.phase-runner/state" && echo plan/A.md > "$p/.phase-runner/state/phases-done"
run_driver "$p"
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 0 "invocations"
assert_grep 'already completed' "$OUT"

scenario "dry run prints the builder prompt and launches nothing"
p="$(new_project dryrun)"
RUNNER_MODE=dry-run run_driver "$p"
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 0 "invocations"
assert_grep 'DRY RUN' "$OUT"
assert_grep 'BUILDER for exactly one phase: `plan/A.md`' "$OUT"
assert_grep 'Be good' "$OUT"
assert_grep 'Phase plan/A.md: builder model claude-fable-5-1, effort xhigh · fix model claude-fable-5-1, effort xhigh · reviewer model claude-fable-5-1, effort xhigh' "$OUT"

scenario "model/effort: CLAUDE_* for every role, BUILD_*/FIX_*/REVIEW_* per role, subagent model, output cap"
p="$(new_project models)"
CLAUDE_MODEL=claude-opus-5 CLAUDE_EFFORT=high BUILD_MODEL=claude-sonnet-5 REVIEW_EFFORT=max FIX_EFFORT=xhigh \
  SUBAGENT_MODEL=claude-haiku-4-5 BASH_OUTPUT_MAX_CHARS=16000 \
  run_driver "$p" build:ok review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(arg_after 1 --model)" claude-sonnet-5 "builder model override"
assert_eq "$(arg_after 1 --effort)" high "builder effort from CLAUDE_EFFORT"
assert_eq "$(arg_after 2 --model)" claude-opus-5 "reviewer model from CLAUDE_MODEL"
assert_eq "$(arg_after 2 --effort)" max "reviewer effort override"
assert_eq "$(arg_after 3 --model)" claude-sonnet-5 "fix inherits the builder's model"
assert_eq "$(arg_after 3 --effort)" xhigh "fix effort override"
assert_grep '^CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-4-5$' "$FAKE/1.env"
assert_grep '^CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-4-5$' "$FAKE/2.env"
assert_eq "$(arg_after 1 --settings | jq -c .)" '{"bashOutputMaxChars":16000}' "settings carry the inline output cap (guard off)"
assert_grep 'Fix rounds .*model claude-sonnet-5, effort xhigh' "$OUT"
assert_grep 'Subagents: claude-haiku-4-5' "$OUT"

scenario "no subagent model configured → nothing forced on the agent"
p="$(new_project nosub)"
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_not_grep 'CLAUDE_CODE_SUBAGENT_MODEL' "$FAKE/1.env"
assert_not_grep -- '--settings' "$FAKE/1.args"

scenario "DOCKER_SOCKET=0 → builder and fix rounds are told there is no Docker daemon; the default says nothing"
p="$(new_project nodocker)"
DOCKER_SOCKET=0 run_driver "$p" build:ok review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep 'No Docker in this run' "$FAKE/1.prompt"
assert_grep 'report `blocked` and say the phase needs `DOCKER_SOCKET=1`' "$FAKE/1.prompt"
assert_grep 'No Docker in this run' "$FAKE/3.prompt"
assert_grep 'docker socket: off' "$OUT"
p="$(new_project dockerdefault)"
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc (default)"
assert_not_grep 'No Docker in this run' "$FAKE/1.prompt"
assert_grep 'docker socket: on' "$OUT"

scenario "per-phase options in the manifest override runner.env for that phase"
p="$(new_project phaseopts)"
mkdir -p "$p/.phase-runner"
printf '# plan\nplan/A.md  model=claude-sonnet-5 effort=medium review_effort=high fix_effort=xhigh bogus=1  # trailing\nplan/B.md\n' > "$p/.phase-runner/phases"
PHASE_FILES="plan/A.md plan/B.md" run_driver "$p" build:ok review:FAIL fix:ok review:PASS build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(arg_after 1 --model)" claude-sonnet-5 "phase A builder model"
assert_eq "$(arg_after 1 --effort)" medium "phase A builder effort"
assert_eq "$(arg_after 2 --model)" claude-fable-5-1 "phase A reviewer keeps the default model"
assert_eq "$(arg_after 2 --effort)" high "phase A reviewer effort"
assert_eq "$(arg_after 3 --model)" claude-sonnet-5 "phase A fix inherits the phase model"
assert_eq "$(arg_after 3 --effort)" xhigh "phase A fix effort"
assert_eq "$(arg_after 5 --model)" claude-fable-5-1 "phase B builder back to defaults"
assert_eq "$(arg_after 5 --effort)" xhigh "phase B builder effort back to defaults"
assert_grep "unknown option 'bogus=1'" "$OUT"
assert_grep 'Phase plan/A.md: builder model claude-sonnet-5, effort medium' "$OUT"
# the host CLI hands the driver paths only
assert_eq "$( (source <(sed -n '/^read_manifest()/,/^}/p' "$KIT/bin/phase-runner"); read_manifest "$p/.phase-runner/phases") )" "plan/A.md plan/B.md" "read_manifest strips options"

scenario "interrupted after the builder finished → re-run skips the builder, goes to gate + review"
p="$(new_project interrupted)"
run_driver "$p" build:ok            # the reviewer finds the fake plan exhausted → the driver dies mid-phase
assert_eq "$RC" 1 "rc of the interrupted run"
assert_grep '^base=[0-9a-f]{40}$' "$STATE/progress/A.md"
assert_grep '^round=0$' "$STATE/progress/A.md"
assert_not_grep 'plan/A.md' "$STATE/phases-done"
echo "half-done edit" > "$p/inflight.txt"          # work the crash left uncommitted
run_driver "$p" review:PASS
assert_eq "$RC" 0 "rc of the resumed run"
assert_eq "$(invocations)" 1 "only the reviewer runs"
assert_eq "$(cat "$FAKE/1.role")" review "role"
assert_grep 'skipping straight to gate and review' "$OUT"
assert_grep 'fake work 1' "$FAKE/1.prompt"       # the reviewer still sees the original builder commits
assert_grep 'checkpoint work left by an interrupted run' <(git -C "$p" log --oneline)
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_no_file "$STATE/progress/A.md"

scenario "blocked phase clears the progress marker → re-run restarts from the builder prompt"
p="$(new_project blockedprogress)"
MAX_FIX_ROUNDS=0 run_driver "$p" build:ok review:FAIL
assert_eq "$RC" 1 "rc"
assert_no_file "$STATE/progress/A.md"

scenario "usage limit → wait for the window to reset, resume the same session"
p="$(new_project limit)"
LIMIT_WAIT_GRACE=0 run_driver "$p" build:limit build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Usage limit reached' "$OUT"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep '^plan/A.md$' "$STATE/phases-done"

scenario "out of usage credits is an honest stop, not a retry"
p="$(new_project nocredits)"
run_driver "$p" build:nocredits
assert_eq "$RC" 1 "rc"
assert_eq "$(invocations)" 1 "invocations"
assert_grep 'out of usage credits' "$OUT"
assert_not_grep 'Usage limit reached' "$OUT"

scenario "FIX_CONTEXT=resume continues the builder's own session with the lean prompt"
p="$(new_project fixresume)"
FIX_CONTEXT=resume run_driver "$p" build:ok review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 4 "invocations"
assert_eq "$(arg_after 3 --resume)" "$(arg_after 1 --session-id)" "fix resumes the builder session"
assert_grep 'continuing in your own session' "$FAKE/3.prompt"
assert_grep 'MARKER-FINDING-2' "$FAKE/3.prompt"
assert_not_grep 'Be good' "$FAKE/3.prompt"        # entry file is already in the session
assert_grep "resuming the builder's session" "$OUT"
assert_grep $'\tfix\t1\tdone\t' "$STATE/runs.tsv"

scenario "FIX_CONTEXT=resume falls back to a fresh context when the session is gone"
p="$(new_project fixresumegone)"
FIX_CONTEXT=resume run_driver "$p" build:ok review:FAIL fix:nosession fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 5 "invocations"
assert_grep 'cannot be resumed' "$OUT"
assert_grep '--session-id' "$FAKE/4.args"
assert_grep 'fix round 1 of 2' "$FAKE/4.prompt"
assert_grep 'Be good' "$FAKE/4.prompt"
assert_eq "$(grep -c $'\tfix\t' "$STATE/runs.tsv")" 1 "the failed resume attempt is not recorded as a run"

scenario "reviewer prompt: gate evidence when a gate ran, own checks when none is configured"
p="$(new_project gateprompt)"
run_driver "$p" build:ok review:PASS
assert_grep 'ran the gate command `true` on this exact commit and it passed' "$FAKE/2.prompt"
assert_grep 'do not re-run the whole gate' "$FAKE/2.prompt"
p="$(new_project nogateprompt)"
GATE_CMD= run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep 'No gate command is configured' "$FAKE/2.prompt"
assert_not_grep 'and it passed' "$FAKE/2.prompt"

scenario "reviewer disabled → gate only"
p="$(new_project noreview)"
PHASE_REVIEW=0 run_driver "$p" build:ok
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 1 "invocations"
assert_grep '^plan/A.md$' "$STATE/phases-done"

scenario "two phases in order"
p="$(new_project two)"
PHASE_FILES="plan/A.md plan/B.md" run_driver "$p" build:ok review:PASS build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(cat "$STATE/phases-done" | tr '\n' ' ')" "plan/A.md plan/B.md " "order"
assert_file "$p/built-A.txt"
assert_file "$p/built-B.txt"
assert_grep 'plan/B.md' "$FAKE/3.prompt"

scenario "COMMIT_REVIEWS=1 commits the verdict into the repo"
p="$(new_project commitreviews)"
COMMIT_REVIEWS=1 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_file "$p/docs/verification/A.md.md"
assert_grep 'docs\(verification\): A.md — PASS' <(git -C "$p" log --oneline)
assert_eq "$(git -C "$p" status --porcelain)" "" "tree clean"

scenario "reviewer leaves files → discarded, phase still passes"
p="$(new_project dirty)"
run_driver "$p" build:ok review:dirty
assert_eq "$RC" 0 "rc"
assert_no_file "$p/stray-from-reviewer.txt"
assert_grep 'left changes in the working tree' "$OUT"
assert_grep '^plan/A.md$' "$STATE/phases-done"

scenario "builder leaves uncommitted work → checkpoint commit"
p="$(new_project leftover)"
run_driver "$p" build:uncommitted review:PASS
assert_eq "$RC" 0 "rc"
assert_grep 'checkpoint uncommitted work after A.md' <(git -C "$p" log --oneline)
assert_eq "$(git -C "$p" status --porcelain)" "" "tree clean"

scenario "builder returns no structured report → still gated and reviewed"
p="$(new_project noreport)"
run_driver "$p" build:noreport review:PASS
assert_eq "$RC" 0 "rc"
assert_grep 'no structured report' "$OUT"
assert_grep '^plan/A.md$' "$STATE/phases-done"

scenario "preflight writes TOOLING.md from the agent's report"
p="$(new_project preflight)"
RUNNER_MODE=preflight run_driver "$p" preflight:ok
assert_eq "$RC" 0 "rc"
assert_grep 'MARKER-REPORT' "$STATE/TOOLING.md"
assert_grep 'plan/A.md' "$FAKE/1.prompt"
assert_grep '--disallowedTools' "$FAKE/1.args"

scenario "read-only pass discards only what it added, keeps pre-existing uncommitted work"
p="$(new_project preflightdirty)"
echo "in-flight spec" > "$p/untracked-from-builder.spec.ts"
echo "in-flight edit" >> "$p/plan/A.md"
RUNNER_MODE=preflight run_driver "$p" preflight:dirty
assert_eq "$RC" 0 "rc"
assert_file "$p/untracked-from-builder.spec.ts"
assert_grep 'in-flight edit' "$p/plan/A.md"
assert_no_file "$p/stray-from-preflight.txt"
assert_not_grep 'edited by preflight' "$p/plan/ENTRY.md"
assert_grep 'stray-from-preflight.txt' "$OUT"
assert_not_grep 'untracked-from-builder' "$OUT"

scenario "final review writes REVIEW.md"
p="$(new_project finalreview)"
RUNNER_MODE=review run_driver "$p" final-review:ok
assert_eq "$RC" 0 "rc"
assert_grep 'MARKER-REPORT' "$STATE/REVIEW.md"
assert_grep 'FINAL ADVERSARIAL REVIEW' "$FAKE/1.prompt"

scenario "host CLI: init, status, logs (no docker)"
p="$(new_project cli)"
out="$(bash "$KIT/bin/phase-runner" --project "$p" init 2>&1)"; rc=$?
assert_eq "$rc" 0 "init rc"
assert_file "$p/.phase-runner/runner.env"
assert_file "$p/.phase-runner/phases"
assert_grep '^\.phase-runner/$' "$p/.git/info/exclude"
# status/logs against the fix-then-pass project
printf 'plan/A.md\n# comment\n\nplan/B.md   # trailing\n' > "$FIXPASS_PROJECT/.phase-runner/phases"
cp "$KIT/templates/runner.env" "$FIXPASS_PROJECT/.phase-runner/runner.env"
st="$(bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" status 2>&1)"; rc=$?
assert_eq "$rc" 0 "status rc"
grep -qE '^plan/A.md +done +PASS +1 +[0-9.]+ +[0-9]+' <<<"$st" && ok || bad "status row for A: $st"
grep -qE '^plan/B.md +pending' <<<"$st" && ok || bad "status row for B"
grep -q 'Agent cost so far' <<<"$st" && ok || bad "status totals"
lg="$(bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" logs A.md.fix 2>&1)"; rc=$?
assert_eq "$rc" 0 "logs rc"
grep -q 'Working on A' <<<"$lg" && ok || bad "logs render"
lg="$(bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" logs A.md.gate 2>&1)"; rc=$?
assert_eq "$rc" 0 "gate log rc"
out="$(bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" reset --yes 2>&1)"; rc=$?
assert_eq "$rc" 0 "reset rc"
assert_no_file "$FIXPASS_PROJECT/.phase-runner/state"
assert_file "$FIXPASS_PROJECT/.phase-runner/runner.env"
out="$(bash "$KIT/bin/phase-runner" --project "$p" bogus 2>&1)"; rc=$?
assert_eq "$rc" 1 "unknown command rc"

scenario "host CLI: DOCKER_SOCKET decides whether the host Docker socket is mounted (fake docker)"
p="$(new_project clidocker)"
mkdir -p "$p/.phase-runner" "$TMP/fakedocker"
printf 'plan/A.md\n' > "$p/.phase-runner/phases"
printf 'ANTHROPIC_API_KEY=test\n' > "$TMP/creds.env"
cat > "$TMP/fakedocker/docker" <<'EOF'
#!/usr/bin/env bash
# Stands in for docker: records every call and, for `compose … run`, the two
# variables docker-compose.yml interpolates for the socket.
printf '%s\n' "$*" >> "$FAKE_DOCKER/calls"
if [[ " $* " == *" run "* ]]; then
  printf '%s\n' "${HOST_DOCKER_SOCK-unset}" > "$FAKE_DOCKER/sock"
  printf '%s\n' "${DOCKER_SOCKET-unset}" > "$FAKE_DOCKER/setting"
fi
exit 0
EOF
chmod +x "$TMP/fakedocker/docker"
cli_run() {  # cli_run [RUNNER_ENV_LINE...] → RC, OUT, FAKE_DOCKER (calls, sock, setting)
  printf '%s\n' 'ENTRY_FILE=plan/ENTRY.md' 'PUSH=0' "$@" > "$p/.phase-runner/runner.env"
  FAKE_DOCKER="$TMP/fakedocker-$RANDOM$RANDOM"; mkdir -p "$FAKE_DOCKER"
  OUT="$TMP/out-$RANDOM$RANDOM.log"
  env -u DOCKER_SOCKET PATH="$TMP/fakedocker:$PATH" FAKE_DOCKER="$FAKE_DOCKER" \
    PHASE_RUNNER_CREDENTIALS="$TMP/creds.env" \
    bash "$KIT/bin/phase-runner" --project "$p" build --dry-run >"$OUT" 2>&1 </dev/null
  RC=$?
}
cli_run
assert_eq "$RC" 0 "rc (unset)"
assert_eq "$(cat "$FAKE_DOCKER/sock" 2>/dev/null)" /var/run/docker.sock "unset keeps the socket (projects that predate the setting)"
assert_eq "$(cat "$FAKE_DOCKER/setting" 2>/dev/null)" 1 "the container is told (unset)"
assert_grep 'Docker: +host socket mounted' "$OUT"
cli_run DOCKER_SOCKET=1
assert_eq "$(cat "$FAKE_DOCKER/sock" 2>/dev/null)" /var/run/docker.sock "DOCKER_SOCKET=1"
cli_run DOCKER_SOCKET=0
assert_eq "$RC" 0 "rc (0)"
assert_eq "$(cat "$FAKE_DOCKER/sock" 2>/dev/null)" /dev/null "DOCKER_SOCKET=0 mounts /dev/null in the socket's place"
assert_eq "$(cat "$FAKE_DOCKER/setting" 2>/dev/null)" 0 "the container is told (0)"
assert_grep 'Docker: +no host socket' "$OUT"
cli_run DOCKER_SOCKET=yes
assert_eq "$RC" 1 "rc (invalid value)"
assert_grep 'DOCKER_SOCKET must be 0 or 1' "$OUT"
assert_no_file "$FAKE_DOCKER/calls"
# The wiring the fake cannot see: compose mounts what the CLI computed and
# never the socket unconditionally; new projects start without it.
assert_grep '^ +- \$\{HOST_DOCKER_SOCK:-/dev/null\}:/var/run/docker\.sock$' "$KIT/docker-compose.yml"
assert_not_grep '^ +- /var/run/docker\.sock:' "$KIT/docker-compose.yml"
assert_grep '^DOCKER_SOCKET=0$' "$KIT/templates/runner.env"

scenario "prompt rendering keeps && and $ literal"
p="$(new_project render)"
printf 'Gate: `a && b` costs $5 & more\n' > "$p/plan/ENTRY.md"
git -C "$p" commit -qam entry
RUNNER_MODE=dry-run run_driver "$p"
assert_grep 'a && b' "$OUT"
assert_grep 'costs \$5 & more' "$OUT"

# ── Guard hook ───────────────────────────────────────────────────────────────
scenario "guard hook"
# shellcheck source=guard.sh
source "$KIT/tests/guard.sh"

echo
if (( FAIL == 0 )); then
  printf '\033[1;32m✓ %d assertions passed\033[0m\n' "$PASS"
else
  printf '\033[1;31m✗ %d failed, %d passed\033[0m\n' "$FAIL" "$PASS"
  exit 1
fi
