[claude-phase-runner](../README.md) · [Documentation](README.md)

# Resume & crash recovery

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

## Stopping a run

Press **Ctrl-C in the terminal running `phase-runner build`**. The CLI is a
foreground `docker compose run`, so the signal reaches the driver inside the
container, the agent dies with it, and the container removes itself. Nothing
is lost: the next `phase-runner build` resumes as described above.

Closing that terminal or killing the tmux window instead stops only the
client. The container keeps running, with the agent still working and still
spending, and no terminal is attached to it any more. Finish the job by hand:

```bash
docker ps                    # a claude-phase-runner-runner-run-<id> container still listed?
docker stop <container id>   # ends the driver and the agent; the container removes itself
```

Do this before starting another `phase-runner build` for the same project: two
drivers on one `.phase-runner/state` and one working tree would step on each
other. With `DOCKER_SOCKET=1`, containers the agent started for the project's
stack are siblings on the host daemon and outlive the runner; `docker ps` lists
them too, and they need their own `docker stop` or the project's
`docker compose down`.

