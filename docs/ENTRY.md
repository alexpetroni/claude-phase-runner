# claude-phase-runner — hardening batch, October 2026 — mission & constitution

You are improving the EXISTING, working `claude-phase-runner` kit: a bash tool that runs
Claude Code unattended against a git repository, one builder and one independent,
read-only reviewer per phase plan file, inside a Docker container. Do not rebuild it and
do not restructure it. This batch closes specific gaps that were found by reading the
logs of real runs. Each phase file states the evidence, the deliverables and a
Definition of Done.

## You are being run by this same tool — read this once

- **The runner around you is a frozen copy.** It is mounted read-only at
  `/opt/phase-runner`. The repository in your working directory is the one you change.
  Your edits to `docker/`, `prompts/` or `bin/` do not affect the run you are in, and the
  behaviour you observe from the runner around you is the OLD behaviour.
- **Never launch the real thing from inside this run.** No real `claude` (the suite uses
  the fake in `tests/bin/claude`), no `phase-runner build`, `preflight` or `review`
  against a real project, no `docker` (there is no daemon here). Everything is verified
  through `tests/run.sh`. Inspecting the installed Claude Code package on disk is fine;
  starting it is not.
- **The guard hook around you refuses a Bash command that mentions `.phase-runner`,
  `docs/ENTRY.md` or a phase file together with a writing construct** (`>`, `rm`, `cp`,
  `mv`, `tee`, `sed -i`, `chmod`, ...). Any `>` counts, including `2>&1` and
  `2>/dev/null`. This repository's code and tests are full of the string
  `.phase-runner`. So change files with the edit tools, and put an ad-hoc
  experiment into a script under `/tmp` (written with the Write tool) and run that
  script, instead of typing such commands inline.
- **Your shell inherits the runner's own variables** (`PHASE_FILES`, `GATE_CMD`,
  `RETRY_SCHEDULE`, `BUILD_EFFORT`, `DOCKER_SOCKET`, `PHASE_RUNNER_ROLE`, ...). Until
  PHASE-0 has landed the test suite is not immune to them; PHASE-0 explains how to get
  a true baseline.

## Read before your phase

`README.md` is the specification of current behaviour: the configuration table, what
happens in a phase, retries, resume, the guard, the security model. Then the code, about
2,300 lines in all. Read the files your phase touches end to end.

| Path | What it is |
|---|---|
| `bin/phase-runner` | Host CLI: `init`, `build`, `preflight`, `review`, `status`, `logs`, `reset`. Loads `<project>/.phase-runner/runner.env`, exports it, calls `docker compose run`. |
| `docker-compose.yml` | The container: mounts, and the `environment:` list that hands settings to the driver. |
| `docker/bootstrap.sh` | Container entrypoint (root): credentials, Docker socket group, git identity, SSH agent, drop to `node`. |
| `docker/driver.sh` | The phase loop: builder, checkpoint, gate, reviewer, fix rounds, blocked handling, push; dry run, preflight, final review. |
| `docker/lib/claude.sh` | Launching `claude` per role: arguments, environment, stall watchdog, transient-failure and usage-limit retries, session resume. |
| `docker/lib/common.sh`, `docker/lib/git.sh` | Logging, prompt rendering, `runs.tsv`, `SUMMARY.md`; checkpoint commits, tree snapshot/restore, push. |
| `docker/guard.sh` | The `PreToolUse` hook that enforces the rules for every role. |
| `prompts/*.md` | The instructions each role receives. They are product: wording matters. |
| `templates/` | `runner.env`, `phases`, `credentials.env` starting points for a new project. |
| `tests/run.sh`, `tests/guard.sh`, `tests/bin/claude` | The suite: driver and CLI scenarios driven by a fake `claude`, plus one case per guard rule. |

## What "done" means for this batch

- Every deliverable is implemented at the root cause and proven by a scenario in
  `tests/run.sh` (driver and CLI behaviour, through the fake `claude`) or a case in
  `tests/guard.sh` (guard rules). An unverified guardrail is a decoration.
- **Existing projects keep working.** A `runner.env` that does not mention a new setting
  behaves as the phase file specifies for that case, and nothing else about it changes.
  The state layout stays readable and resumable: `phases-done`, `progress/`, `blocked`,
  the `runs.tsv` columns, `reviews/`, the `logs/` file names.
- No behaviour change beyond the phase's deliverables. Keep diffs tight and reviewable.
- These decisions belong to the human and are NOT part of this batch, even where a phase
  touches the same code: the default effort level, the default `FIX_CONTEXT`, falling
  back to another model when a usage cap is hit, and removing the legacy fallbacks
  (`PHASE_FILES` in `runner.env`, credentials in the kit directory).

## Binding engineering rules

- **Bash only.** bash 5, coreutils, git, jq. No new runtime dependency and no other
  language for kit code. Follow the conventions already in each file (`set -uo pipefail`
  in the driver, `set -euo pipefail` in the CLI, results returned through documented
  globals because bash functions cannot return arrays). Keep `# shellcheck` directives
  accurate.
- **A setting exists in five places or it does not exist:** read with its default where
  it is used; listed under `environment:` in `docker-compose.yml` (a variable that is
  not listed there never reaches the driver); documented in `templates/runner.env`;
  in the README configuration table; covered by a test. Settings are seconds, not
  milliseconds, and `0`/`1` for switches, like the existing ones.
- **The separation of powers stays.** The builder never verifies itself, the reviewer is
  read-only with a fresh context, the runner pushes and the agent cannot. Do not weaken
  a guard rule. The guard fails open on unparseable input and must keep doing so: a
  guard bug must never brick a multi-hour run.
- **The kit stays clean.** Nothing per-project and nothing secret lives in the kit
  directory. Per-project config and state live under `<project>/.phase-runner/`,
  credentials are user-level.
- **Do not weaken existing tests to pass.** When an existing assertion has to change
  because the behaviour changes on purpose, the phase file names that change; say so in
  the commit message. The assertion count only grows.
- **Prompts change as little as the phase requires.** Say why a rule exists in one
  sentence so the agent can generalise from it, state things that are true in every
  configuration, and keep the text short.
- **Docs move with the code.** Update every README section the change affects: the
  configuration table, the section that describes the behaviour, Troubleshooting, and
  the tests paragraph under "Iterating on the kit".
- **Commits:** conventional (`feat:`, `fix:`, `test:`, `docs:`), one logical change per
  commit, the body says why. `git log` shows the house style.
- **The entry file and the phase plans are read-only for you.** If you disagree with a
  deliverable or find it impossible, deliver the rest and say so in your report.

## Verification

The gate, from the repository root:

```
bash tests/run.sh
```

- It needs no Docker and no token, takes about 20 seconds, prints one line per scenario
  and only the assertions that fail, and ends with `✓ N assertions passed` or
  `✗ F failed, P passed`. The suite is fast, so running it whole a handful of times is
  fine; pipe it through `tail -15`.
- A driver scenario is `scenario "name"`, `p="$(new_project name)"`, then
  `run_driver "$p" <plan lines>` and assertions on `$RC`, `$OUT` (the driver's terminal
  output), `$STATE` (the project's state directory) and `$FAKE/<n>.args`, `.prompt`,
  `.env`, `.role` (what invocation `n` of the fake `claude` received). Settings are
  passed by prefix assignment: `FIX_CONTEXT=resume run_driver "$p" ...`.
- The fake `claude` pops one `<role>:<outcome>` line of the plan per invocation and
  emits stream-json like the real CLI. When a phase needs the CLI to behave in a new
  way, add an outcome there and keep its output faithful to the real shapes the phase
  file quotes.
- `shellcheck` is installed in this container.
- `docker/bootstrap.sh` and `docker-compose.yml` are NOT exercised by the suite, and
  there is no Docker daemon here. Changes to them can only be checked statically
  (`bash -n`, reading, an assertion on the file's text). Keep them minimal and say in
  your report what could not be executed.

If a Definition of Done item is genuinely unreachable, deliver every other item, commit,
and report status `blocked` with what is missing. Never fake green, never soften the DoD.

## Known gotchas (each has cost a session somewhere)

- A setting added to `runner.env` and read in the driver, but not listed in
  `docker-compose.yml`, works in every test and never works in a real run.
- One log file holds several attempts. Retries and re-runs append to the same
  `<phase>.<role>.log`, so it can contain several `result` events and events left by an
  earlier attempt or an earlier run. Anything that reads "the last X in the log" has to
  ask whether X belongs to the attempt it is judging.
- bash 5.2 treats `&` in `${var//pat/rep}` specially; prompts contain `&&`. See the
  `shopt` at the top of `docker/lib/common.sh` before touching prompt rendering.
- With `pipefail`, `producer | grep -q` fails on SIGPIPE when grep matches early; buffer
  into a variable first, as `docker/lib/claude.sh` does.
- The driver's terminal output is asserted by many scenarios (`assert_grep ... "$OUT"`).
  Changing the wording of an existing line breaks them; add lines rather than rewording.
