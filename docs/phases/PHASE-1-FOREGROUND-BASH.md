# PHASE-1 — Agents are cut off while their own verification runs in the background

## Problem

This is the main recurring failure in real runs. In one project, 3 of the 7 builds after
2026-09-05 ended with the builder reporting `blocked` although the work was finished:

- "The turn was force-ended by the harness while verification was still in progress ...
  the full `pnpm test:unit` run was still executing in the background"
- "The report was forced while the final full gate run ... was still inside `test:unit`"
- "The run was cut off before verification completed: the full gate was still
  executing"

All three phases then passed the runner's gate and the reviewer, one of them only after
a fix round for a failure the builder would have seen had it watched its own gate
finish. The logs show the same sequence each time:

1. A foreground command runs past the Bash tool's default timeout and Claude Code moves
   it to the background by itself. The tool result says: `Command did not complete
   within its 120s timeout and was moved to the background (ID: ...). ... You will be
   notified when it completes.`
2. Having learned that, the builder starts the project's gate (about 5 minutes) with
   `run_in_background: true`, and then a waiter loop, also in the background.
3. It ends its turn to wait for the promised notification. In a headless `claude -p`
   run with `--json-schema` nothing wakes it up: the turn ending is the end of the run,
   and the structured report is demanded on the spot.

`prompts/rules.md` already says "Do not leave commands running in the background and do
not end your turn while anything is still running". It did not prevent this, because the
tool's own message says the opposite and the default timeout pushes every slow command
into the background before the agent has chosen anything. The reviewer and the
report-only roles run under the same conditions.

Claude Code has switches for exactly this. In version 2.1.263, the version this run is
pinned to, the package contains the names `BASH_DEFAULT_TIMEOUT_MS`,
`BASH_MAX_TIMEOUT_MS` and `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`. Confirm what each one
does from the installed package (under `$(npm root -g)/@anthropic-ai/claude-code`) and
from the official documentation if you can reach it, without starting `claude`. If one
of them does not exist or does something else, say so in your report and use what does
exist.

## Deliverables

1. **Three settings, applied to the `claude` process of every role** (build, fix, review,
   preflight, final-review):

   | Setting | Default | Meaning | Reaches Claude Code as |
   |---|---|---|---|
   | `BASH_TIMEOUT` | `600`, capped at `BASH_TIMEOUT_MAX` | Seconds a Bash tool call may run when the agent passes no timeout. | `BASH_DEFAULT_TIMEOUT_MS` |
   | `BASH_TIMEOUT_MAX` | `STALL_TIMEOUT - 300`, never below `120` | The longest timeout an agent may ask for. | `BASH_MAX_TIMEOUT_MS` |
   | `BACKGROUND_TASKS` | `0` | `0` disables Claude Code's background tasks: `run_in_background` and the automatic move to the background. `1` leaves Claude Code's own behaviour. | `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` when `0`, nothing when `1` |

   The defaults change the behaviour of existing projects on purpose: the failure above
   happens with the settings they have today.
2. **Validation when the driver starts, before any agent is launched**, for values the
   project set explicitly: each timeout is a positive integer; `BASH_TIMEOUT` is not
   above `BASH_TIMEOUT_MAX`; `BASH_TIMEOUT_MAX` is below `STALL_TIMEOUT`, because a
   foreground command prints nothing while it runs and the stall watchdog would kill a
   legitimately long one; `BACKGROUND_TASKS` is `0` or `1`. A violation stops the run
   with a message naming the setting, its value and the rule. Derived defaults never
   stop a run: a project with a small `STALL_TIMEOUT` and no explicit timeouts must
   start.
3. **The driver's banner states the result** on a line of its own: the default and
   maximum Bash timeout in seconds and whether background tasks are on or off.
4. **`prompts/rules.md`: replace the background rule with guidance the tool cannot
   contradict.** It has to say, briefly and with the reason: every command runs in the
   foreground; anything slow gets an explicit `timeout`, up to the maximum, stated in
   minutes from the configured value; never `run_in_background` and never end the turn
   to wait, because in this run no notification ever arrives and the turn ending is the
   end of the run; a server or watcher the work needs is started with shell `&` and a
   log file, polled for readiness with a bounded retry, and stopped before finishing;
   a command that cannot finish within the maximum is split or reported, not
   backgrounded. Every statement must be true with `BACKGROUND_TASKS=1` as well.
   `prompts/review.md` gets the same point in one sentence, since the reviewer runs
   tests too and does not receive the rules block.
5. **Template, compose, README.** The three settings in `templates/runner.env` with the
   why, in `docker-compose.yml`, and in the README configuration table. In the README,
   also: the cost of a long silent command in the `STALL_TIMEOUT` row; the paragraph of
   "What happens in a phase" that describes builders ending their turn with the suite
   in the background, which should now say what the runner does about it; a
   Troubleshooting row for a builder that reports "verification still running" or "cut
   off"; and the Claude Code version the switches were checked against.

## Out of scope

- Per-phase overrides of the timeouts in the `phases` manifest.
- The gate command: it is not an agent and already has `GATE_TIMEOUT`.
- Changing `STALL_TIMEOUT` or how the watchdog works.
- The handling of a `blocked` report that comes with commits. It stays as the safety net.

## Definition of Done

- [ ] With the driver's default `STALL_TIMEOUT` of 1800 and none of the three settings
      present, the `claude` process of each of the five roles receives
      `BASH_DEFAULT_TIMEOUT_MS=600000`, `BASH_MAX_TIMEOUT_MS=1500000` and
      `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`. Scenarios assert it from what the fake
      `claude` recorded, for build, fix, review, preflight and final-review. (Note that
      `run_driver` passes `STALL_TIMEOUT=600` unless a scenario says otherwise.)
- [ ] `BASH_TIMEOUT=90 BASH_TIMEOUT_MAX=300` reaches the process as `90000` and
      `300000`; `BACKGROUND_TASKS=1` leaves `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`
      unset.
- [ ] With `STALL_TIMEOUT=700` and no explicit timeouts the run starts and the process
      receives a maximum of `400000` and a default of `400000`. With `STALL_TIMEOUT=200`
      and no explicit timeouts the run starts with a maximum of `120000`.
- [ ] Each of these stops the run before any agent is launched (zero fake invocations),
      with a message naming the setting: `BASH_TIMEOUT=abc`; `BASH_TIMEOUT=0`;
      `BASH_TIMEOUT=900 BASH_TIMEOUT_MAX=600`; `BASH_TIMEOUT_MAX=1800` with the default
      `STALL_TIMEOUT`; `BACKGROUND_TASKS=yes`.
- [ ] The banner line appears in the driver output with the resolved values, in a build
      and in a dry run.
- [ ] The builder and fix prompts contain the new guidance with the maximum in minutes
      taken from the configured value (25 by default), and no longer contain the old
      sentence. The reviewer prompt contains the one-sentence version. Scenarios assert
      both, including a non-default maximum.
- [ ] `docker-compose.yml` passes all three settings through; `templates/runner.env`
      and the README configuration table describe them; the README sections named in
      deliverable 5 are updated and name the Claude Code version that was checked.
- [ ] No existing assertion was removed. Assertions that pin the old sentence or the old
      banner may be updated, and the commit message says which.
- [ ] Gate green.
