# PHASE-N — <the outcome, as a sentence>

<!-- One builder run with a fresh context; the repository green at the end; 60–150
     lines. Deliverables as end states. A Definition of Done a read-only reviewer can
     check item by item with a command or a file:line. docs/WRITING-PHASES.md in the
     kit explains each section. Delete these comments. -->

## Problem

<Why this phase exists, with evidence: the failing scenario, the log line, the missing
capability. What it relies on from earlier phases: files, exports, commands.>

## Deliverables

1. **<End state>** — `path/to/file`: <what it contains, exports or does>.
2. **<End state>** — ...
3. **Docs** — <the README section, ADR or changelog entry the change needs>.

## Tests to add

- `tests/<file>` — <what it proves; the cases, including the failure path>.

## Out of scope

- <What a diligent builder would be tempted to do here and must not.>

## Definition of Done

- [ ] <One observable claim: a command and its expected result, or a file:line fact.>
- [ ] <Counts where they exist: "all 12 routes return 401 without a session".>
- [ ] <No existing assertion modified; the assertion count grew.>
- [ ] <Docs updated as in deliverable 3.>
- [ ] Gate green.
