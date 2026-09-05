# claude-phase-runner

Autonomous, phase-by-phase project builder. It runs Claude Code with
`--dangerously-skip-permissions` inside a sandboxed Docker container against a
target git repository, **one builder run per phase plan file**, and then has an
**independent reviewer** with a fresh context and no edit tools audit the phase
before it counts. Transient API errors and hangs are retried on an escalating
schedule, a killed run resumes where it stopped, and every verified phase is
committed and pushed.

Everything per-project lives **inside the target project** under
`.phase-runner/` (config, phase manifest, state, verdicts, logs), excluded from
git locally. The kit directory holds code only. Credentials are user-level.

```
phase-runner build  (host)  →  docker compose run  →  driver.sh, per phase file:
┌────────────────────────────────────────────────────────────────────────────┐
│ 1. BUILDER   fresh context, edit tools, guard hook   → structured report    │
│ 2. checkpoint commit (nothing in flight is ever lost)                       │
│ 3. GATE      your command, e.g. lint && typecheck && test                   │
│ 4. REVIEWER  fresh context, read-only, gets the diff → PASS / FAIL verdict  │
│      FAIL or red gate → FIX round (builder, fresh context, the findings)    │
│      ≤ MAX_FIX_ROUNDS, then the phase is BLOCKED and the run stops          │
│ 5. record phase done → git push                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

The one-sentence philosophy, borrowed from the Cadence setup: **prompts steer,
hooks enforce.** The builder is told not to push and not to verify itself; a
`PreToolUse` guard hook makes sure it *cannot* push, cannot rewrite history,
cannot touch the plan files, and that the reviewer cannot edit anything.

---

## Contents

```
bin/phase-runner          host CLI: init · build · preflight · review · status · logs · reset
docker/Dockerfile         node 24 + git + docker CLI + pnpm + jq + Claude Code (pinnable)
docker/bootstrap.sh       root entrypoint: socket group, git identity, trust, drop to node
docker/driver.sh          the phase loop: builder → gate → reviewer → fix rounds → push
docker/lib/               claude.sh (roles, retries, watchdog) · git.sh · common.sh · renderers
docker/guard.sh           the enforcement hook (per-role rules, tested)
prompts/*.md              builder, fix (fresh or resumed), reviewer, preflight, final-review instructions — edit freely
templates/                runner.env, phases, credentials.env starting points
tests/                    bash tests/run.sh — driver, CLI and guard tests with a fake `claude`
docker-compose.yml        container definition (same-path repo mount, DooD, agent home)

<project>/.phase-runner/  created by `phase-runner init`, excluded via .git/info/exclude
  runner.env              per-project configuration
  phases                  phase plan files, one per line, in order, with optional per-phase model/effort
  home/                   the agent's ~/.claude (skills, agents, plugins, sessions)
  state/phases-done       resume marker, one line per completed phase
  state/progress/         per-phase "builder finished" markers, so an interrupted run resumes at the gate
  state/blocked           phases the run gave up on, with the reason
  state/runs.tsv          one row per agent run / gate / push: outcome, seconds, cost, turns
  state/reviews/          <phase>.md + .json verdicts (latest), <phase>.r<N>.* per round
  state/logs/             <phase>.build.log (+ .txt transcript), .fix.rN, .review.rN, .gate.rN
  state/SUMMARY.md · TOOLING.md · REVIEW.md
```

## Quick start

```bash
# once per machine
ln -s "$PWD/bin/phase-runner" ~/.local/bin/phase-runner      # or add bin/ to PATH
mkdir -p ~/.config/claude-phase-runner
cp templates/credentials.env ~/.config/claude-phase-runner/credentials.env   # then add your token

# in the target project
cd ~/work/my-project
phase-runner init                    # creates .phase-runner/{runner.env,phases}
$EDITOR .phase-runner/runner.env     # ENTRY_FILE, GATE_CMD, models, push
$EDITOR .phase-runner/phases         # the plan files, one per line
phase-runner build --dry-run         # prints the exact first builder prompt, launches nothing
phase-runner preflight               # optional: what tooling/credentials the plan needs
phase-runner build                   # go (use tmux; Ctrl-C is safe at any time)
phase-runner status                  # any time, from another terminal
phase-runner logs -f                 # follow the live agent transcript
phase-runner review                  # after the build: adversarial review → REVIEW.md
```

Prerequisites: Docker with the compose plugin, `jq` on the host (for `logs`
and `status`), a target project that is a git repository, and a Claude Code
credential — a subscription OAuth token from `claude setup-token` or an
`ANTHROPIC_API_KEY`. For SSH push remotes, a running `ssh-agent` with the key
added (see [Pushing](#pushing)).

## Commands

| Command | What it does |
|---|---|
| `phase-runner init` | Create `.phase-runner/` in the project from the templates and exclude it from git. Idempotent. |
| `phase-runner build` | Run every pending phase (the default command). `--dry-run` validates everything, prints the first pending phase's builder prompt and exits. |
| `phase-runner preflight` | Read-only tooling assessment of the whole plan → `.phase-runner/state/TOOLING.md`. |
| `phase-runner review` | Read-only adversarial review of the finished project → `.phase-runner/state/REVIEW.md`. |
| `phase-runner status` | Table of phases: status, last verdict, fix rounds, cost, minutes. No container. |
| `phase-runner logs [PHASE] [-f]` | Readable transcript of the latest log, or the newest log matching PHASE. `-f` follows. |
| `phase-runner reset [--yes]` | Delete `.phase-runner/state`. Config, phases and the agent home stay. |

All commands take `--project DIR` (default: the git repository containing the
current directory).

---

## What happens in a phase

**1. Builder.** One `claude -p` run with a fresh context. Prompt = your entry
file + `prompts/build.md`: execute exactly this phase, commit as you go, do not
verify yourself, do not leave anything running in the background, return a
structured report (`done` or `blocked`, summary, commits, blockers). A builder
that reports `blocked` **without having committed anything** stops the run
honestly: the phase is recorded in `state/blocked`, and
`state/reviews/<phase>.blocked.md` holds its report. A `blocked` report *with*
new commits is treated as a claim, not a verdict — builders routinely finish
the work, start the suite in the background, report "verification still
running" as a blocker and end the turn — so the phase goes through gate and
review like any other, with the report attached to any fix round. A genuine
blocker then surfaces as a `FAIL` and, at worst, one more blocked report from
the fix round with nothing new committed, which does stop the run.

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
session with a short prompt (`prompts/fix-resume.md`) — see [Cost](#cost) for
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

### Cost

Roughly one reviewer run per phase on top of the build, and one builder + one
reviewer run per fix round. From real runs on Fable 5.1 at xhigh: build phases
cost $2–30 and take 8–80 minutes; the reviewer adds 15–30% of the builder's
cost; a fix round with a fresh context costs 30–55% of the build.
`phase-runner status` shows the per-phase totals (cost is the CLI's own
estimate; on a subscription the real constraint is the usage window).
`BUILD_BUDGET_USD` and `REVIEW_BUDGET_USD` cap a single run; hitting a cap is
an honest stop, not a retry.

**Where a builder run's money goes** (from the `result` events of real runs,
Fable 5.1 at xhigh, 1-hour prompt cache):

| Bucket | Share | Driven by |
|---|---|---|
| Output tokens (~40% of them thinking) | ~40% | effort level, number of turns |
| Cache writes: tool output entering the context once | ~40% | test/log dumps, file reads, the agent's own edits |
| Cache reads: the growing context re-read every turn | ~16% | turns × context size |
| Fresh input | <2% | the prompt |

**The levers, in order of impact — all configurable, see the table below:**

1. **Effort per role and per phase.** Fable 5.1's own guidance: `high` for most
   work, `xhigh` for the most capability-sensitive; `high` on Fable 5.1 still
   exceeds `xhigh` on the previous generation. The template ships
   `BUILD_EFFORT=high`, `FIX_EFFORT=xhigh` (re-run failures at the higher
   setting — same pass rate, about half the cost), `REVIEW_EFFORT=high`, and
   the `phases` manifest takes `effort=xhigh` for the hard phases and
   `model=claude-sonnet-5 effort=medium` for the trivial ones (a release cut,
   a config-only phase). With nothing set, every role runs Fable 5.1 at xhigh.
2. **Cheaper subagents.** `SUBAGENT_MODEL=claude-sonnet-5` routes the
   subagents the builder and reviewer spawn (Explore, general-purpose, test
   audits) to a cheaper model; an agent definition that names its own model
   still wins.
3. **Less tool output in the context.** `BASH_OUTPUT_MAX_CHARS` caps what a
   Bash result puts inline (the rest goes to a file the agent can grep), and
   `prompts/rules.md` tells the builder to iterate on single test files with
   a quiet reporter and run the full gate once, at the end — in one real run
   the builder ran the test suite 57 times. The reviewer is told the gate's
   green output is the runner's own evidence, so it does targeted checks
   instead of re-running the whole suite and build.
4. **No paid re-work.** A run interrupted after the builder finished (usage
   limit, crash, Ctrl-C) resumes at the gate, not the builder — that was a
   $6–11 re-audit per interruption in the logs. Subscription usage windows are
   waited out and the same session resumed instead of aborting the run.
5. **`FIX_CONTEXT=resume`.** The builder's session already holds the whole
   repository context; a resumed fix round pays cache reads instead of
   rebuilding that context, but only while the cache is warm (1 hour on a
   subscription, 5 minutes on an API key unless `CLAUDE_CODE_PROMPT_CACHE_TTL`
   is set). If gate + review take longer, the resume rewrites the whole
   context at the cache-write rate and a fresh context is cheaper — hence
   `fresh` stays the default. Keep `FIX_EFFORT` unset with `resume`: an effort
   change invalidates the cache too.

Measure before and after with `phase-runner status`; the per-run cost there is
the last `result` event of each session (a resumed session reports its total
cumulatively, so summing every event — the previous behaviour — overstated
resumed runs by up to 2×).

---

## Configuration — `.phase-runner/runner.env`

All paths are relative to the project root. Phases are listed in
`.phase-runner/phases` (one per line, `#` comments; `PHASE_FILES` in
`runner.env` still works as a space-separated fallback).

| Variable | Default | Meaning |
|---|---|---|
| `ENTRY_FILE` | — (required) | Entry/constitution prompt, prepended to every builder, reviewer and report prompt. |
| `GATE_CMD` | empty | Independent verification command run after every builder run. Empty = no gate. |
| `PHASE_REVIEW` | `1` | Run the independent reviewer after every phase. `0` = gate only. |
| `MAX_FIX_ROUNDS` | `2` | Fix rounds per phase before it is recorded as blocked. |
| `COMMIT_REVIEWS` / `REVIEWS_DIR` | `0` / `docs/verification` | Also commit the latest verdict into the repository. |
| `CLAUDE_MODEL`, `CLAUDE_EFFORT` | `claude-fable-5-1`, `xhigh` | Model/effort for every role when nothing more specific is set. |
| `BUILD_MODEL`, `BUILD_EFFORT` | ↑ | The builder's first attempt (template: `high`). |
| `FIX_MODEL`, `FIX_EFFORT` | builder's | Fix rounds (template: `xhigh` — spend more after a failure signal). |
| `REVIEW_MODEL`, `REVIEW_EFFORT` | ↑ | The reviewer, preflight and final review (template: `high`). |
| `SUBAGENT_MODEL` | inherit | Model for subagents the agents spawn when their definition names none (template: `claude-sonnet-5`). |
| `BASH_OUTPUT_MAX_CHARS` | Claude Code's 30000 | Inline characters of a Bash result; the rest is saved to a file the agent can grep (template: 16000). |
| `FIX_CONTEXT` | `fresh` | `resume` continues the builder's session for fix rounds instead of a new context. |
| `BUILD_BUDGET_USD`, `REVIEW_BUDGET_USD` | none | Hard spend cap per agent run. |
| `RETRY_SCHEDULE` | `30 300 3600 10800` | Seconds before each retry after a transient failure. The list's length is the retry count. |
| `LIMIT_WAIT_MAX` | `21600` | Longest wait for a subscription usage window to reset before the run gives up. |
| `STALL_TIMEOUT` | `1800` | Kill + retry an agent that printed nothing for this long. Keep above your slowest silent step. |
| `GATE_TIMEOUT` | `3600` | Kill the gate command after this long (it is not an agent, the stall watchdog does not cover it). The gate runs with stdin closed, so anything that prompts fails fast. |
| `PUSH`, `GIT_REMOTE`, `GIT_BRANCH` | `1`, `origin`, current | Push after every verified phase. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | `Phase Runner` / `runner@phase.local` | Identity for runner commits. |
| `EXTRA_APT_PACKAGES` | empty | Extra apt packages baked into the image. |
| `CLAUDE_CODE_VERSION` | `latest` | Pin the Claude Code version in the image. |
| `AGENT_HOME` | `.phase-runner/home` | Mounted as the agent's `~/.claude`: put `skills/`, `agents/`, plugins there. Sessions persist here too. |
| `REVIEW_PROMPT` | built-in | The final review's instruction (entry file still prepended). |
| `GUARD` | `1` | `0` disables the enforcement hook. Not recommended. |

Credentials are resolved from `$PHASE_RUNNER_CREDENTIALS`, then
`~/.config/claude-phase-runner/credentials.env`, then (with a warning) a
legacy `credentials.env` in the kit directory. They are the agent's own
secret store, deliberately outside the project, so the agent can manage the
project's `.env` files without ever seeing its token.

### The entry file and the phase files

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
docs/phases/PHASE-2-CORE-ENGINE.md   effort=xhigh
docs/phases/PHASE-7-RELEASE.md       model=claude-sonnet-5 effort=medium review_effort=medium
```

Put the top effort on the phases that need it rather than on all of them;
`phase-runner build --dry-run` prints the resolved roles per phase.

**Each phase file** is one self-contained slice: deliverables, steps, and an
explicit **Definition of Done** the reviewer can check item by item. The
better the DoD, the better the verdict: "all 37 ported tests pass, none
skipped" is checkable; "the engine works" is not. If a phase has no explicit
DoD the reviewer derives one from the deliverables and says so.

**Networking note for verification steps:** the agent starts the project's
stack as *sibling* containers (docker-out-of-docker), so their published
ports live on the **host** — from inside the runner container they are
reachable at `host.docker.internal:PORT`, not `127.0.0.1`. Say so in the entry
file if the agent has to curl its own services.

**MCP servers, skills, plugins.** A project `.mcp.json` is picked up
automatically (the project is trusted at boot). User-level skills and agents go
into `.phase-runner/home/skills/` and `.phase-runner/home/agents/`.

---

## Enforcement — the guard hook

`docker/guard.sh` runs as a `PreToolUse` hook on every `Bash`, `Edit`, `Write`,
`MultiEdit` and `NotebookEdit` call of every role (injected with `--settings`,
so nothing is added to the project). A blocked call returns its reason to the
model, which then routes around it instead of retrying blindly.

Every role: no `git push` (the runner pushes), no `reset --hard`, `clean -f`,
`checkout .`, `branch -D`, rebase or other history rewriting, no `--no-verify`,
no `sudo`, no `rm -rf` of root/home/`.git`, no `docker … prune` (the socket is
the host's), no `curl | sh`, and **no modification of the entry file, the
phase files or `.phase-runner/`** — through file tools or shell redirects.
Reading them is fine.

Read-only roles (reviewer, preflight, final review): additionally no edit
tools at all, no git mutation of any kind, no publishing. After a read-only
role finishes, a dirty working tree is reset to HEAD and logged.

The guard fails open on unparseable input and is covered by `tests/guard.sh`;
add a case there for every new rule — an unverified guardrail is a decoration.

## Retries — "the API stopped responding"

Two failure shapes are treated as transient and retried on `RETRY_SCHEDULE`:

- **Errored** — claude exits non-zero and the log tail matches transient
  patterns: HTTP 5xx / 429, `overloaded`, rate limit, connection
  refused/reset, timeouts, `fetch failed`, `socket hang up`.
- **Hung** — no output for `STALL_TIMEOUT` seconds. The watchdog kills the
  process and stamps the log with `RUNNER-STALL`.
- **Usage window** — a subscription's "You've hit your session limit · resets
  3:20pm". The driver reads the reset time from the CLI's `rate_limit_event`,
  waits for it (at most `LIMIT_WAIT_MAX`), and resumes the same session. Being
  out of usage credits is not transient: the run stops with that hint.

Every run gets its own session id; a retry resumes exactly that session, so
in-flight context is preserved and a false stall-kill is cheap. If the session
cannot be resumed the role restarts from its prompt with a new id.

**An honest agent stop is never retried.** Non-zero without transient markers
— an auth error, a budget cap, a CLI failure — aborts the run with the log
path and a hint. A builder that *reports* `blocked` is not a failure at all:
see above.

## Resume & crash recovery

State lives in `.phase-runner/state/` inside the project. Re-running
`phase-runner build` after any interruption (crash, Ctrl-C, exhausted retries,
a blocked phase you have since fixed):

1. pushes any commit backlog a previous run left behind,
2. skips every phase listed in `state/phases-done`,
3. for the first unfinished phase: if its builder had already finished
   (`state/progress/<phase>` exists), checkpoint-commits anything left in the
   tree and goes straight to gate and review — the builder's work is never paid
   for twice; otherwise it restarts from the builder prompt on top of the
   committed repository state. A blocked phase clears the marker, so after you
   intervene the builder does start over.

Phases are keyed by their manifest path — renaming a file makes it look new.
`phase-runner reset` wipes the state; the repository keeps whatever was
committed.

## Monitoring

```bash
phase-runner status            # per phase: done/BLOCKED/partial/pending, verdict, rounds, $, min
phase-runner logs -f           # live transcript of the newest log
phase-runner logs A.md.review  # newest log whose name contains that
cat .phase-runner/state/reviews/<phase>.md
```

Logs are stream-json (`*.log`); a rendered transcript (`*.txt`) is written
next to each when the role ends, and `logs` renders live with jq.

## Preflight and final review

Both are read-only passes run by the same machinery (fresh context, no edit
tools, guard hook); the agent returns the report and the driver writes it.

- `phase-runner preflight` before a long build: which skills, MCP servers,
  plugins, apt packages, and credentials each phase needs, and how to provision
  each — secrets into the credentials file, packages into
  `EXTRA_APT_PACKAGES`, skills into `.phase-runner/home/`, MCP servers into the
  project's `.mcp.json`. The unattended runner cannot authenticate mid-build,
  so anything needing a secret must be in place before launch.
- `phase-runner review` after the build: a prioritized list of what to
  improve, simplify or harden, each item with severity and the concrete fix,
  written to `state/REVIEW.md`. Turn the findings you accept into new phase
  files, append them to `.phase-runner/phases`, run `build` again — resume
  skips the done phases. Customize the lens with `REVIEW_PROMPT`.

## Pushing

The runner pushes after every verified phase (and after a blocked one, so the
work is never only local). The agent itself cannot push — the guard blocks it.

- **SSH remote**: start an agent and add your key before launching
  (`eval $(ssh-agent); ssh-add`); the socket is forwarded into the container
  and host keys are accepted automatically. The CLI warns if the remote is SSH
  and no agent is running.
- **HTTPS remote with embedded token**
  (`https://x-access-token:<TOKEN>@github.com/you/repo.git`): needs nothing.

Push failures retry 3× and then abort without losing the phase record; fix
the auth and re-run — the backlog is pushed first. `PUSH=0` disables pushing.

## Security model — read this once

- The container is a sandbox **against accidents**, which is what makes
  `--dangerously-skip-permissions` acceptable: the agent cannot trash your
  host filesystem or shell config.
- It is **not** a hard boundary against a hostile agent: the mounted Docker
  socket is effectively host-root and outbound network is open (the API,
  registries and `git push` need it). The guard hook narrows what a *careless*
  agent can do; it is not a security boundary either. If you need hard
  containment, remove the socket mount and lose docker-first verification.
- Nothing is published inbound.
- Claude Code refuses to skip permissions as root, so `bootstrap.sh` starts as
  root only to align the docker-socket group and drops to the non-root `node`
  user (uid 1000, so file ownership matches the typical host user).
- The agent's credentials are environment variables in the container; the
  project never sees the file.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no credentials file` | Create `~/.config/claude-phase-runner/credentials.env` from the template with exactly one of `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`. |
| `no config at .phase-runner/runner.env` | Run `phase-runner init` in the project, or pass `--project DIR`. |
| Phase BLOCKED after fix rounds | Read `state/reviews/<phase>.md`. Fix the plan or the code yourself, or raise `MAX_FIX_ROUNDS`, then re-run: the phase restarts from its prompt on the committed state. |
| Builder reported blocked | Read `state/reviews/<phase>.blocked.md`; it names what it needs. Provide it (credentials, a decision, a package), re-run. |
| `push failed 3 times` | No SSH agent forwarded / bad token in the remote URL. Fix, re-run — the backlog pushes first. |
| Killed as stalled during a long docker build / test suite | Raise `STALL_TIMEOUT`. The retry resumes the same session, so little is lost. |
| Agent can't reach its own services on `127.0.0.1` | DooD: use `host.docker.internal:PORT`, or attach test containers to the app's compose network. |
| `guard … BLOCKED` lines in the transcript | Working as intended. If a legitimate command is caught, add a narrower rule + a test case in `tests/guard.sh`. |
| A completed phase runs again | Its manifest path changed, or the state was reset. |
| Need python/go/rust in the image | `EXTRA_APT_PACKAGES="python3 python3-pip"` in `runner.env`; the image rebuilds on the next run. |
| Reviewer verdicts feel shallow | Sharpen the phase's Definition of Done and set `REVIEW_MODEL`/`REVIEW_EFFORT` higher than the builder's. |
| A phase costs far more than its size suggests | Read the transcript for repeated full test runs and big output dumps; lower that phase's `effort=` in `phases`, set `BASH_OUTPUT_MAX_CHARS`, see [Cost](#cost). |
| Run stopped with `hit your session limit` | Older kits aborted here; now the driver waits for the reset (`LIMIT_WAIT_MAX`) and resumes. `out of usage credits` still stops the run — top up or switch to API billing. |

## Iterating on the kit

`docker/` and `prompts/` are bind-mounted over the baked copies, so driver,
library, guard and prompt edits take effect on the next run without a rebuild.
`docker/Dockerfile` changes rebuild automatically (a cache hit when nothing
changed).

Tests need no Docker and no token: `bash tests/run.sh` runs a fake `claude`
(`tests/bin/claude`) through every scenario — happy path, reviewer FAIL → fix
→ PASS, exhausted rounds, red gate, transient retry with session resume and
once-counted cumulative cost, stall, no-session restart, usage-limit wait,
out-of-credits stop, blocked builder, resume after an interruption (builder
skipped), per-phase manifest options, per-role model/effort, subagent model
and output cap, `FIX_CONTEXT=resume` with fallback, dry run, two phases,
committed verdicts, reviewer leaving files, uncommitted leftovers, preflight,
final review, the host CLI — plus every guard rule. Add a scenario with each
behaviour change.

## Migrating from the old layout (kit-local `runner.env` + `state/`)

1. In each target project: `phase-runner init`, then move the old
   `runner.env` values into `.phase-runner/runner.env` (drop `PROJECT_DIR`;
   `PHASE_FILES` still works, but the `phases` manifest is nicer) and the phase
   list into `.phase-runner/phases`.
2. Move that project's `state/` contents into `.phase-runner/state/`
   (`phases-done`, `logs/`, `SUMMARY.md`, …). Old per-project state that was
   mixed in one kit `state/` directory must be split by project — the
   `phases-done` paths tell you which is which.
3. Move `credentials.env` to `~/.config/claude-phase-runner/credentials.env`.
4. Remove the "spawn a verification subagent" instructions from your entry
   files; the runner's reviewer replaces them.
