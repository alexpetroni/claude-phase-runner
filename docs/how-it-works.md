[claude-phase-runner](../README.md) · [Documentation](README.md)

# What happens in a phase

**1. Builder.** One `claude -p` run with a fresh context. Prompt = your entry
file + `prompts/build.md`: execute exactly this phase, commit as you go, do not
verify yourself, do not leave anything running in the background, return a
structured report (`done` or `blocked`, summary, commits, blockers). A builder
that reports `blocked` **without having committed anything** stops the run
honestly: the phase is recorded in `state/blocked`, and
`state/reviews/<phase>.blocked.md` holds its report. A `blocked` report *with*
new commits is treated as a claim, not a verdict — builders used to finish
the work, start the suite in the background, report "verification still
running" as a blocker and end the turn — so the phase goes through gate and
review like any other, with the report attached to any fix round. A genuine
blocker then surfaces as a `FAIL` and, at worst, one more blocked report from
the fix round with nothing new committed, which does stop the run.

The runner removes the cause of that pattern rather than only catching it.
Claude Code moves a Bash call that outruns its timeout (120 s by default) to
the background and tells the agent it "will be notified when it completes";
in a headless `claude -p` run nothing ever does, and the turn ending is the
end of the run. So every role's `claude` process gets a long default timeout
(`BASH_TIMEOUT`, 600 s), a maximum the agent may ask for that stays under the
stall watchdog (`BASH_TIMEOUT_MAX`, `STALL_TIMEOUT` − 300 s), and Claude
Code's background tasks switched off (`BACKGROUND_TASKS=0`:
`run_in_background` and the automatic move to the background both disabled).
The rules block tells the agent the same thing: run everything in the
foreground with an explicit `timeout` up to the maximum, start a server it
needs with the shell's `&` and stop it before finishing, and split or report a
command that cannot finish in time. The driver validates explicit values at
start-up and prints the resolved ones in its banner (`Bash tool: default
timeout 600s, maximum 1500s; background tasks: off`). The switches
(`BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS`,
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`) were checked against Claude Code
2.1.263.

**2. Checkpoint.** Anything the builder left uncommitted is committed as
`chore(runner): checkpoint uncommitted work after <phase>`.

**3. Gate.** `GATE_CMD` from the project root, logged to
`state/logs/<phase>.gate.r<N>.log`, with stdin closed and a `GATE_TIMEOUT`
cap, so a tool that asks a question (corepack's download prompt) fails
instead of hanging on the driver's terminal. Red → a fix round with the output
in the prompt. The gate proves *green*, not *done*; that is the reviewer's job.

**4. Reviewer.** A second `claude -p` run with a fresh context, `Edit`/`Write`
disabled, and the guard hook refusing every git mutation. It gets the entry
file, the phase file, the commit list and diffstat of the phase, and the gate
output. Its instructions (`prompts/review.md`): list every Definition of Done
item verbatim, verify each one *itself* against the repository — read the
changed files and tests, grep, run the specific tests an item needs (the gate's
green run is the runner's own evidence, so it does not repeat the whole suite)
— treating the builder's commit messages, notes
and any self-written verification files as claims, not proof; hunt for skipped
or vacuous tests, weakened existing tests, swallowed errors, broken entry-file
invariants, out-of-scope work; review the diff for correctness with `file:line`
findings and concrete fixes; no style nits. `PASS` only if every DoD item holds
and there is no critical or high finding. The verdict is structured JSON,
rendered to `state/reviews/<phase>.md` (DoD table with evidence + findings). If
the reviewer leaves anything in the working tree it is discarded — everything
was committed before it ran. (Read-only passes only ever discard what they
added themselves: `preflight` on a tree holding a failed builder's uncommitted
files leaves those files alone.)

**5. Fix rounds.** On a red gate or a `FAIL`, the builder comes back with the
exact gate output or verdict and fixes forward, commits; then gate and reviewer
run again. `FIX_CONTEXT=fresh` (default) gives it a new context and the full
prompt (`prompts/fix.md`); `FIX_CONTEXT=resume` continues the builder's own
session with a short prompt (`prompts/fix-resume.md`) — see [Cost](cost.md) for
when that is cheaper. Fix rounds can run at their own model/effort
(`FIX_MODEL`, `FIX_EFFORT`): they start from a failure signal, so spending more
there than on the first attempt is the efficient shape. `MAX_FIX_ROUNDS`
(default 2) caps this. When it is exhausted the phase is recorded as blocked, the work
is pushed so nothing is lost, and the run stops for you: read
`state/reviews/<phase>.md`, decide, re-run (the phase restarts from its prompt
on top of the committed state).

**6. Done.** The phase is appended to `state/phases-done` and the branch is
pushed. With `COMMIT_REVIEWS=1` the latest verdict is also committed into the
repository as `docs/verification/<phase>.md` first.

Why the reviewer is a separate process and not a subagent the builder spawns:
a reviewer briefed by, and reporting to, the thing under review is not
independent. In practice builders end their turn with "the gate is running in
the background, I'll report when it finishes" — and the run ends. Here the
builder's job is the work; deciding whether the work is done belongs to
something that shares none of its context and cannot edit.

## Preflight and final review

Both are read-only passes run by the same machinery (fresh context, no edit
tools, guard hook); the agent returns the report and the driver writes it.

- `phase-runner preflight` before a long build: which skills, MCP servers,
  plugins, apt packages, and credentials each phase needs, and how to provision
  each — secrets into the credentials file, packages into
  `EXTRA_APT_PACKAGES`, skills into `.phase-runner/home/`, MCP servers into the
  project's `.mcp.json`, a Docker daemon via `DOCKER_SOCKET=1` (and
  `DOCKER_SOCKET=0` when no phase needs containers). The unattended runner
  cannot authenticate mid-build, so anything needing a secret must be in place
  before launch.
- `phase-runner review` after the build: a prioritized list of what to
  improve, simplify or harden, each item with severity and the concrete fix,
  written to `state/REVIEW.md`. Turn the findings you accept into new phase
  files, append them to `.phase-runner/phases`, run `build` again — resume
  skips the done phases. Customize the lens with `REVIEW_PROMPT`.

