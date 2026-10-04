# PHASE-0 — The suite ignores its caller's environment; the kit refuses to build itself live

## Problem

Two things stand between this kit and being built by itself. Both are real defects of
the kit, not just obstacles for this batch.

**1. The test suite takes its configuration from whoever calls it.** `run_driver` in
`tests/run.sh` passes several settings as `${VAR:-default}` (`PHASE_FILES`,
`RETRY_SCHEDULE`, `STALL_TIMEOUT`, `GATE_CMD`, `RUNNER_MODE`, `PHASE_REVIEW`,
`MAX_FIX_ROUNDS`, `COMMIT_REVIEWS`) and lets every other runner variable through
untouched (`CLAUDE_MODEL`, the `*_EFFORT` and `*_MODEL` family, `SUBAGENT_MODEL`,
`DOCKER_SOCKET`, `FIX_CONTEXT`, `BASH_OUTPUT_MAX_CHARS`, the budgets, `GIT_BRANCH`, ...).
Inside a runner container all of these are exported, because that is how the driver is
configured. Measured on 2026-10-04:

- clean environment (`env -i PATH="$PATH" HOME="$HOME" bash tests/run.sh`): 317
  assertions pass in about 20 seconds;
- the environment a runner container gives it: 200 of 317 fail within 3 seconds
  (the inherited `PHASE_FILES` names files that do not exist in the temporary
  projects, the inherited `GATE_CMD` runs in them, the inherited efforts and models
  contradict the expected banners);
- with the runner's `RETRY_SCHEDULE="30 300 3600 10800"` inherited, the retry scenarios
  sleep for real: the suite was still running after 60 seconds.

The same happens on a developer's machine as soon as one of those variables is exported.

> **Do not run plain `bash tests/run.sh` in this container before your fix is in.** It
> sleeps on the inherited retry schedule. Use
> `env -i PATH="$PATH" HOME="$HOME" bash tests/run.sh` for the true baseline (317).

**2. Nothing stops the kit from being pointed at itself.** `docker-compose.yml`
bind-mounts the kit's own `docker/` and `prompts/` over the copies baked into the image,
so that kit edits take effect without a rebuild. When the project being built is that
same directory, the builder's edits land in the running runner: bash executes
`driver.sh` incrementally from the file, the prompts are re-read for every role, and
`guard.sh` is started fresh for every tool call. A syntax error in a half-edited
`guard.sh` exits with status 2, which Claude Code treats as "block this call" — every
tool call of the builder, including the edit that would repair the file. The only safe
way to build the kit is from a separate, frozen checkout, and the CLI should say so
instead of starting.

## Deliverables

1. **The suite's result depends only on `PATH`, `HOME` and `TMPDIR`.** No variable in
   the caller's environment may change which assertions run or whether they pass.
   Scenario-level prefix assignments (`CLAUDE_MODEL=x run_driver ...`) must keep working
   exactly as they do now, so sanitise once, up front, rather than per scenario. One
   way: re-execute the script under `env -i` with those three variables, guarded so it
   happens once. The standalone invocation documented in the header of
   `tests/guard.sh` must keep working.
2. **A canary scenario at the start of the suite** asserts that none of the runner's
   variables is present in the environment the scenarios run in. Take the list from the
   keys under `environment:` in `docker-compose.yml`, read from the file so that a
   setting added later is covered without editing the test, plus the names the driver
   sets for agents and tests: `PHASE_RUNNER_ROLE`, `PHASE_RUNNER_PROTECTED`,
   `RUNNER_STATE`, `RUNNER_MANIFEST`, `FAKE_PLAN`, `FAKE_LOG`.
3. **`bin/phase-runner` refuses to launch a container when the project is the kit
   itself.** For the commands that start the container (`build`, `build --dry-run`,
   `dry-run`, `preflight`, `review`): when the resolved project directory and the kit
   directory are the same directory, exit 1 before `docker` is called, with a message
   that says why (the kit's code is mounted live into the run) and how to proceed
   (clone the kit somewhere else and run that clone's `bin/phase-runner` with
   `--project` pointing here). `init`, `status`, `logs` and `reset` start no container
   and must keep working on such a project.
4. **README.** A short subsection under "Iterating on the kit", "Building the kit with
   the kit": the hazard in two sentences and the frozen-clone procedure. Mention in the
   tests paragraph that the suite ignores the caller's environment.

## Out of scope

- Changing what any scenario asserts. This phase changes the environment the scenarios
  run in, and adds the canary and the CLI scenario; the 317 existing assertions stay.
- A test filter, parallel execution or any other suite feature.

## Definition of Done

- [ ] In this container, where the runner's variables are exported
      (`env | grep -cE '^(PHASE_FILES|GATE_CMD|RETRY_SCHEDULE)='` prints `3`), plain
      `bash tests/run.sh` ends with `✓ N assertions passed`, N greater than 317, in
      under 90 seconds.
- [ ] `env -i PATH="$PATH" HOME="$HOME" bash tests/run.sh` reports the same N.
- [ ] This hostile invocation reports the same N:
      `PHASE_FILES=nope.md GATE_CMD=false RUNNER_MODE=review RETRY_SCHEDULE="300 300" STALL_TIMEOUT=1 PHASE_REVIEW=0 MAX_FIX_ROUNDS=0 COMMIT_REVIEWS=1 CLAUDE_MODEL=x CLAUDE_EFFORT=low BUILD_MODEL=y SUBAGENT_MODEL=z FIX_CONTEXT=resume DOCKER_SOCKET=0 BASH_OUTPUT_MAX_CHARS=1 BUILD_BUDGET_USD=1 GIT_BRANCH=nope GUARD=1 PUSH=1 FAKE_PLAN=/nonexistent PHASE_RUNNER_ROLE=review PHASE_RUNNER_PROTECTED=tests bash tests/run.sh`
- [ ] The canary scenario exists, reads its variable list from `docker-compose.yml`,
      and is what fails first under the hostile invocation when the sanitising step is
      disabled in a scratch copy of the repository.
- [ ] On a project whose directory is the kit directory, `build`, `build --dry-run`,
      `preflight` and `review` exit 1 with a message naming the frozen-clone procedure,
      and `docker` is never invoked; `init`, `status`, `logs` and `reset` still work
      there. A scenario proves both halves using a temporary copy of the kit and a fake
      `docker`, in the style of the existing `DOCKER_SOCKET` CLI scenario.
- [ ] A normal project, where kit and project differ, is unaffected: the existing CLI
      scenarios pass unchanged.
- [ ] The README has the "Building the kit with the kit" subsection, and the tests
      paragraph mentions the two new behaviours.
- [ ] Gate green.
