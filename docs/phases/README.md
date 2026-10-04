# Hardening batch, October 2026 — how to run it

Six phases that the runner executes on its own repository. `docs/ENTRY.md` is the entry
file, the phase files are in this directory, and the project configuration is in
`.phase-runner/` (not committed).

| Phase | What it fixes | Evidence |
|---|---|---|
| 0 Self-hosting | The suite ignores its caller's environment; the CLI refuses to build the kit from its live copy | 200 of 317 assertions fail inside a runner container |
| 1 Foreground Bash | Agents are no longer cut off while their own gate runs in the background | 3 of the last 7 builds in one project ended in a forced `blocked` report |
| 2 Usage limits | Limits are judged by the CLI's event, scoped to the attempt, and a stop says when to come back | Real stops that today's code would not wait for |
| 3 Driver log | The runner's own narrative is written to `state/logs/driver.log` | Retries and waits exist only in terminal scrollback |
| 4 SSH agent | Agents and the gate lose the forwarded SSH agent; the guard blocks SSH | The agent socket reaches every role today |
| 5 CI, lint, smoke | shellcheck in the suite, a GitHub Actions workflow, a container smoke test | No automated check exists |

## Run it from a frozen clone, never from this checkout

The kit's `docker/` and `prompts/` are bind-mounted live into the container. If the kit
runs on its own checkout, the builder edits the runner that is running it, and a
half-edited `guard.sh` can block every tool call. So a second, untouched copy of the kit
does the running. PHASE-0 makes the CLI refuse the unsafe way; until it lands nothing
stops you, and the `phase-runner` on your `PATH` is a symlink into this checkout.

```bash
# 1. once: the frozen copy that runs the build (master as of this plan)
git clone --quiet ~/work/claude-phase-runner ~/work/claude-phase-runner-frozen
PR=~/work/claude-phase-runner-frozen/bin/phase-runner

# 2. a branch for the batch, with the plan committed
cd ~/work/claude-phase-runner
git switch -c improve/2026-10-hardening
git add docs && git commit -m "docs: plan for the October 2026 hardening batch"

# 3. check, then run — in tmux. The push remote is SSH: `ssh-add -l` must list
#    your key. A desktop keyring usually provides the agent already; do not start
#    a new one with `ssh-agent`, which would be empty and make every push fail.
ssh-add -l
$PR build --dry-run        # prints the PHASE-0 builder prompt, launches no agent
$PR build

# 4. watch, from another terminal in this directory
$PR status
$PR logs -f
```

Good to know:

- **The first run rebuilds the image.** `runner.env` adds `shellcheck` and pins Claude
  Code to 2.1.263, the version the September runs used and the phase files were checked
  against. Expect a few minutes.
- **Do not run other projects with the `phase-runner` on your `PATH` while the batch is
  running.** It points at this checkout, whose `docker/` and `prompts/` are being
  edited. Use `$PR --project <dir>` for them, or wait.
- **Every verified phase is pushed** to `origin` on the batch branch.
- **A blocked phase stops the run.** Read `.phase-runner/state/reviews/<phase>.md`,
  decide, and run `$PR build` again. Completed phases are skipped.
- **PHASE-0 runs with a gate that fails until its fix is in.** That is intended: the
  gate is the plain suite, and inside the container it only passes once the suite
  ignores the runner's variables.

## After the batch: what only you can verify

The runner has no Docker daemon and cannot observe a real agent run, so four things are
outside its reach.

1. `bash tests/run.sh` on the host.
2. `bash tests/smoke.sh` on the host. This is the first real execution of the smoke
   test; PHASE-5 could only check it statically.
3. The first GitHub Actions run after the push, both jobs.
4. One real run of a real project on the new kit. For PHASE-1, a build log of a project
   with a slow gate should contain no `moved to the background` and no
   `run_in_background`. For PHASE-2 and PHASE-3, the next usage-limit wait should show
   up in that project's `driver.log` with its reset time.

Then merge the branch into `master`, and delete the frozen clone or update it with
`git -C ~/work/claude-phase-runner-frozen pull`.

## Decisions that are still yours and are not in this batch

- The default effort in code, still `xhigh`. The template ships `high`.
- The default `FIX_CONTEXT`.
- Falling back to another model when a usage cap is hit, as the CLI suggests.
- Running the driver and the agent as different users, which would make PHASE-4 a hard
  boundary.
- `DOCKER_SOCKET=0` and the cost settings in the projects that predate them.
- Removing the fallbacks for the old layout.
