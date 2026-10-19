[claude-phase-runner](../README.md) · [Documentation](README.md)

# Configuration — `.phase-runner/runner.env`

All paths are relative to the project root. Phases are listed in
`.phase-runner/phases` (one per line, `#` comments). What `init` creates and
what a run writes is laid out in
[Setup](setup.md#what-init-creates-and-what-a-run-writes).

| Variable | Default | Meaning |
|---|---|---|
| `ENTRY_FILE` | — (required) | Entry/constitution prompt, prepended to every builder, reviewer and report prompt. |
| `GATE_CMD` | empty | Independent verification command run after every builder run. Empty = no gate. |
| `PHASE_REVIEW` | `1` | Run the independent reviewer after every phase. `0` = gate only. |
| `MAX_FIX_ROUNDS` | `2` | Fix rounds per phase before it is recorded as blocked. |
| `COMMIT_REVIEWS` / `REVIEWS_DIR` | `0` / `docs/verification` | Also commit the latest verdict into the repository. |
| `CLAUDE_MODEL`, `CLAUDE_EFFORT` | `claude-fable-5-1`, `xhigh` | Model/effort for every role when nothing more specific is set. |
| `BUILD_MODEL`, `BUILD_EFFORT` | ↑ | The builder's first attempt (template: `claude-opus-5-5`, `high`). |
| `FIX_MODEL`, `FIX_EFFORT` | builder's | Fix rounds (template: `claude-fable-5-1`, `xhigh` — spend more after a failure signal). |
| `REVIEW_MODEL`, `REVIEW_EFFORT` | ↑ | The reviewer, preflight and final review (template: `high`). |
| `SUBAGENT_MODEL` | inherit | Model for subagents the agents spawn when their definition names none (template: `claude-sonnet-5-5`). |
| `BASH_OUTPUT_MAX_CHARS` | Claude Code's 30000 | Inline characters of a Bash result; the rest is saved to a file the agent can grep (template: 16000). |
| `FIX_CONTEXT` | `fresh` | `resume` continues the builder's session for fix rounds instead of a new context. |
| `BUILD_BUDGET_USD`, `REVIEW_BUDGET_USD` | none | Hard spend cap per agent run. |
| `RETRY_SCHEDULE` | `30 300 3600 10800` | Seconds before each retry after a transient failure. The list's length is the retry count. |
| `LIMIT_WAIT_MAX` | `21600` | Longest wait for a subscription usage window to reset. A rejected `rate_limit_event` whose reset is within this many seconds is waited out and the same session resumed; one further away stops the run at once, naming the reset time. |
| `LIMIT_WAIT_GRACE` | `60` | Seconds added to every such wait before the session is resumed: the reset time is the server's and the clocks differ, so resuming on the dot can be rejected once more. A non-negative integer. |
| `STALL_TIMEOUT` | `1800` | Kill + retry an agent that printed nothing for this long. Keep above your slowest silent step: a foreground Bash call prints nothing until it ends, so it also bounds `BASH_TIMEOUT_MAX` (the derived default is `STALL_TIMEOUT` − 300). |
| `BASH_TIMEOUT` | `600`, capped at `BASH_TIMEOUT_MAX` | Seconds a Bash tool call may run when the agent passes no timeout (`BASH_DEFAULT_TIMEOUT_MS` to Claude Code, whose own default is 120). Must be a positive integer not above `BASH_TIMEOUT_MAX`. |
| `BASH_TIMEOUT_MAX` | `STALL_TIMEOUT` − 300, never below `120` | The longest timeout an agent may ask for (`BASH_MAX_TIMEOUT_MS`); the prompts state it in minutes. Must be a positive integer below `STALL_TIMEOUT`, or the watchdog would kill a legitimately long command. |
| `BACKGROUND_TASKS` | `0` | `0` disables Claude Code's background tasks (`run_in_background` and the automatic move of a slow command to the background), which end a headless run with "verification still running". `1` leaves Claude Code's own behaviour. See [What happens in a phase](how-it-works.md). |
| `GATE_TIMEOUT` | `3600` | Kill the gate command after this long (it is not an agent, the stall watchdog does not cover it). The gate runs with stdin closed, so anything that prompts fails fast. |
| `PUSH`, `GIT_REMOTE`, `GIT_BRANCH` | `1`, `origin`, current | Push after every verified phase. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | `Phase Runner` / `runner@phase.local` | Identity for runner commits. |
| `EXTRA_APT_PACKAGES` | empty | Extra apt packages baked into the image. |
| `CLAUDE_CODE_VERSION` | `latest` | Pin the Claude Code version in the image. |
| `AGENT_HOME` | `.phase-runner/home` | Mounted as the agent's `~/.claude`: put `skills/`, `agents/`, plugins there. Sessions persist here too. |
| `DOCKER_SOCKET` | `1` | `1` mounts the host's Docker socket so the agent can run the project's stack and test containers on the host daemon. `0` mounts nothing: the agent has no daemon, runs everything as plain processes in the runner container, and reports `blocked` if a phase needs containers. The socket is effectively host-root, so the template ships `0` — see [Security model](security.md). |
| `REVIEW_PROMPT` | built-in | The final review's instruction (entry file still prepended). |
| `GUARD` | `1` | `0` disables the enforcement hook. Not recommended. |

Credentials are resolved from `$PHASE_RUNNER_CREDENTIALS`, then
`~/.config/claude-phase-runner/credentials.env`. They are the agent's own
secret store, deliberately outside the project, so the agent can manage the
project's `.env` files without ever seeing its token.

## The entry file and the phase files

How to write them — cutting a project into phases, what belongs in the entry
file, what makes a Definition of Done checkable, the manifest, the checks
before the first run — is in
[skills/phase-runner/WRITING-PHASES.md](../skills/phase-runner/WRITING-PHASES.md),
with the `ENTRY.md` and `PHASE.md` skeletons next to it. That directory is the
`/phase-runner` skill, so what Claude follows when you ask it to write the
phases is what you read to do it by hand. In short:

**The entry file** is read first and prepended to every prompt. Put in it: the
mission and what "done" means for the product; the binding engineering rules
(test policy, lint gates, commit conventions, forbidden patterns, mock rules
for external services); the exact verification commands. Keep phase scoping
out — the runner appends it. Do **not** ask the builder to spawn a
verification subagent or write PASS files any more: the runner's reviewer does
that, with a context the builder cannot influence, and self-issued verdicts
are ignored.

**The phases manifest** lists the phase files in order; a line may carry
per-phase overrides after the path — `model=` `effort=` for the builder,
`fix_model=` `fix_effort=` for its fix rounds, `review_model=` `review_effort=`
for its reviewer:

```
docs/phases/PHASE-2-CORE-ENGINE.md   model=claude-fable-5-1
docs/phases/PHASE-7-RELEASE.md       model=claude-sonnet-5-5 effort=medium review_effort=medium
```

Put the top model on the phases that need it rather than on all of them;
`phase-runner build --dry-run` prints the resolved roles per phase.

**Each phase file** is one self-contained slice: deliverables, steps, and an
explicit **Definition of Done** the reviewer can check item by item. The
better the DoD, the better the verdict: "all 37 ported tests pass, none
skipped" is checkable; "the engine works" is not. If a phase has no explicit
DoD the reviewer derives one from the deliverables and says so.

**The skill.** `phase-runner install` links `skills/phase-runner/` into
`~/.claude/skills/` as a personal skill: every Claude Code session on the
machine has `/phase-runner`, and Claude loads it on its own when you ask for
phases or a plan for the runner. The procedure: check the kit and the
repository, run `phase-runner init`, ask whatever is still open in one message,
write the entry file and the phase files by the guide, fill the manifest and the
gate, hand over the next steps. It does not commit and does not start Docker.
After a blocked phase the same request revises the plan from the verdict. The
agents inside a run never see it: their home is `.phase-runner/home`, not
yours.

**Networking note for verification steps:** with `DOCKER_SOCKET=1` the agent
starts the project's stack as *sibling* containers (docker-out-of-docker), so
their published ports live on the **host** — from inside the runner container
they are reachable at `host.docker.internal:PORT`, not `127.0.0.1`. Say so in
the entry file if the agent has to curl its own services. With
`DOCKER_SOCKET=0` there are no containers: services are processes inside the
runner container and `127.0.0.1` is correct.

**MCP servers, skills, plugins.** A project `.mcp.json` is picked up
automatically (the project is trusted at boot). User-level skills and agents go
into `.phase-runner/home/skills/` and `.phase-runner/home/agents/`.

