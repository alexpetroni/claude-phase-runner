[claude-phase-runner](../README.md) · [Documentation](README.md)

# Troubleshooting

| Symptom | Cause / fix |
|---|---|
| The tmux scrollback is gone and you don't know what the run did or why it stopped | `phase-runner logs driver`: every line the driver printed, timestamped, across runs — retries, usage-limit waits, red gates, verdicts, the final `FAIL` line. The `Run stopped with …` rows below are all there. |
| `no credentials file` | Create `~/.config/claude-phase-runner/credentials.env` from the template with exactly one of `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`. |
| `no config at .phase-runner/runner.env` | Run `phase-runner init` in the project, or pass `--project DIR`. |
| Claude Code has no `/phase-runner`, or writes a plan in a format of its own | The skill is not linked: `phase-runner install` (`phase-runner init` says so too). Claude Code picks the new skill up in the running session. |
| Phase BLOCKED after fix rounds | Read `state/reviews/<phase>.md`. Fix the plan or the code yourself, or raise `MAX_FIX_ROUNDS`, then re-run: the phase restarts from its prompt on the committed state. |
| Builder reported blocked | Read `state/reviews/<phase>.blocked.md`; it names what it needs. Provide it (credentials, a decision, a package), re-run. |
| `push failed 3 times` | No SSH agent forwarded (`ssh-add -l` in the launching terminal must list the key; a new agent is empty and replaces the keyring's agent for that terminal, so `eval $(ssh-agent); ssh-add` only when there is none at all) / bad token in the remote URL. Fix, re-run — the backlog pushes first. With `PUSH=1` the driver checks the remote before the first agent (`Push remote … is NOT reachable` warning in the first minute, details in `logs/push.log`), so this is usually visible at the start of the run. |
| Killed as stalled during a long docker build / test suite | Raise `STALL_TIMEOUT`. The retry resumes the same session, so little is lost. |
| Builder reports "verification still running", "cut off" or "the turn was force-ended" | A Bash call outran its timeout and went to the background, where nothing wakes the agent up. With the defaults (`BACKGROUND_TASKS=0`, `BASH_TIMEOUT=600`, maximum `STALL_TIMEOUT` − 300) this cannot happen; if the project sets its own values, check the banner line `Bash tool: …` (on the terminal or in `phase-runner logs driver`), raise `BASH_TIMEOUT_MAX` (and `STALL_TIMEOUT` with it) above the slowest command, and keep `BACKGROUND_TASKS=0`. |
| Agent can't reach its own services on `127.0.0.1` | DooD: use `host.docker.internal:PORT`, or attach test containers to the app's compose network. |
| `Cannot connect to the Docker daemon` in the transcript, or the builder reports blocked asking for `DOCKER_SOCKET=1` | The project runs with `DOCKER_SOCKET=0` (the template default). If its phases or gate really need containers, set `DOCKER_SOCKET=1` in `runner.env` and re-run. |
| `refusing to start a container with the kit as the project` | The project directory is the kit itself, whose code is mounted live into the run. Run a frozen clone's `bin/phase-runner` with `--project` pointing here, see [Building the kit with the kit](development.md#building-the-kit-with-the-kit). |
| `guard … BLOCKED` lines in the transcript | Working as intended. If a legitimate command is caught, add a narrower rule + a test case in `tests/guard.sh`. |
| A completed phase runs again | Its manifest path changed, or the state was reset. |
| Killed the tmux window or closed the terminal instead of pressing Ctrl-C | The container keeps running with no terminal attached. `docker ps`, then `docker stop <id>` on the `claude-phase-runner-runner-run-…` container; it removes itself. Then `phase-runner build` resumes. See [Stopping a run](resume.md#stopping-a-run). |
| Need python/go/rust in the image | `EXTRA_APT_PACKAGES="python3 python3-pip"` in `runner.env`; the image rebuilds on the next run. |
| Reviewer verdicts feel shallow | Sharpen the phase's Definition of Done (see [skills/phase-runner/WRITING-PHASES.md](../skills/phase-runner/WRITING-PHASES.md)) and set `REVIEW_MODEL`/`REVIEW_EFFORT` higher than the builder's. |
| A phase costs far more than its size suggests | Read the transcript for repeated full test runs and big output dumps; lower that phase's `effort=` in `phases`, set `BASH_OUTPUT_MAX_CHARS`, see [Cost](cost.md). |
| Run stopped with `usage limit: the … window resets at …` | The reset was further away than `LIMIT_WAIT_MAX`, so the driver stopped instead of sleeping. Re-run `phase-runner build` after the time it names — the run resumes where it stopped — or raise `LIMIT_WAIT_MAX` above the distance to have the runner wait. A reset within `LIMIT_WAIT_MAX` is waited out automatically, whatever the CLI's wording ("hit your session limit", "out of usage credits · resets …"). |
| Run stopped with `out of usage credits — top up …` | The CLI sent no rejected `rate_limit_event` with a reset time, so there is nothing to wait for: top up, wait for the window yourself, or switch to API billing. |

