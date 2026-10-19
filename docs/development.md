[claude-phase-runner](../README.md) · [Documentation](README.md)

# Developing the kit

## Layout

```
bin/phase-runner          host CLI: install · init · build · preflight · review · status · logs · reset
docker/Dockerfile         node 24 + git + docker CLI + pnpm + jq + Claude Code (pinnable)
docker/bootstrap.sh       root entrypoint: socket group, git identity, trust, drop to node
docker/driver.sh          the phase loop: builder → gate → reviewer → fix rounds → push
docker/lib/               claude.sh (roles, retries, watchdog) · git.sh · common.sh · renderers
docker/guard.sh           the enforcement hook (per-role rules, tested)
prompts/*.md              builder, fix (fresh or resumed), reviewer, preflight, final-review instructions, the rules and no-Docker notes — edit freely
skills/phase-runner/      the Claude Code skill that writes the plan: SKILL.md (the procedure), WRITING-PHASES.md (the guide), ENTRY.md and PHASE.md (skeletons); `install` links it into ~/.claude/skills
templates/                runner.env, phases, credentials.env — what `init` and `install` copy
docs/                     the documentation; README.md is its index
self-build/               the kit's own build plan: ENTRY.md, phases/, and the runbook README.md (see Building the kit with the kit)
tests/                    bash tests/run.sh — driver, CLI, lint and guard tests with a fake `claude`; smoke.sh — the real container, dry run, no API call
.github/workflows/ci.yml  both on every push and pull request: run.sh (job `test`) and smoke.sh (job `smoke`)
docker-compose.yml        container definition (same-path repo mount, optional host Docker socket, agent home)
```

## Iterating on the kit

`docker/` and `prompts/` are bind-mounted over the baked copies, so driver,
library, guard and prompt edits take effect on the next run without a rebuild.
`docker/Dockerfile` changes rebuild automatically (a cache hit when nothing
changed).

Tests need no Docker and no token: `bash tests/run.sh` runs a fake `claude`
(`tests/bin/claude`) through every scenario — happy path, reviewer FAIL → fix
→ PASS, exhausted rounds, red gate, transient retry with session resume and
once-counted cumulative cost, stall, no-session restart, usage limits (the
five-hour wait under either wording with the real event shape, the weekly
stop with its message in the output and `SUMMARY.md` and the same window
waited out under a raised `LIMIT_WAIT_MAX` — the fake's windows reset 8
seconds ahead, `FAKE_LIMIT_RESET_IN` from a scenario, so a driver delayed by a
few seconds still finds the reset ahead —, a `LIMIT_WAIT_GRACE` above zero
lengthening the announced wait and an invalid one stopping the run before
any agent, the no-event out-of-credits stop,
a reset already passed, a stale rejection seeded in the log by an earlier run,
an allowed event), blocked builder, resume after an interruption (builder
skipped), per-phase manifest options, per-role model/effort, subagent model
and output cap, `FIX_CONTEXT=resume` with fallback, dry run, two phases,
committed verdicts, reviewer leaving files, uncommitted leftovers, preflight,
final review, the host CLI (`install` into a scratch `HOME`: the two links, the
credentials file created then kept, an existing skill directory left alone;
`init`'s next steps with and without the skill and the credentials; `status`'s
`missing` state and its `Next:` line in every state), the `DOCKER_SOCKET` switch (with a fake `docker`),
`RUNNER_IMAGE` as the image name the CLI inspects (default
`claude-phase-runner:latest`), the CLI refusing to build the kit itself, the Bash tool settings (defaults
and explicit values as every role's process receives them, derived defaults
from a small `STALL_TIMEOUT`, invalid values stopping the run before any
agent, the banner line and the minutes stated in the prompts), the driver log
(every terminal line of a run mirrored in order with timestamp and level, the
`INFO`/`WARN`/`FAIL` lines of a retry, a red gate and a `die`, two runs
appending under two headers, an unwritable file not failing the build, and
`logs`, `logs driver` and `status` on the host), the SSH agent (every role's
process and the gate without `SSH_AUTH_SOCK` while a `pre-push` hook sees the
driver's value and the push to a bare remote succeeds; the early push-access
check: one line for a reachable remote, a warning naming an unreachable one
in `preflight` with no push attempted whose advice checks `ssh-add -l` and
warns about an empty agent before saying how to start one — as the CLI's
warning for an SSH remote without an agent does —, a remote that needs credentials —
`tests/bin/git-remote-needsauth`, a helper that asks git for credentials like
`git-remote-https` on a 401 — failing at once with git's `terminal prompts
disabled` error in `logs/push.log`, nothing contacted with `PUSH=0`) — plus every
guard rule and the lint scenario below. The suite
ignores the caller's environment: it re-executes itself once under `env -i`
with only `PATH`, `HOME` and `TMPDIR`, so exported runner settings (inside a
runner container, or on your machine) cannot change what a scenario asserts;
a canary scenario at the start checks that none of the `environment:` keys of
`docker-compose.yml` is present. Add a scenario with each behaviour change.

### CI, lint and the container smoke test

`.github/workflows/ci.yml` runs on every push and pull request, with no
secret and `contents: read` only, two independent jobs on `ubuntu-latest`:
`test` installs `jq` and `shellcheck` and runs `bash tests/run.sh`; `smoke`
runs `bash tests/smoke.sh`. The actions are pinned to released tags
(`actions/checkout@v7.0.1`, checked against `git ls-remote --tags` and the
releases API when it was pinned).

**Lint** is a scenario of `tests/run.sh`: `shellcheck -x -S warning` over
every shell script of the kit — `bin/*`, `docker/*.sh`, `docker/lib/*.sh`,
`tests/*.sh`, `tests/bin/*`, a list built from the directories, so a new
script is covered without editing the test. The kit is clean at that level;
a finding shellcheck cannot judge (a global set in one file and read in a
sourced one) is silenced on that line only, with a comment saying where the
variable is read. Without `shellcheck` on `PATH` the scenario prints one
`SKIP` line and passes, so the suite still runs anywhere; the skip path is
itself exercised with `shellcheck` hidden.

**The smoke test**, `tests/smoke.sh`, is the real container end to end with
no API call: it builds the image, then runs the real CLI in `build --dry-run`
mode against a throwaway project with a dummy `ANTHROPIC_API_KEY`, once per
`DOCKER_SOCKET` value, and checks the lines only a container shows — the
bootstrap's socket line, the dry-run banner and the no-Docker note in the
printed builder prompt (present with `0`, absent with `1`). With `0` it also
starts the container with an entrypoint override and checks that `docker
info` fails inside. The throwaway project is created with `state/logs` and
`home` in place and made world-writable first, because the container's
`node` user is uid 1000 and the host user may not be (GitHub's runner is
1001). Run it locally with Docker available:

```bash
bash tests/smoke.sh          # a few minutes the first time (image build), seconds after
```

Without a reachable daemon it prints one `SKIP` line and exits 0. It leaves
one thing behind, the image `claude-phase-runner:smoke` (a cache hit on the
next run; `docker image rm claude-phase-runner:smoke` drops it); the
throwaway project and the credentials file are removed on exit, and on a
failed assertion it prints the last lines of each log and exits non-zero.
The tag comes from **`RUNNER_IMAGE`**: `docker-compose.yml` names the image
`${RUNNER_IMAGE:-claude-phase-runner:latest}` and `bin/phase-runner`
inspects that same name, so an exported `RUNNER_IMAGE` makes a run build and
use a tag of its own while real runs keep `claude-phase-runner:latest`. It is
an environment override for testing, not a `runner.env` setting.

Status: the smoke test was written in a run without a Docker daemon and
checked statically only (`bash -n`, the lint scenario, its `SKIP` path); its
main path has not been executed yet. Run `bash tests/smoke.sh` once on a host
with Docker, or watch the first `smoke` job in CI, and remove this note.

### Building the kit with the kit

`docker-compose.yml` mounts the kit's own `docker/` and `prompts/` live into
the container, so when the project being built is the kit directory itself,
the builder's edits change the runner while it runs: `driver.sh` is executed
incrementally from the file, prompts are re-read for every role, and a
half-edited `guard.sh` exits 2 and blocks every tool call, including the one
that would repair it. `bin/phase-runner` therefore refuses `build`,
`preflight` and `review` when the project and the kit are the same directory
(`init`, `status`, `logs` and `reset` still work). Run the kit from a frozen
clone instead:

```bash
git clone /path/to/claude-phase-runner /tmp/phase-runner-frozen
/tmp/phase-runner-frozen/bin/phase-runner --project /path/to/claude-phase-runner build
```

The clone is what runs; the checkout under `--project` is what gets edited,
committed and pushed. Re-clone (or `git pull` in the clone) when you want the
runner to pick up kit changes.

The kit's own plan lives in `self-build/`, apart from the documentation:
`self-build/ENTRY.md` is the entry file, `self-build/phases/` holds the phase
files of the October 2026 hardening batch, and
[`self-build/README.md`](../self-build/README.md) is the runbook for that
batch. The kit's `.phase-runner/runner.env` points `ENTRY_FILE` there.
