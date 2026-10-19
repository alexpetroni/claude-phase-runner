# Writing the plan: the entry file and the phase files

The runner executes a plan you write. It is three things, all inside the project:

- **the entry file** — the mission and the rules that hold in every phase;
- **the phase files** — one per phase, each ending in a Definition of Done;
- **`.phase-runner/phases`** — the manifest: which phase files, in which order.

Per phase, a builder with a fresh context reads the entry file and its phase file,
works, commits. The gate runs. A reviewer with another fresh context lists the phase's
Definition of Done and checks every item against the repository and the diff. Nothing
else carries from one phase to the next. That shapes everything below: **the
repository and the plan are the builder's only memory, and the Definition of Done is
the only contract the reviewer enforces.**

Starting points: `ENTRY.md` and `PHASE.md` next to this file in the kit. Copy them
into the project, fill them in, delete the guidance comments.

## 1. Cut the project into phases

One phase is one builder run: a fresh context, a sequence of commits, one reviewable
diff, and the repository green at the end. Cut along those lines.

- **Size: a focused day for one engineer.** One subsystem, or one cross-cutting change
  with its tests. In plan text that is 60–150 lines. For scale, the kit's own October
  batch was seven phases of 68–144 lines; each took the builder 31–90 turns and 9–20
  minutes. A phase that is too big fills the builder's context with tool output and
  fails review more often; one that is too small pays the reviewer's fixed cost for
  little work.
- **Phase 0 of a new project is the scaffold.** The toolchain, the layout, one trivial
  passing test per package, and the gate command green. No product logic. Every later
  diff is then readable and every later gate run means something.
- **Order by dependency, then by risk.** The hard, uncertain piece goes early, where a
  blocked phase costs the least. Release, packaging and cleanup go last and can run on
  a cheaper model (`model=` in the manifest).
- **Vertical slices over layers** where the product allows it. "The quiz works end to
  end for one archetype" can be verified; "all the types" cannot.
- **Every phase ends green.** No phase leaves the gate red for the next one to fix. If
  a change has to break things on the way, the break and the repair are one phase.
- **Say what a phase relies on.** The builder of phase 3 never saw phases 1 and 2 being
  built. Name the files, exports and commands it will find, or say where to read them.

## 2. Write the entry file

The entry file is prepended to every prompt: builder, fix round, reviewer, preflight,
final review. It is the constitution; the phase file is the work order. Put in it what
holds in every phase, and nothing that changes per phase.

What goes in:

1. **The mission** in a paragraph, and what "done" means for the product as a whole.
2. **Decisions already made**: stack, layout, source of truth, dependencies to use or
   avoid. Say they are not to be relitigated.
3. **Invariants** that hold at the end of every phase: gate green, no skipped tests, no
   secrets in the tree, the contracts that must not change without a phase saying so.
4. **Engineering rules**: test policy, lint and type gates, commit conventions,
   forbidden patterns, mock rules for external services.
5. **Verification**: the exact commands, from the repository root, and what green looks
   like. `GATE_CMD` in `runner.env` must be one of them.
6. **Known gotchas**, a sentence each, so the builder does not rediscover them.

What stays out:

- **Phase scoping** ("you are building phase N"). The runner adds it.
- **Self-verification**: spawning a verification subagent, writing PASS files, verdict
  files in the repository. The runner's reviewer does that with a context the builder
  cannot influence; self-issued verdicts are ignored, and the instruction only spends
  the builder's turns. Plans written before the runner existed usually contain this.
  Strip it.
- **Pushing, credentials, SSH.** The runner pushes; the agent cannot.

Keep it to what changes behaviour, 100–200 lines. Two facts about the environment the
builder cannot know unless you state them:

- **Networking.** With `DOCKER_SOCKET=0` (the template default) there are no containers:
  services and tests run as processes in the runner container and `127.0.0.1` is
  right. With `DOCKER_SOCKET=1` the project's stack runs as sibling containers on the
  host daemon and its published ports are at `host.docker.internal:PORT`.
- **Secrets.** The unattended run cannot authenticate anywhere. Whatever the phases need
  (a key the tests call, a service token) must be in place before launch, where the
  project reads it and outside git. Say what is available and what is deliberately not
  and must be mocked. `phase-runner preflight` reads the whole plan and lists what is
  missing.

## 3. Write each phase file

Use the sections of `PHASE.md`, next to this file.

**Title.** The outcome as a sentence, not the activity: "The runner's own account of a
run is kept", not "Logging".

**Problem.** Why the phase exists, with evidence: the failing scenario, the log line,
the missing capability. Two paragraphs at most. A builder that knows why decides the
details the plan does not cover the way you would.

**Deliverables.** Numbered, concrete, with paths. Write them as end states ("`src/engine/`
exports `createIntake()`"), not actions ("add an engine"): a phase that is re-run after
a block starts from the committed state, and an end state is still true when half of it
already exists.

**Tests to add.** The files and what they prove, including the failure paths. The
reviewer looks specifically for tests that mock the module under test, vacuous
assertions, and existing tests weakened or deleted.

**Out of scope.** What a diligent builder would be tempted to do here and must not. The
reviewer flags out-of-scope work, so this list protects the builder too.

**Definition of Done.** A checkbox list. This is the contract: the reviewer lists the
items verbatim, verifies each one itself, and returns PASS or FAIL per item with
evidence. The phase passes only if every item holds and there is no critical or high
finding. Rules for an item:

- **Checkable by a read-only agent** with a command or a `file:line`. "All 37 ported
  tests pass, none skipped" is checkable; "the engine works" is not.
- **One claim per item.** A compound item fails as a whole.
- **Numbers where they exist**: tests, routes, files, sizes, latencies.
- **"Gate green" is the last item** of every phase.
- **Documentation is an item** when the phase changes something a reader relies on.
- **No "the verification file says PASS", no "a subagent confirmed".** There is no such
  file, and the reviewer treats such claims as claims.
- **Do not ask the builder to tick the boxes.** The entry file, the phase files and
  `.phase-runner/` are read-only for every role; the guard blocks the write.

A phase without an explicit Definition of Done gets one derived by the reviewer from
the deliverables. You then get the reviewer's reading of your plan instead of yours.

## 4. The manifest and `runner.env`

`.phase-runner/phases` lists the phase files one per line, in order, as paths relative
to the project root. `#` starts a comment. Options after a path override models and
efforts for that phase only; `templates/phases` documents them.

- **Order is the manifest's**, not the file names'. Numbering files is for humans.
- **Append new phases at the end.** A completed phase is recorded by its path in
  `state/phases-done`; renaming or moving the file makes it look new and it runs again.
- **`ENTRY_FILE` and `GATE_CMD` are part of the plan.** The gate is the command the
  entry file tells the builder to run; it runs from the project root with stdin closed,
  capped by `GATE_TIMEOUT`, so it must be quiet and non-interactive. For a new project it
  is red until phase 0 delivers it. That is intended: making it green is phase 0's job.

## 5. Before the first run

```bash
git add docs/ENTRY.md docs/phases && git commit -m "docs: build plan"   # the plan first
phase-runner build --dry-run      # the exact first builder prompt; no agent is launched
phase-runner preflight            # optional: tooling, packages, credentials the plan needs
```

Commit the plan before launching: the runner's checkpoint commits add everything in
the tree, so an uncommitted plan would land in the builder's first commit. The dry run
fails at once on a missing entry file or phase file. Read the printed prompt as the
builder will: together with the repository, it is everything the builder gets.

## 6. While it runs, and after

- **A blocked phase stops the run.** Read `state/reviews/<phase>.md`: the Definition of
  Done table with evidence, then the findings. Usually the plan was ambiguous, or asked
  for something the environment cannot do. Edit the phase file and re-run: the phase
  restarts from its prompt on the committed state, and completed phases are skipped.
- **Add phases by appending to the manifest.** `phase-runner review` after a build
  returns a prioritized list of improvements, each written so it can become a phase
  file with its own Definition of Done. The kit's own PHASE-6 collects the reviewers'
  low findings from earlier phases the same way.
- **Change the plan between runs, not during one.** The manifest is read when the
  driver starts; a phase file is read when its phase starts.

## 7. Let Claude draft the plan

The plan is the one part of this loop that no reviewer checks, so draft it in an
interactive session where you can push back, then read every file yourself. The kit
ships the procedure as a Claude Code skill: `phase-runner install` links this directory
into `~/.claude/skills/`, and from then on, in Claude Code in the project, once the
project has been talked through:

> Write the phases for claude-phase-runner.

or `/phase-runner`. The skill (`SKILL.md` next to this file) checks the kit and the
repository, runs `phase-runner init`, asks what is still open in one message, writes
the entry file and the phase files by this guide, fills the manifest and the gate, and
ends with the steps that follow. After a blocked phase the same request revises the
plan from the verdict.

Without the skill, paste the procedure yourself:

> Read `ENTRY.md`, `PHASE.md` and `WRITING-PHASES.md` in
> `<path to the kit>/skills/phase-runner`. Then read this repository and `<the spec,
> if there is one>`.
> Write `docs/ENTRY.md` and `docs/phases/PHASE-0-<slug>.md` … `PHASE-N-<slug>.md` for:
> `<what to build, the decisions already made, what done means>`. Each phase is one
> focused day of work, ends with the repository green, and has a Definition of Done a
> read-only reviewer can check item by item with commands and `file:line`. Phase 0 is
> the scaffold and the gate. Deliverables are end states. No self-verification
> instructions, no PASS files. Finish by printing the lines for `.phase-runner/phases`.

Then cut what you would not have written, and sharpen every Definition of Done item you
cannot picture a reviewer checking.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| "Spawn a subagent to verify, write `verification/PHASE-N.md`, loop until PASS" (plans from before the runner) | Builder turns spent on a verdict nobody reads, and a DoD item that can never be met | Delete it; the runner's reviewer does this |
| DoD items like "works", "robust", "clean" | The reviewer derives its own criteria or passes on weak evidence | One observable claim per item, with a command or a path |
| A phase relies on an earlier phase's work without saying so | The builder rediscovers it from the code, or rebuilds it differently | Name the files, exports and commands it will find |
| A phase too big for one context | Tool output fills the context, the builder cuts corners near the end, more fix rounds | Split it; a focused day each |
| The gate takes longer than `GATE_TIMEOUT`, or asks a question | Red gate, then a fix round that cannot fix it | A quiet, non-interactive gate; raise the timeout for a slow suite |
| A phase needs a secret or an interactive login | The builder reports blocked | Provision it before launch; run `preflight` |
| "Start the dev server and leave it running for the next phase" | Nothing survives the end of a run | Each phase starts and stops what it needs |
| The plan is not committed before launch | It lands in the builder's first checkpoint commit | Commit the plan first |
| A phase file is renamed or moved after it ran | The phase runs again | Append; rename only on purpose |
