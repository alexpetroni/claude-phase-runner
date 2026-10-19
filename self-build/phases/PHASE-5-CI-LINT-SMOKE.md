# PHASE-5 — The kit checks itself: lint in the suite, CI, a container smoke test

## Problem

- **Nothing runs the suite except a human who remembers to.** There is no CI. The suite
  needs neither Docker nor a token and takes about 20 seconds, so there is no reason
  for a push to go unchecked.
- **The code carries `# shellcheck` directives, but shellcheck is not part of any
  check.** Run on 2026-10-04 with `shellcheck -x -S warning`, the kit has 16 findings:
  `docker/driver.sh` SC2034 ×8, `docker/lib/claude.sh` SC2034 ×1, `tests/run.sh`
  SC1090 ×2, SC1007 ×2, SC2034 ×1 and SC1010 ×1, `bin/phase-runner` SC1010 ×1. Most are
  variables that are set in one file and read in a sourced one, which shellcheck cannot
  see. That count comes from the current stable release; the version installed in this
  container is older and may report a slightly different set. The version here is the
  one that has to be clean.
- **`docker/bootstrap.sh`, `docker-compose.yml` and the `Dockerfile` are never
  executed by a test.** The `DOCKER_SOCKET` change was verified by hand, with a dry run
  in a real container. That check should be a script.
- `load_config` in `bin/phase-runner` contains a dead statement:
  `if [[ -n "${PROJECT_DIR_FROM_ENV:-}" ]]; then :; fi`.

There is no Docker daemon in this run. You can write the smoke test and check it
statically, but you cannot execute its main path. The Definition of Done is written
accordingly, and the human runs it on the host afterwards.

## Deliverables

1. **Lint is part of the suite.** A scenario in `tests/run.sh` runs
   `shellcheck -x -S warning` over every shell script of the kit: `bin/phase-runner`,
   `docker/*.sh`, `docker/lib/*.sh`, `tests/*.sh`, `tests/bin/claude`. When
   `shellcheck` is not on `PATH` the scenario prints one visible `SKIP` line and does
   not fail, so the suite still runs anywhere. The list of scripts is built from the
   directories, so a new script is covered without editing the test.
2. **The kit is clean at that level.** Fix what is a real problem. Where a finding is a
   false positive, such as a global consumed by a sourced file, silence exactly that
   line with a directive and a comment that says where the variable is read. No
   file-wide or blanket disables.
3. **`.github/workflows/ci.yml`**, on every push and pull request, with two independent
   jobs on `ubuntu-latest`:
   - `test`: check out, make sure `jq` and `shellcheck` are installed, run
     `bash tests/run.sh`.
   - `smoke`: check out, run `bash tests/smoke.sh`.

   Pin each action to a released tag that you have verified to exist, for example with
   `git ls-remote --tags https://github.com/actions/checkout`. No secrets, no tokens,
   minimal `permissions`.
4. **`tests/smoke.sh`: the real container, end to end, without an API call.** It builds
   the image and runs the real CLI in `build --dry-run` mode against a throwaway
   project with a dummy `ANTHROPIC_API_KEY`, once per `DOCKER_SOCKET` value, and
   asserts:
   - exit status 0 and the dry-run banner both times;
   - with `0`: the bootstrap line that says there is no Docker socket, the no-Docker
     note in the printed builder prompt, and, through an entrypoint override, that
     `docker info` fails inside the container;
   - with `1`: the bootstrap line that says the daemon is reachable, and no no-Docker
     note in the prompt.

   Requirements: it exits 0 with a single `SKIP` line when no Docker daemon is
   reachable; it never replaces the image that real runs use (deliverable 5); it cleans
   up its temporary project and credentials file; it prints what failed and exits
   non-zero on any failed assertion. One portability point matters on GitHub's runners:
   the user there has uid 1001, while the container's `node` user has uid 1000 and must
   be able to write the project. Create the throwaway project's `.phase-runner/state/logs`
   and `.phase-runner/home` up front and make the whole throwaway project
   world-writable before invoking the CLI.
5. **`RUNNER_IMAGE`.** `docker-compose.yml` names the image as
   `${RUNNER_IMAGE:-claude-phase-runner:latest}` and the CLI inspects that same name.
   The default is unchanged. The smoke test sets it to a tag of its own. This is an
   environment override for testing, documented in the README under "Iterating on the
   kit", not a per-project setting for the template.
6. **Remove the dead statement** in `load_config`.
7. **README, "Iterating on the kit":** what CI runs, the lint scenario and its skip, how
   to run the smoke test locally and what it leaves behind, `RUNNER_IMAGE`.

## Reference: the manual check that `tests/smoke.sh` replaces

This worked on a host with Docker on 2026-10-04. `$KIT` is the kit, `$P` a throwaway git
repository with `plan/ENTRY.md` and `plan/A.md`, `$S` a scratch directory holding a
credentials file with a dummy key. The dry runs should go through the real CLI
(`PHASE_RUNNER_CREDENTIALS=... bin/phase-runner --project "$P" build --dry-run` with
`DOCKER_SOCKET` set in the throwaway project's `runner.env`); the probe needs compose
directly, with the variables the CLI would export:

```bash
run() {  # run DOCKER_SOCKET HOST_DOCKER_SOCK command...
  local ds="$1" hs="$2"; shift 2
  ( cd "$KIT" && CREDENTIALS_FILE="$S/creds.env" PROJECT_DIR="$P" ENTRY_FILE=plan/ENTRY.md \
      PHASE_FILES=plan/A.md AGENT_HOME="$S/home" HOST_SSH_AUTH_SOCK=/dev/null \
      RUNNER_MODE=dry-run PUSH=0 DOCKER_SOCKET="$ds" HOST_DOCKER_SOCK="$hs" "$@" )
}
# with 0, even root in the container has no daemon
run 0 /dev/null docker compose -f docker-compose.yml run --rm -T --entrypoint bash runner \
  -c 'docker info >/dev/null 2>&1 && echo REACHABLE || echo UNREACHABLE'      # UNREACHABLE
run 0 /dev/null docker compose -f docker-compose.yml run --rm -T runner
run 1 /var/run/docker.sock docker compose -f docker-compose.yml run --rm -T runner
```

Lines observed, with colour codes stripped:

```
✓ No Docker socket (DOCKER_SOCKET=0) — the agent cannot reach the host daemon.
▶ Retry schedule: 30 300 3600 10800s; stall timeout: 1800s; guard hook: on; docker socket: off
▶ DRY RUN — the builder prompt for the first pending phase (plan/A.md) follows. No agent is launched.
No Docker in this run: the host's Docker socket is not mounted (`DOCKER_SOCKET=0` in ...
```

and with `1`: `✓ Docker daemon reachable as 'node' (docker-out-of-docker enabled).`,
`docker socket: on`, and no "No Docker in this run" anywhere in the output. Earlier
phases of this batch add lines to the banner; assert on fragments, not whole lines.

## Out of scope

- Releases, tags, a changelog, a licence file.
- Running real agents in CI, or anything that needs a credential.
- Making the container work for host users other than uid 1000.
- Removing the legacy fallbacks (`PHASE_FILES` in `runner.env`, credentials in the kit
  directory, the migration section of the README).

## Definition of Done

- [ ] `shellcheck -x -S warning` over the scripts listed in deliverable 1 exits 0 in
      this container, and `grep -rn 'shellcheck disable' bin docker tests` shows only
      single-line directives, each with a reason.
- [ ] The lint scenario is part of `bash tests/run.sh`, builds its file list from the
      directories, and has a code path that prints `SKIP` and passes when `shellcheck`
      is not found.
- [ ] `.github/workflows/ci.yml` triggers on push and pull request, has the two jobs
      with the commands of deliverable 3, declares minimal permissions, and every
      `uses:` reference is a tag that exists upstream. The report says how each tag was
      verified.
- [ ] `bash -n tests/smoke.sh` succeeds, the script is covered by the lint scenario,
      and in this container `bash tests/smoke.sh; echo "rc=$?"` prints one `SKIP` line
      and `rc=0`.
- [ ] Reading `tests/smoke.sh` shows every assertion of deliverable 4, the uid
      preparation, the cleanup and the use of `RUNNER_IMAGE`.
- [ ] `docker-compose.yml` uses `${RUNNER_IMAGE:-claude-phase-runner:latest}`; with the
      fake `docker`, a CLI scenario shows that `RUNNER_IMAGE=x:y` is the name the CLI
      inspects and that the default is `claude-phase-runner:latest`.
- [ ] `PROJECT_DIR_FROM_ENV` no longer appears in the repository.
- [ ] The README section covers CI, lint, the smoke test and `RUNNER_IMAGE`, and says
      that the smoke test's main path was not executed during this phase.
- [ ] The report lists, under blockers or notes, that `tests/smoke.sh` and the `smoke`
      CI job still have to be run by the human.
- [ ] Gate green.
