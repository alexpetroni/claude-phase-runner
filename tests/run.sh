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

scenario "gate red, no reviewer, fix rounds exhausted → blocked"
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

scenario "model/effort: CLAUDE_* for every role, BUILD_*/REVIEW_* per role"
p="$(new_project models)"
CLAUDE_MODEL=claude-opus-5 CLAUDE_EFFORT=high BUILD_MODEL=claude-sonnet-5 REVIEW_EFFORT=max \
  run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(arg_after 1 --model)" claude-sonnet-5 "builder model override"
assert_eq "$(arg_after 1 --effort)" high "builder effort from CLAUDE_EFFORT"
assert_eq "$(arg_after 2 --model)" claude-opus-5 "reviewer model from CLAUDE_MODEL"
assert_eq "$(arg_after 2 --effort)" max "reviewer effort override"

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
