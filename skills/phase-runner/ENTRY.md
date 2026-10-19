# <Project> — mission & constitution

<!-- Prepended to EVERY prompt: builder, fix round, reviewer, preflight, final review.
     Only what holds in every phase. No phase scoping (the runner adds it), no
     self-verification or PASS files (the runner's reviewer does that), nothing about
     pushing (the runner pushes; the agent cannot). WRITING-PHASES.md next to this skeleton
     explains each section. Delete these comments. -->

## What we are building

<One paragraph: the product, who it is for, and what "done" means for the whole plan.>

## Decisions already made — do not relitigate

- Stack: <language, framework, package manager, pinned versions>
- Layout: <workspaces, directories, where tests live>
- Source of truth: <the spec, the reference implementation, the design file>
- <Dependencies to use; dependencies never to add>

## Invariants at the end of EVERY phase

- The gate below is green. No test skipped, focused or weakened to get there.
- <No secrets in the tree; `.env.example` documents every variable.>
- <Public API / schema / URL contracts that do not change unless a phase says so.>

## Engineering rules

- Tests: <framework; what every change comes with; what must never be mocked>.
- Lint and types: <commands; zero-warning policy>.
- Commits: conventional (`feat:`, `fix:`, `test:`, `docs:`), one logical change per
  commit, the body says why.
- <Forbidden patterns; mock rules for external services; docs move with the code.>
- The entry file and the phase files are read-only for you. If a deliverable is wrong
  or impossible, deliver the rest and say so in your report.

## How to verify — exact commands, from the repository root

```
<pnpm install --frozen-lockfile>
<pnpm -r --if-present run lint>
<pnpm -r --if-present run typecheck>
<pnpm -r --if-present run test>
```

<What green looks like. Which of these is GATE_CMD. How long they take, so a slow one
gets an explicit timeout.>

## Environment

- <DOCKER_SOCKET=0: services and tests are processes in the runner container,
  127.0.0.1 is right. DOCKER_SOCKET=1: the stack runs as sibling containers on the
  host, reachable at host.docker.internal:PORT.>
- <Secrets available and where the project reads them. What is deliberately NOT
  available and must be mocked.>

## Known gotchas

- <One sentence each: things that have cost a session before.>
