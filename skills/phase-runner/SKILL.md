---
name: phase-runner
description: Write the plan that lets claude-phase-runner build a project unattended — the entry file, one phase file per phase with its Definition of Done and tests, the phases manifest and the gate — or revise that plan after a blocked phase or a finished run. Use when the user asks to write, prepare, generate or update the phases, a DoD or a plan "for claude-phase-runner" or "for the phase runner", or to make a plan they have agreed buildable unattended.
argument-hint: [what to build, or which phase to revise]
allowed-tools: Read Grep Glob Bash(phase-runner init) Bash(phase-runner help) Bash(phase-runner status) Bash(command -v phase-runner)
---

# Write the plan for claude-phase-runner

claude-phase-runner builds a project unattended, in a Docker container, one phase at a
time. Per phase: a builder with a fresh context reads the entry file and the phase
file, works and commits; a gate command runs; a reviewer with another fresh context
and no edit tools checks every Definition of Done item against the repository and the
diff and returns PASS or FAIL; a FAIL buys a fix round, then the phase is blocked and
the run stops for the human. Nothing else carries from one phase to the next. **The
plan is the builders' only memory, and each Definition of Done is the only contract
the reviewer enforces.** Every rule below protects one of those two facts.

`WRITING-PHASES.md` in this directory is the full guide; `ENTRY.md` and `PHASE.md` are
the skeletons. Read all three before writing anything.

The conversation that led here is the source material. If there was none — the user
opened with this request — read the repository and any spec first, and expect to ask
more in step 2.

## 1. Check the ground

From the project root, in one Bash call:

```bash
command -v phase-runner && phase-runner help | tail -2
git rev-parse --show-toplevel && git remote -v && git status --short | head
ls .phase-runner .phase-runner/state 2>&1
```

- **No `phase-runner` on PATH**: stop and say so. The kit is not installed on this
  machine: `git clone git@github.com:alexpetroni/claude-phase-runner.git`, then
  `bin/phase-runner install` from the clone. Do not write the plan blind; the install
  also puts this skill in place for the next session.
- **Not a git repository**: the runner needs one, with a first commit. Ask before
  running `git init`.
- **No remote**: the runner pushes every verified phase to `origin`. Without one, set
  `PUSH=0` in step 4 and say so.
- **No `.phase-runner/`**: run `phase-runner init`. It creates
  `.phase-runner/runner.env` and `.phase-runner/phases` from the kit's templates and
  excludes the directory from git. Idempotent, no container, no token.
- **`.phase-runner/state/` exists**: a run has happened. This is a revision: read
  step 5 before touching anything.

## 2. Settle what the plan needs

The entry file needs the points below, and the user has usually decided most of them
in this conversation. List what is still open and ask it all in **one** message, each
question with the default you would pick. Never one question per turn, and never write
files while the stack or the gate is undecided.

- the mission in a paragraph, and what "done" means for the whole plan;
- stack, layout, package manager, pinned versions; dependencies to use or never add;
- the source of truth — a spec, a design, a reference implementation — and where it is;
- the verification commands from the repository root, and which of them is the gate;
- what the unattended run needs from the environment: containers (`DOCKER_SOCKET=1`)
  or none, secrets and services that are available or must be mocked, a toolchain
  beyond Node (`EXTRA_APT_PACKAGES`);
- the invariants and rules you would hold a contractor to: test policy, lint and type
  gates, commit conventions, forbidden patterns.

Decide the small things yourself and list them in the final message.

## 3. Write the files

**The entry file** — `docs/ENTRY.md`, the path `ENTRY_FILE` names in
`.phase-runner/runner.env` (keep that default unless the project has its own docs
convention). Fill the skeleton's sections and delete its guidance comments. It is
prepended to every prompt, so it holds only what is true in every phase: mission,
decisions, invariants, rules, the exact verification commands, environment facts,
gotchas. No phase scoping, no self-verification or PASS files, nothing about pushing:
the runner does all three, and an instruction to verify itself only spends the
builder's turns.

**The phase files** — `docs/phases/PHASE-0-<slug>.md`, `PHASE-1-<slug>.md`, … (zero-pad
past nine). One builder run each: a focused day for one engineer, 60–150 lines of
plan, the repository green at the end. Phase 0 of a new project is the scaffold:
toolchain, layout, one trivial test per package, the gate command green. The hard,
uncertain piece comes early, where a blocked phase costs least. Each file has the
skeleton's sections: Problem with evidence, Deliverables as end states with paths,
Tests to add, Out of scope, Definition of Done. Say what a phase relies on from earlier
phases by name — the builder of phase 3 never saw phases 1 and 2 being built.

**The Definition of Done** is what the reviewer enforces, item by item, with evidence it
gathers itself. Per item:

- one observable claim a read-only agent can check with a command or a `file:line`;
  "all 37 ported tests pass, none skipped" is checkable, "the engine works" is not;
- numbers where they exist: tests, routes, files, sizes, latencies;
- "Gate green" is the last item of every phase;
- documentation is an item when the phase changes something a reader relies on;
- never "a verification file says PASS" or "a subagent confirmed": no such thing
  exists, and the reviewer treats such claims as claims;
- the builder cannot tick the boxes: the plan files are read-only for every role.

## 4. Wire the runner

- **`.phase-runner/phases`** — replace the template's example lines with the phase
  files in execution order, one project-relative path per line; keep the header
  comments. Options after a path override the models for that phase only:
  `model=claude-fable-5-1` on the hard phases, `model=claude-sonnet-5-5 effort=medium`
  on release and cleanup phases. Leave the rest on the defaults.
- **`.phase-runner/runner.env`** — edit in place and keep the comments; they are the
  user's reference. Set `GATE_CMD` to the gate the entry file names: it runs from the
  project root, non-interactive, stdin closed, within `GATE_TIMEOUT`, so a watch mode
  or a prompt makes it red. Set `ENTRY_FILE` if the entry file is not `docs/ENTRY.md`,
  `DOCKER_SOCKET=1` only if a phase really needs containers, `EXTRA_APT_PACKAGES` for
  a toolchain beyond Node, `PUSH=0` when there is no remote. Leave the model settings
  as shipped unless the user asked.
- **Check what the dry run would check**: every path in the manifest exists, the
  entry file exists. Do not run `phase-runner build --dry-run` yourself — it starts
  Docker and may build the image for minutes; it is the user's first next step.

## 5. Revising after a run

`phase-runner status` shows each phase as pending, partial, done, BLOCKED or missing,
with verdicts and cost, and ends with the next step. Then:

- **A blocked phase** — read `.phase-runner/state/reviews/<phase file>.md` (the DoD
  table with evidence, then the findings) and `.phase-runner/state/blocked`. Usually
  the plan was ambiguous, or asked for something the environment cannot do. Edit the
  phase file; the next `phase-runner build` restarts that phase from its prompt on the
  committed state and skips completed phases. Never rename or move a phase file that
  has run: completion is recorded by path, and a renamed file runs again.
- **A builder that reported blocked** —
  `.phase-runner/state/reviews/<phase file>.blocked.md` names what it needs: a
  credential, a decision, a package. Provide it, or change the plan.
- **More work after a finished run** — append new phase files at the end of the
  manifest. `phase-runner review` writes `.phase-runner/state/REVIEW.md`, a prioritised
  list whose items are written to become phases.
- Change the plan between runs, never during one: the manifest is read when the driver
  starts and a phase file when its phase starts.

## 6. Hand over

The plan must be committed before the first run (the runner's checkpoint commits add
everything in the tree, so an uncommitted plan lands in the builder's first commit),
but do not commit unless the user asked. End with this, filled in and nothing more:

```
Plan written: docs/ENTRY.md, N phase files in docs/phases/, .phase-runner/phases,
GATE_CMD="<the gate>".
Decided on my own: <only what was not discussed, one line each>

Next:
  1. Read docs/ENTRY.md and the phase files. Sharpen every Definition of Done item
     you cannot picture a reviewer checking with a command.
  2. git add docs/ENTRY.md docs/phases && git commit -m "docs: build plan"
     (or say "commit" and I will)
  3. phase-runner build --dry-run      the exact first builder prompt; launches no agent
  4. tmux new -s build, then phase-runner build
                                       Ctrl-C stops it cleanly; never kill the window
  5. phase-runner status · phase-runner logs -f      from another terminal

A blocked phase stops the run: read .phase-runner/state/reviews/<phase>.md, ask me
to revise the plan, run again — completed phases are skipped.
Details: phase-runner help names the README; the plan-writing guide is
WRITING-PHASES.md next to this skill.
```
