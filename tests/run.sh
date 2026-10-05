#!/usr/bin/env bash
# Driver + CLI tests without Docker or tokens: a fake `claude` on PATH plays
# the builder and the reviewer according to a per-scenario plan.
#   bash tests/run.sh            # all scenarios + guard tests
# The result depends only on PATH, HOME and TMPDIR: the caller's environment
# is discarded (see below), so the runner's own variables — exported inside a
# runner container, or on a developer machine — cannot change what a scenario
# asserts or sleep on an inherited RETRY_SCHEDULE.
set -uo pipefail
if [[ -z "${PHASE_RUNNER_TESTS_CLEAN:-}" ]]; then
  # Re-exec once under a clean environment. Scenario-level prefix assignments
  # (`CLAUDE_MODEL=x run_driver …`) are the only configuration from here on.
  clean=(PATH="$PATH" HOME="$HOME" PHASE_RUNNER_TESTS_CLEAN=1)
  [[ -n "${TMPDIR:-}" ]] && clean+=(TMPDIR="$TMPDIR")
  exec env -i "${clean[@]}" bash "${BASH_SOURCE[0]}" "$@"
fi
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
    PHASE_FILES="${PHASE_FILES:-plan/A.md}" PUSH="${PUSH:-0}" RETRY_SCHEDULE="${RETRY_SCHEDULE:-0}" \
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
scenario "canary: no runner variable reaches the scenarios' environment"
# Every setting the container hands to the driver (the keys under
# `environment:` in docker-compose.yml, read from the file so a setting added
# later is covered) plus what the driver sets for agents and tests.
mapfile -t runner_vars < <(sed -n '/^ *environment:/,/^ *volumes:/p' "$KIT/docker-compose.yml" \
  | sed -nE 's/^ +([A-Z_]+):.*/\1/p')
runner_vars+=(PHASE_RUNNER_ROLE PHASE_RUNNER_PROTECTED RUNNER_STATE RUNNER_MANIFEST FAKE_PLAN FAKE_LOG)
for v in PHASE_FILES GATE_CMD RETRY_SCHEDULE CLAUDE_MODEL DOCKER_SOCKET; do
  printf '%s\n' "${runner_vars[@]}" | grep -qx "$v" && ok || bad "$v missing from the list read from docker-compose.yml"
done
for v in "${runner_vars[@]}"; do
  [[ -z "${!v+set}" ]] && ok || bad "$v is set in the suite's environment (value '${!v}')"
done
unset v runner_vars

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
assert_grep '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z FAIL phase plan/A.md BLOCKED' "$STATE/logs/driver.log"   # die → FAIL line

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
assert_grep '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z WARN Gate RED \(rc=' "$STATE/logs/driver.log"   # warn → WARN line

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
assert_grep '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z INFO Transient API failure \(build, attempt 1/' "$STATE/logs/driver.log"   # the retry is on record
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
assert_grep 'Bash tool: default timeout 300s, maximum 300s; background tasks: off' "$OUT"   # STALL_TIMEOUT=600 → max 300, default capped

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

scenario "Bash tool defaults: every role gets 600s/1500s and background tasks off; prompts say 25 minutes"
p="$(new_project bashdefaults)"
STALL_TIMEOUT=1800 run_driver "$p" build:ok review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(cat "$FAKE/3.role")" fix "role 3"
for n in 1 2 3 4; do
  assert_grep '^BASH_DEFAULT_TIMEOUT_MS=600000$' "$FAKE/$n.env"
  assert_grep '^BASH_MAX_TIMEOUT_MS=1500000$' "$FAKE/$n.env"
  assert_grep '^CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1$' "$FAKE/$n.env"
done
assert_grep 'Bash tool: default timeout 600s, maximum 1500s; background tasks: off' "$OUT"
for n in 1 3; do   # builder and fix prompts carry the rules block
  assert_grep 'Every command runs in the foreground' "$FAKE/$n.prompt"
  assert_grep 'explicit `timeout`, up to 25 minutes' "$FAKE/$n.prompt"
  assert_grep 'Never use `run_in_background` and never end your turn to wait' "$FAKE/$n.prompt"
  assert_grep 'started with the shell.s `&` and a log file' "$FAKE/$n.prompt"
  assert_not_grep 'Do not leave commands running in the background' "$FAKE/$n.prompt"
done
assert_grep 'never with `run_in_background`, and never end your turn to wait' "$FAKE/2.prompt"
assert_grep 'up to 25 minutes' "$FAKE/2.prompt"
assert_not_grep 'Every command runs in the foreground' "$FAKE/2.prompt"   # the reviewer gets the one-sentence version, not the rules block
p="$(new_project bashpreflight)"
STALL_TIMEOUT=1800 RUNNER_MODE=preflight run_driver "$p" preflight:ok
assert_eq "$RC" 0 "rc (preflight)"
assert_grep '^BASH_DEFAULT_TIMEOUT_MS=600000$' "$FAKE/1.env"
assert_grep '^BASH_MAX_TIMEOUT_MS=1500000$' "$FAKE/1.env"
assert_grep '^CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1$' "$FAKE/1.env"
p="$(new_project bashfinal)"
STALL_TIMEOUT=1800 RUNNER_MODE=review run_driver "$p" final-review:ok
assert_eq "$RC" 0 "rc (final review)"
assert_grep '^BASH_DEFAULT_TIMEOUT_MS=600000$' "$FAKE/1.env"
assert_grep '^BASH_MAX_TIMEOUT_MS=1500000$' "$FAKE/1.env"
assert_grep '^CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1$' "$FAKE/1.env"

scenario "Bash tool: explicit timeouts reach the process in ms; BACKGROUND_TASKS=1 sets nothing; prompts state the maximum"
p="$(new_project bashexplicit)"
BASH_TIMEOUT=90 BASH_TIMEOUT_MAX=300 BACKGROUND_TASKS=1 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
for n in 1 2; do
  assert_grep '^BASH_DEFAULT_TIMEOUT_MS=90000$' "$FAKE/$n.env"
  assert_grep '^BASH_MAX_TIMEOUT_MS=300000$' "$FAKE/$n.env"
  assert_not_grep 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' "$FAKE/$n.env"
  assert_grep 'up to 5 minutes' "$FAKE/$n.prompt"
done
assert_grep 'Bash tool: default timeout 90s, maximum 300s; background tasks: on' "$OUT"

scenario "Bash tool: derived defaults follow a small STALL_TIMEOUT and never stop the run"
p="$(new_project bashderived700)"
STALL_TIMEOUT=700 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc (700)"
assert_grep '^BASH_DEFAULT_TIMEOUT_MS=400000$' "$FAKE/1.env"
assert_grep '^BASH_MAX_TIMEOUT_MS=400000$' "$FAKE/1.env"
assert_grep 'Bash tool: default timeout 400s, maximum 400s; background tasks: off' "$OUT"
assert_grep 'up to 6 minutes' "$FAKE/1.prompt"   # 400s, rounded down so the stated maximum is never above the real one
p="$(new_project bashderived200)"
STALL_TIMEOUT=200 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc (200)"
assert_grep '^BASH_DEFAULT_TIMEOUT_MS=120000$' "$FAKE/1.env"
assert_grep '^BASH_MAX_TIMEOUT_MS=120000$' "$FAKE/1.env"
assert_grep 'Bash tool: default timeout 120s, maximum 120s; background tasks: off' "$OUT"
assert_grep 'up to 2 minutes' "$FAKE/1.prompt"

scenario "Bash tool: an invalid explicit setting stops the run before any agent and names the setting"
p="$(new_project bashinvalid)"
BASH_TIMEOUT=abc run_driver "$p" build:ok review:PASS
assert_eq "$RC" 1 "rc (BASH_TIMEOUT=abc)"
assert_eq "$(invocations)" 0 "invocations (BASH_TIMEOUT=abc)"
assert_grep 'BASH_TIMEOUT=abc: must be a positive integer' "$OUT"
BASH_TIMEOUT=0 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 1 "rc (BASH_TIMEOUT=0)"
assert_eq "$(invocations)" 0 "invocations (BASH_TIMEOUT=0)"
assert_grep 'BASH_TIMEOUT=0: must be a positive integer' "$OUT"
BASH_TIMEOUT=900 BASH_TIMEOUT_MAX=600 STALL_TIMEOUT=1800 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 1 "rc (BASH_TIMEOUT above max)"
assert_eq "$(invocations)" 0 "invocations (BASH_TIMEOUT above max)"
assert_grep 'BASH_TIMEOUT=900: must not be above BASH_TIMEOUT_MAX \(600\)' "$OUT"
STALL_TIMEOUT=1800 BASH_TIMEOUT_MAX=1800 run_driver "$p" build:ok review:PASS
assert_eq "$RC" 1 "rc (BASH_TIMEOUT_MAX not below STALL_TIMEOUT)"
assert_eq "$(invocations)" 0 "invocations (BASH_TIMEOUT_MAX not below STALL_TIMEOUT)"
assert_grep 'BASH_TIMEOUT_MAX=1800: must be below STALL_TIMEOUT \(1800\)' "$OUT"
BACKGROUND_TASKS=yes run_driver "$p" build:ok review:PASS
assert_eq "$RC" 1 "rc (BACKGROUND_TASKS=yes)"
assert_eq "$(invocations)" 0 "invocations (BACKGROUND_TASKS=yes)"
assert_grep 'BACKGROUND_TASKS=yes: must be 0 or 1' "$OUT"
assert_not_grep 'plan/A.md' "$STATE/phases-done"

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
# shellcheck source=/dev/null  # the function's text is cut out of bin/phase-runner at run time
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

# ── Usage limits: the rejected rate_limit_event decides, scoped to the attempt ──
scenario "usage limit → wait for the window to reset, resume the same session"
p="$(new_project limit)"
LIMIT_WAIT_GRACE=0 run_driver "$p" build:limit build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Usage limit reached' "$OUT"
assert_grep 'the five_hour window resets at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC — waiting' "$OUT"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_grep '"unifiedWindows"' "$STATE/logs/A.md.build.log"              # the fake speaks the real dialect
assert_grep '"overageStatus":"rejected"' "$STATE/logs/A.md.build.log"
assert_grep "hit your session limit · resets 4:10pm \(UTC\)" "$STATE/logs/A.md.build.log"

scenario "five-hour limit announced as 'out of usage credits · resets …' → the event decides: waited out, not a stop"
p="$(new_project limitcredits)"
LIMIT_WAIT_GRACE=0 run_driver "$p" build:limitcredits build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Usage limit reached .*the five_hour window resets at' "$OUT"
assert_not_grep 'out of usage credits — top up' "$OUT"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_grep "out of usage credits · resets 8:40pm \(UTC\)" "$STATE/logs/A.md.build.log"

# A reset further away than LIMIT_WAIT_MAX is an honest stop, at once. The cap
# is low in these scenarios so that a regression into waiting costs seconds
# and a second invocation, not a day of sleep.
scenario "weekly limit resetting after LIMIT_WAIT_MAX → stops at once and says when to come back"
p="$(new_project weekly)"
t0=$(date +%s)
LIMIT_WAIT_MAX=30 run_driver "$p" build:weekly
assert_eq "$RC" 1 "rc"
assert_eq "$(invocations)" 1 "invocations"
(( $(date +%s) - t0 < 20 )) && ok || bad "the driver slept instead of stopping"
assert_not_grep 'Usage limit reached|Retry [0-9]' "$OUT"
reset_at="$(jq -R -r 'fromjson? | select(.type=="rate_limit_event") | .rate_limit_info.resetsAt' "$STATE/logs/A.md.build.log" | tail -1)"
reset_str="$(date -u -d "@$reset_at" '+%F %H:%M UTC')"
for f in "$OUT" "$STATE/SUMMARY.md"; do
  assert_grep "usage limit: the seven_day_overage_included window resets at $reset_str \(in 2[34]h [0-9]{2}m, further away than LIMIT_WAIT_MAX=30s\)" "$f"
  assert_grep "the CLI said \"You're out of usage credits\. Switch to another model to continue\.\"" "$f"
  assert_grep 're-run `phase-runner build` after that time to resume where the run stopped, or raise LIMIT_WAIT_MAX to make the runner wait instead' "$f"
done
assert_grep 'FAILED' "$STATE/SUMMARY.md"
assert_grep '"unifiedWindows"' "$STATE/logs/A.md.build.log"
unset t0 reset_at reset_str f

scenario "the same weekly limit with LIMIT_WAIT_MAX above the distance → waited out, resumed"
p="$(new_project weeklywait)"
FAKE_LIMIT_RESET_IN=3 LIMIT_WAIT_MAX=30 LIMIT_WAIT_GRACE=0 run_driver "$p" build:weekly build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Usage limit reached .*the seven_day_overage_included window resets at' "$OUT"
assert_not_grep 'out of usage credits — top up' "$OUT"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep '^plan/A.md$' "$STATE/phases-done"

scenario "out of usage credits with no rejected event is an honest stop, not a retry"
p="$(new_project nocredits)"
run_driver "$p" build:nocredits
assert_eq "$RC" 1 "rc"
assert_eq "$(invocations)" 1 "invocations"
assert_grep 'out of usage credits — top up' "$OUT"
assert_not_grep 'Usage limit reached|window resets' "$OUT"
assert_grep "/model to switch models\." "$STATE/logs/A.md.build.log"
assert_not_grep '"status":"rejected"' "$STATE/logs/A.md.build.log"     # the text alone decides here

scenario "rejection whose reset has passed → retried on RETRY_SCHEDULE, whatever the text says"
p="$(new_project limitpassed)"
FAKE_LIMIT_RESET_IN=-5 run_driver "$p" build:weekly build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Usage window reset already .*the seven_day_overage_included window reset at' "$OUT"
assert_not_grep 'out of usage credits — top up|Usage limit reached' "$OUT"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep '^plan/A.md$' "$STATE/phases-done"

# Retries and re-runs append to one log file: a rejected event and an
# out-of-credit text left by yesterday's run must not decide today's 529.
scenario "stale rejection left in the log by an earlier run does not decide a later transient failure"
p="$(new_project stalelimit)"
mkdir -p "$p/.phase-runner/state/logs"
printf '%s\n' \
  "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\",\"resetsAt\":$(( $(date +%s) + 10800 )),\"rateLimitType\":\"seven_day_overage_included\",\"overageStatus\":\"rejected\",\"overageDisabledReason\":\"out_of_credits\",\"isUsingOverage\":false}}" \
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"duration_ms\":1000,\"total_cost_usd\":0.3,\"num_turns\":2,\"session_id\":\"old\",\"result\":\"You're out of usage credits. Switch to another model to continue.\"}" \
  > "$p/.phase-runner/state/logs/A.md.build.log"
t0=$(date +%s)
LIMIT_WAIT_MAX=30 run_driver "$p" build:transient build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Transient API failure' "$OUT"
assert_not_grep '[Uu]sage (limit|window)|out of usage credits' "$OUT"
(( $(date +%s) - t0 < 20 )) && ok || bad "the driver waited for the stale window"
assert_eq "$(arg_after 2 --resume)" "$(arg_after 1 --session-id)" "resume uses the first session id"
assert_grep '^plan/A.md$' "$STATE/phases-done"
unset t0

scenario "an allowed rate_limit_event carrying overageStatus rejected is never a rejection"
p="$(new_project allowed)"
LIMIT_WAIT_MAX=30 run_driver "$p" build:allowed build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 3 "invocations"
assert_grep 'Transient API failure' "$OUT"
assert_not_grep '[Uu]sage (limit|window)' "$OUT"
assert_grep '"status":"allowed"' "$STATE/logs/A.md.build.log"
assert_grep '"overageStatus":"rejected"' "$STATE/logs/A.md.build.log"
assert_grep '^plan/A.md$' "$STATE/phases-done"

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
GATE_CMD='' run_driver "$p" build:ok review:PASS
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

# ── driver.log: the runner's own account of a run ─────────────────────────
TS='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
ESC=$'\033'
scenario "driver.log: every log line of a run, timestamped, levelled, in order, no colour"
p="$(new_project driverlog)"
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
DRV="$STATE/logs/driver.log"
assert_file "$DRV"
assert_grep "$TS INFO === driver start: mode build, branch main, Claude Code 0\.0\.0 \(fake\), pid [0-9]+$" "$DRV"
assert_eq "$(grep -cE "$TS (INFO|WARN|FAIL) " "$DRV")" "$(wc -l < "$DRV")" "every line starts with a UTC timestamp and a level"
assert_not_grep "$ESC" "$DRV"
# the INFO lines after the header are exactly the terminal's ▶ lines, in order
assert_eq "$(grep -E "$TS INFO " "$DRV" | tail -n +2 | cut -d' ' -f3-)" \
          "$(sed -n "s/^${ESC}\[1;34m▶ \(.*\)${ESC}\[0m\$/\1/p" "$OUT")" "INFO lines mirror the terminal"
assert_grep "$TS INFO All phases complete$" "$DRV"
# a second run in the same project appends: two headers, both runs' messages
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc (second run)"
assert_eq "$(invocations)" 0 "second run: nothing left to build"
assert_eq "$(grep -c '=== driver start:' "$DRV")" 2 "two header lines"
assert_eq "$(grep -c 'All phases complete$' "$DRV")" 2 "both runs' last message"
assert_grep 'Phase plan/A.md: already completed in a previous run' "$DRV"
assert_grep "$TS INFO Phases: plan/A.md$" "$DRV"
assert_eq "$(grep -cE "$TS (INFO|WARN|FAIL) " "$DRV")" "$(wc -l < "$DRV")" "every line still well-formed"

scenario "driver.log impossible to write → the build still completes"
p="$(new_project driverlog-ro)"
mkdir -p "$p/.phase-runner/state/logs/driver.log"   # a directory in its place defeats root too
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_grep '^plan/A.md$' "$STATE/phases-done"
assert_grep 'All phases complete' "$OUT"
assert_not_grep 'Is a directory' "$OUT"
[[ -d "$STATE/logs/driver.log" ]] && ok || bad "the directory was replaced"
assert_grep 'SUCCESS' "$STATE/SUMMARY.md"

scenario "host CLI: init, status, logs (no docker)"
p="$(new_project cli)"
bash "$KIT/bin/phase-runner" --project "$p" init >/dev/null 2>&1; rc=$?
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
# driver.log is the newest file in logs/ during a run: `logs` with no phase still picks an agent log
touch "$FIXPASS_PROJECT/.phase-runner/state/logs/driver.log"
lg="$(bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" logs 2>&1)"; rc=$?
assert_eq "$rc" 0 "latest log rc"
grep -q 'driver.log' <<<"$lg" && bad "latest log picked driver.log" || ok
grep -qE '^.*▶ .*state/logs/A\.md\.[a-z]+(\.r[0-9]+)?\.log' <<<"$lg" && ok || bad "latest log is not an agent log: $(head -1 <<<"$lg")"
lg="$(bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" logs driver 2>&1)"; rc=$?
assert_eq "$rc" 0 "driver log rc"
grep -qE "$TS INFO === driver start: mode build" <<<"$lg" && ok || bad "logs driver does not print the driver log"
grep -qE "$TS INFO All phases complete$" <<<"$lg" && ok || bad "logs driver is not plain text"
grep -q 'logs driver' <<<"$(tail -1 <<<"$st")" && ok || bad "status does not name the driver log in its last line: $(tail -1 <<<"$st")"
grep -q 'logs driver' <<<"$(bash "$KIT/bin/phase-runner" --help)" && ok || bad "usage does not list 'logs driver'"
assert_file "$FIXPASS_PROJECT/.phase-runner/state/logs/driver.log"
bash "$KIT/bin/phase-runner" --project "$FIXPASS_PROJECT" reset --yes >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "reset rc"
assert_no_file "$FIXPASS_PROJECT/.phase-runner/state/logs/driver.log"
assert_no_file "$FIXPASS_PROJECT/.phase-runner/state"
assert_file "$FIXPASS_PROJECT/.phase-runner/runner.env"
bash "$KIT/bin/phase-runner" --project "$p" bogus >/dev/null 2>&1; rc=$?
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
assert_grep '^image inspect claude-phase-runner:latest$' "$FAKE_DOCKER/calls"
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
# RUNNER_IMAGE: an environment override for testing (tests/smoke.sh builds
# under its own tag). The CLI inspects that name, and compose interpolates
# the same one, so the default image is never replaced.
RUNNER_IMAGE=x:y cli_run DOCKER_SOCKET=0
assert_eq "$RC" 0 "rc (RUNNER_IMAGE)"
assert_grep '^image inspect x:y$' "$FAKE_DOCKER/calls"
assert_not_grep 'claude-phase-runner:latest' "$FAKE_DOCKER/calls"
assert_grep '^ +image: \$\{RUNNER_IMAGE:-claude-phase-runner:latest\}$' "$KIT/docker-compose.yml"

scenario "host CLI: the kit refuses to build itself; init/status/logs/reset still work there (fake docker)"
# A copy of the kit that is also the project: its own bin/phase-runner is run
# with --project pointing at the copy (via a symlink, to prove the comparison
# is by directory and not by string).
k="$TMP/kitcopy"
mkdir -p "$k/plan" "$k/.phase-runner"
cp -a "$KIT/bin" "$KIT/docker" "$KIT/prompts" "$KIT/templates" "$KIT/docker-compose.yml" "$k/"
git -C "$k" init -q -b main
printf '# Entry\n' > "$k/plan/ENTRY.md"; printf '# Phase A\n' > "$k/plan/A.md"
printf 'ENTRY_FILE=plan/ENTRY.md\nPUSH=0\n' > "$k/.phase-runner/runner.env"
printf 'plan/A.md\n' > "$k/.phase-runner/phases"
ln -s "$k" "$TMP/kitcopy-link"
self_run() {  # self_run ARG... → RC, OUT, FAKE_DOCKER
  FAKE_DOCKER="$TMP/fakedocker-$RANDOM$RANDOM"; mkdir -p "$FAKE_DOCKER"
  OUT="$TMP/out-$RANDOM$RANDOM.log"
  PATH="$TMP/fakedocker:$PATH" FAKE_DOCKER="$FAKE_DOCKER" PHASE_RUNNER_CREDENTIALS="$TMP/creds.env" \
    bash "$k/bin/phase-runner" --project "$TMP/kitcopy-link" "$@" >"$OUT" 2>&1 </dev/null
  RC=$?
}
for cmd in "build" "build --dry-run" "dry-run" "preflight" "review"; do
  # shellcheck disable=SC2086  # unquoted on purpose: "build --dry-run" must split into two arguments
  self_run $cmd
  assert_eq "$RC" 1 "rc ($cmd)"
  assert_grep 'refusing to start a container with the kit as the project' "$OUT"
  assert_grep 'mounted live into the run' "$OUT"
  assert_grep 'frozen clone' "$OUT"
  assert_grep "git clone $k " "$OUT"
  assert_grep "--project $k(-link)? ${cmd%% *}" "$OUT"
  assert_no_file "$FAKE_DOCKER/calls"
done
# No container needed, so these keep working on the kit-as-project.
rm -rf "$k/.phase-runner"
self_run init
assert_eq "$RC" 0 "init rc"
assert_file "$k/.phase-runner/runner.env"
assert_file "$k/.phase-runner/phases"
printf 'plan/A.md\n' > "$k/.phase-runner/phases"
mkdir -p "$k/.phase-runner/state/logs"
printf 'gate output\n' > "$k/.phase-runner/state/logs/A.md.gate.r0.log"
self_run status
assert_eq "$RC" 0 "status rc"
assert_grep '^plan/A.md +pending' "$OUT"
self_run logs A.md.gate
assert_eq "$RC" 0 "logs rc"
assert_grep '^gate output$' "$OUT"
self_run reset --yes
assert_eq "$RC" 0 "reset rc"
assert_no_file "$k/.phase-runner/state"
assert_file "$k/.phase-runner/runner.env"
unset k cmd

scenario "prompt rendering keeps && and $ literal"
p="$(new_project render)"
printf 'Gate: `a && b` costs $5 & more\n' > "$p/plan/ENTRY.md"
git -C "$p" commit -qam entry
RUNNER_MODE=dry-run run_driver "$p"
assert_grep 'a && b' "$OUT"
assert_grep 'costs \$5 & more' "$OUT"

# ── Lint ─────────────────────────────────────────────────────────────────────
scenario "lint: shellcheck -x -S warning over every kit script (one SKIP line when shellcheck is absent)"
lint_files() {  # lint_files → LINT_FILES, kit-relative, from the directories: a new script is covered unedited
  local f; LINT_FILES=()
  for f in "$KIT"/bin/* "$KIT"/docker/*.sh "$KIT"/docker/lib/*.sh "$KIT"/tests/*.sh "$KIT"/tests/bin/*; do
    [[ -f "$f" ]] && LINT_FILES+=("${f#"$KIT"/}")
  done
}
lint_kit() {  # lint_kit → rc 0 and one SKIP line without shellcheck; otherwise shellcheck's findings and rc
  command -v shellcheck >/dev/null 2>&1 \
    || { echo "  SKIP: shellcheck not on PATH — the lint scenario did not run"; return 0; }
  lint_files
  (cd "$KIT" && shellcheck -x -S warning "${LINT_FILES[@]}")
}
lint_files
for f in bin/phase-runner docker/driver.sh docker/guard.sh docker/lib/claude.sh tests/run.sh tests/guard.sh tests/smoke.sh tests/bin/claude; do
  printf '%s\n' "${LINT_FILES[@]}" | grep -qx "$f" && ok || bad "$f missing from the lint list"
done
if command -v shellcheck >/dev/null 2>&1; then
  lint_out="$(lint_kit 2>&1)"; rc=$?
  if (( rc == 0 )); then ok; else bad "shellcheck -x -S warning over ${#LINT_FILES[@]} scripts:"$'\n'"$lint_out"; fi
else
  lint_kit
fi
# The skip path, whatever this machine has: with shellcheck hidden from PATH
# the scenario prints exactly one SKIP line and passes.
mkdir -p "$TMP/no-shellcheck"
lint_out="$(PATH="$TMP/no-shellcheck" lint_kit 2>&1)"; rc=$?
assert_eq "$rc" 0 "rc without shellcheck"
assert_eq "$(grep -c 'SKIP: shellcheck not on PATH' <<<"$lint_out")" 1 "one SKIP line without shellcheck"
assert_eq "$(wc -l <<<"$lint_out")" 1 "nothing but the SKIP line without shellcheck"
unset f lint_out

# ── Guard hook ───────────────────────────────────────────────────────────────
scenario "guard hook"
# ── The SSH agent is the runner's push credential, never the agent's ─────────
scenario "SSH agent: every agent and the gate run without SSH_AUTH_SOCK; the runner's push keeps it"
p="$(new_project sshagent)"
remote="$TMP/remote-sshagent.git"; git init -q --bare "$remote"
git -C "$p" remote add origin "$remote"
printf '#!/usr/bin/env bash\necho "${SSH_AUTH_SOCK-unset}" > "%s/pre-push.saw"\n' "$TMP" > "$p/.git/hooks/pre-push"
chmod +x "$p/.git/hooks/pre-push"
SSH_AUTH_SOCK=/tmp/fake-agent.sock PUSH=1 GATE_CMD='test -z "${SSH_AUTH_SOCK:-}"' \
  run_driver "$p" build:ok review:FAIL fix:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_eq "$(invocations)" 4 "invocations"
for n in 1 2 3 4; do                       # build, review, fix, review
  assert_file "$FAKE/$n.env"
  assert_not_grep 'SSH_AUTH_SOCK' "$FAKE/$n.env"
done
assert_grep 'Gate GREEN' "$OUT"
assert_grep $'\tgate\t1\tgreen\t' "$STATE/runs.tsv"
assert_eq "$(cat "$TMP/pre-push.saw")" /tmp/fake-agent.sock "pre-push hook saw the driver's SSH_AUTH_SOCK"
assert_grep 'Pushed main to origin' "$OUT"
assert_eq "$(git -C "$remote" rev-parse main)" "$(git -C "$p" rev-parse HEAD)" "remote has HEAD"
assert_eq "$(grep -c 'Push remote origin (' "$OUT")" 1 "one early-check line"
assert_grep 'Push remote origin \(.*remote-sshagent.git\) is reachable' "$OUT"
assert_not_grep 'NOT reachable' "$OUT"
assert_grep 'No SSH .* the runner holds the push credentials' "$FAKE/1.prompt"
assert_grep 'No SSH .* the runner holds the push credentials' "$FAKE/3.prompt"
unset n remote

scenario "SSH agent: preflight and final review run without SSH_AUTH_SOCK; preflight is told not to probe"
p="$(new_project sshreport)"
SSH_AUTH_SOCK=/tmp/fake-agent.sock RUNNER_MODE=preflight run_driver "$p" preflight:ok
assert_eq "$RC" 0 "rc (preflight)"
assert_file "$FAKE/1.env"
assert_not_grep 'SSH_AUTH_SOCK' "$FAKE/1.env"
assert_grep 'Push access is checked by the runner itself' "$FAKE/1.prompt"
SSH_AUTH_SOCK=/tmp/fake-agent.sock RUNNER_MODE=review run_driver "$p" final-review:ok
assert_eq "$RC" 0 "rc (review)"
assert_file "$FAKE/1.env"
assert_not_grep 'SSH_AUTH_SOCK' "$FAKE/1.env"

scenario "push access: an unreachable remote in preflight warns, names the remote, completes, never pushes"
p="$(new_project pushcheck)"
git -C "$p" remote add origin "$TMP/no-such-remote.git"
PUSH=1 RUNNER_MODE=preflight run_driver "$p" preflight:ok
assert_eq "$RC" 0 "rc"
assert_grep 'Push remote origin \(.*no-such-remote.git\) is NOT reachable' "$OUT"
assert_grep 'no SSH agent forwarded' "$OUT"
assert_grep 'bad token in an HTTPS remote URL' "$OUT"
assert_grep 'MARKER-REPORT' "$STATE/TOOLING.md"
assert_not_grep 'Pushed|Push failed' "$OUT"
assert_not_grep $'\tpush\t' "$STATE/runs.tsv"
assert_grep 'does not appear to be a git repository' "$STATE/logs/push.log"

scenario "push access: a remote that needs credentials fails at once with git's own error, no prompt, no kill"
# tests/bin/git-remote-needsauth asks git for credentials like git-remote-https
# on a 401. The driver has a terminal under `docker compose run`, so without
# GIT_TERMINAL_PROMPT=0 git would prompt for a username until the 30-second cap
# kills it; with it the log holds git's error and the warning is immediate.
p="$(new_project pushauth)"
git -C "$p" remote add origin needsauth://needsauth.invalid/o/r.git
t0=$(date +%s)
PUSH=1 RUNNER_MODE=preflight run_driver "$p" preflight:ok
assert_eq "$RC" 0 "rc"
(( $(date +%s) - t0 < 20 )) && ok || bad "the push check waited on a prompt instead of failing at once"
assert_grep 'Push remote origin \(needsauth://needsauth.invalid/o/r.git\) is NOT reachable' "$OUT"
assert_grep "could not read Username for 'https://needsauth.invalid': terminal prompts disabled" "$STATE/logs/push.log"
assert_not_grep 'No such device|Killed' "$STATE/logs/push.log"
assert_grep 'MARKER-REPORT' "$STATE/TOOLING.md"
assert_not_grep $'\tpush\t' "$STATE/runs.tsv"
unset t0

scenario "push access: PUSH=0 never contacts the remote"
p="$(new_project pushcheck0)"
git -C "$p" remote add origin "$TMP/no-such-remote.git"
run_driver "$p" build:ok review:PASS
assert_eq "$RC" 0 "rc"
assert_not_grep 'Push remote' "$OUT"
assert_no_file "$STATE/logs/push.log"

# shellcheck source=guard.sh
source "$KIT/tests/guard.sh"

echo
if (( FAIL == 0 )); then
  printf '\033[1;32m✓ %d assertions passed\033[0m\n' "$PASS"
else
  printf '\033[1;31m✗ %d failed, %d passed\033[0m\n' "$FAIL" "$PASS"
  exit 1
fi
