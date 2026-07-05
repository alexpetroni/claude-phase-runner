# claude-phase-runner

Autonomous, phase-by-phase project builder. It runs Claude Code with
`--dangerously-skip-permissions` inside a sandboxed Docker container against a
target git repository: **one agent run per phase plan file**, escalating
retries when the Claude API errors or hangs, optional independent
verification gates, and a **commit + push after every phase**. A killed or
crashed run resumes exactly where it stopped.

Generalized from the `grounded-flow` builder (`docker-compose.builder.yml` +
`docker/builder/`) and the crash-safety lessons of its
`scripts/refactor-driver.sh`.

```
┌ run.sh (host) ──────────────────────────────────────────────────────┐
│ validate config → build image → docker compose run                  │
│  ┌ container ─────────────────────────────────────────────────────┐ │
│  │ bootstrap.sh (root): docker-socket group, git identity,        │ │
│  │                      drop to non-root `node`                   │ │
│  │  └ driver.sh: for each phase file, in order:                   │ │
│  │      1. claude -p "<entry file> + execute ONLY this phase"     │ │
│  │      2. on API error/hang → retry: 30s, 5m, 1h, 3h (--continue)│ │
│  │      3. optional GATE_CMD (+ one remediation run)              │ │
│  │      4. checkpoint-commit leftovers, record phase, git push    │ │
│  └────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Contents

```
run.sh                    host launcher: validate config → build → run
runner.env.example        per-project config — copy to runner.env
credentials.env.example   agent token — copy to credentials.env
docker-compose.yml        container definition (same-path repo mount, DooD)
docker/Dockerfile         node 24 + git + docker CLI + pnpm + Claude Code
docker/bootstrap.sh       root entrypoint: socket group, git config, drop to node
docker/driver.sh          the phase loop: retries, gates, commit, push, resume
state/                    created at runtime: phases-done, logs/, SUMMARY.md
```

## Prerequisites

- Docker with the compose plugin on the host.
- A **target project** that is a git repository with a pushable remote.
- A Claude Code credential: either a subscription OAuth token
  (`claude setup-token`) or an `ANTHROPIC_API_KEY`.
- For SSH push remotes: a running `ssh-agent` with the key added (see
  [Pushing](#pushing)).

The kit lives anywhere on disk — it does not need to be inside the target
project.

---

## Setup

### 1. Credentials

```bash
cp credentials.env.example credentials.env
# edit: set EXACTLY ONE of
#   CLAUDE_CODE_OAUTH_TOKEN=...   (subscription — from `claude setup-token`)
#   ANTHROPIC_API_KEY=...         (API billing)
```

This file is the agent's own secret store, deliberately separate from the
target project's env files — the agent can freely create/modify the project's
`.env` without ever touching its own token. Never commit it anywhere.

### 2. Prepare the target project

The runner needs two kinds of files **inside the target repo**:

**An entry file** (`ENTRY_FILE`) — the mission/constitution prompt, read
first and prepended to every phase prompt. Modeled on grounded-flow's
`docker/builder/PROMPT.md`. It should contain:

- the mission and what "done" means for the product;
- the binding engineering rules (test policy, lint gates, commit conventions,
  forbidden patterns, mock-provider rules for AI code, …);
- how to *verify* work (the exact commands), and the instruction to never
  fake a green result — stop honestly with a blocker report instead.

Keep phase scoping **out** of it: the runner appends a per-phase trailer
("execute ONLY the phase in `<file>`, stop when its DoD holds and the work is
committed, do not push") automatically.

**Phase plan files** (`PHASE_FILES`) — one file per phase, in execution
order. Each should be a self-contained, executable slice: deliverables, steps,
and an explicit **Definition of Done** the agent can check itself against.
Phases should build on each other; the runner enforces the order.

**Networking note for verification steps:** the agent starts the project's
stack as *sibling* containers (docker-out-of-docker), so their published
ports live on the **host** — from inside the runner container they are
reachable at `host.docker.internal:PORT`, **not** `127.0.0.1`. If your entry
file tells the agent to curl its own services, say so (or have tests attach
to the app's compose network, as grounded-flow's
`test/helpers/rag-network.ts` does).

### 3. Configure the run

```bash
cp runner.env.example runner.env
```

| Variable | Default | Meaning |
|---|---|---|
| `PROJECT_DIR` | — (required) | Absolute host path of the target repo. Mounted at the same path inside the container so the project's own compose bind mounts stay valid. |
| `ENTRY_FILE` | — (required) | Entry prompt file, relative to the project root. |
| `PHASE_FILES` | — (required) | Ordered, space-separated phase files, relative to the project root. One agent run per file. |
| `RETRY_SCHEDULE` | `30 300 3600 10800` | Seconds to wait before each retry after a transient failure. **The list's length is the retry count** — the default is 4 retries: 30s, 5m, 1h, 3h. |
| `STALL_TIMEOUT` | `1800` | Kill + retry the agent if it emits no output for this many seconds. Keep above your slowest silent step (one big docker build or test suite is a single tool call that prints nothing until it ends). |
| `GATE_CMD` | empty | Optional independent verification command run from the project root after every phase (e.g. `pnpm lint && pnpm typecheck && pnpm test`). Empty = trust the agent's own checks. |
| `PUSH` | `1` | Push after every phase. `0` disables pushing (commits still happen). |
| `GIT_REMOTE` | `origin` | Remote to push to. |
| `GIT_BRANCH` | current branch | Branch to push. |
| `CLAUDE_MODEL` | CLI default | Model override passed to `claude --model`. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | `Phase Runner` / `runner@phase.local` | Commit identity for runner checkpoint commits. |
| `EXTRA_APT_PACKAGES` | empty | Extra apt packages baked into the image at build time (e.g. `"python3 python3-pip"` for non-JS stacks). |

### 4. Dry run (always do this first)

```bash
DRY_RUN=1 bash run.sh
```

Validates the config on the host (paths exist, repo is git), builds the
image, boots the container, re-validates inside, and prints the fully
composed **first phase prompt** — exactly what the agent would receive — then
exits without launching any agent. Read that prompt; if it says what you
mean, you're ready.

### 5. Run

```bash
bash run.sh                     # uses ./runner.env
bash run.sh path/to/other.env   # or an explicit config
```

Runs in the foreground (phases take hours — use `tmux`/`screen` for long
sessions). `Ctrl-C` is safe at any time: everything committed so far is on
the branch, and completed phases are recorded.

---

## What happens during a run

Per phase file, in order:

1. **Prompt assembly** — entry file contents + the scope trailer for this
   phase file.
2. **Agent run** — `claude --dangerously-skip-permissions -p <prompt>
   --output-format stream-json --verbose`, logged to
   `state/logs/phase-<file>.log`. `stream-json` makes the log advance on
   every agent event, which is what makes hang detection possible.
3. **Retries** — see below.
4. **Gates** — if `GATE_CMD` is set: run it; on failure the agent gets **one**
   remediation run (with the gate output in its prompt), then the gates run
   again; still red aborts the whole run. The agent's own claim of green is
   never trusted when gates are configured.
5. **Checkpoint commit** — anything the agent left uncommitted is committed
   as `chore(runner): checkpoint uncommitted work after <phase>` so no work
   is ever lost between phases.
6. **Record + push** — the phase is appended to `state/phases-done` and the
   branch is pushed (3 attempts, 30s apart).

After the last phase, `state/SUMMARY.md` is written with the final `git log`.

## Retries — "the API stopped responding"

Two failure shapes are treated as **transient** and retried on the
`RETRY_SCHEDULE`:

- **Errored** — claude exits non-zero and the log tail matches transient
  patterns: HTTP 5xx / 429, `overloaded`, rate limit, connection
  refused/reset, timeouts, `fetch failed`, `socket hang up`, …
- **Hung** — no output for `STALL_TIMEOUT` seconds. A watchdog kills the
  process and stamps the log with `RUNNER-STALL`.

Retries resume the interrupted session with `--continue`, so in-flight
context (what the agent was in the middle of) is preserved; if no session
exists yet, the phase prompt is restarted from scratch. A false stall-kill is
therefore cheap.

**An honest agent stop is never retried.** If claude exits non-zero *without*
transient markers — e.g. it hit an unreachable DoD and stopped with a blocker
report, per the entry file's rules — the run aborts immediately with logs.
Retrying an honest failure would just burn tokens re-asking a question that
was already answered.

When the schedule is exhausted, the run aborts; everything already committed
is safe, and a later re-run resumes the phase.

## Resume & crash recovery

State lives in `state/` (bind-mounted, survives the container):

- `state/phases-done` — one line per completed phase file.
- `state/logs/` — per-phase agent logs, gate logs, push log.
- `state/SUMMARY.md` — success summary, or the failure reason on abort.

Re-running `bash run.sh` after any interruption (crash, `Ctrl-C`, power
loss, exhausted retries):

1. pushes any commit backlog a previous run left behind (e.g. it died on the
   push itself),
2. skips every phase listed in `phases-done`,
3. restarts the first unfinished phase from its prompt (the repo state — all
   prior commits — is its starting point).

**Fresh start**: `rm -rf state/`. The target repo keeps whatever was
committed; reset the branch yourself if you want the code gone too.

**Note**: phases are keyed by their file path — renaming a phase file makes
it look new and it will run again.

## Pushing

The runner pushes the branch after every phase. Two auth options:

- **SSH remote** (`git@github.com:...`): start an agent and add your key
  *before* launching — `eval $(ssh-agent); ssh-add` — the socket is
  forwarded into the container (`SSH_AUTH_SOCK`). Host keys are accepted
  automatically (`StrictHostKeyChecking=accept-new`) so an unattended run
  never blocks on a prompt. `run.sh` warns if the remote is SSH and no agent
  is running.
- **HTTPS remote with embedded token**
  (`https://x-access-token:<TOKEN>@github.com/you/repo.git`): needs nothing.

Push failures retry 3× (30s apart) and then abort **without losing the phase
record** — fix the auth and re-run; the backlog is pushed first.

`PUSH=0` turns pushing off entirely (commits still happen locally).

## Monitoring a run

The driver's own progress lines (phase started, retrying in Ns, gates, push)
print to your terminal. The agent's raw output is stream-json in
`state/logs/`:

```bash
# what is the agent saying/doing right now?
tail -f state/logs/phase-PHASE-2-PLAN.md.log \
  | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text'

# every tool call as it happens
tail -f state/logs/phase-PHASE-2-PLAN.md.log \
  | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name'
```

## Security model — read this once

- The container is a sandbox **against accidents**, which is what makes
  `--dangerously-skip-permissions` acceptable: the agent cannot trash your
  host filesystem or your shell config.
- It is **not** a hard boundary against a hostile agent: the mounted Docker
  socket (`/var/run/docker.sock`) is effectively host-root, and outbound
  network is fully open (the Claude API, registries, and `git push` need
  it). If you need hard containment, remove the socket mount — and lose
  docker-first verification.
- Nothing is published inbound; no one can connect *to* the container.
- Claude Code refuses to skip permissions as root, so `bootstrap.sh` starts
  as root only to align the docker-socket group, then drops to the non-root
  `node` user (uid 1000 — matches the typical host repo owner, so file
  ownership stays sane).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ERROR: no credentials` at boot | `credentials.env` missing or empty — set `CLAUDE_CODE_OAUTH_TOKEN` **or** `ANTHROPIC_API_KEY`. |
| `push failed 3 times` | No SSH agent forwarded / bad token in remote URL. Fix auth, re-run — the commit backlog pushes first. |
| Phase killed as stalled during a long docker build / test suite | Raise `STALL_TIMEOUT` above your slowest silent step. The retry `--continue`s the session, so little is lost. |
| Agent can't reach its own services on `127.0.0.1` | DooD: published ports live on the host. Use `host.docker.internal:PORT` (mapped via `extra_hosts`), or attach test containers to the app's compose network. |
| `still red after remediation` | The gate genuinely fails. Read `state/logs/gates-*.log`, fix or relax `GATE_CMD`, re-run — the phase restarts. |
| A completed phase runs again | Its file was renamed (resume is keyed by path), or `state/` was deleted. |
| Docker socket warnings at boot | `/var/run/docker.sock` not mounted or not accessible — docker-first verification is disabled but the run continues. |
| Need python/go/rust in the image | `EXTRA_APT_PACKAGES="python3 python3-pip"` in `runner.env`, then re-run (the image rebuilds). |

## Iterating on the kit itself

`docker/driver.sh` is bind-mounted over the baked copy, so driver changes
take effect on the next `run.sh` **without** an image rebuild. Changes to
`docker/Dockerfile` or `docker/bootstrap.sh` need a rebuild — `run.sh` always
runs `docker compose build`, which is a no-op cache hit when nothing changed.

The driver can also be exercised without Docker or tokens (this is how it was
tested): point `PATH` at a fake `claude` binary and run it directly —
`RUNNER_STATE=/tmp/state PROJECT_DIR=... ENTRY_FILE=... PHASE_FILES=... bash
docker/driver.sh`.
