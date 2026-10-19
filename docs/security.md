[claude-phase-runner](../README.md) · [Documentation](README.md)

# Security model — read this once

- The container is a sandbox **against accidents**, which is what makes
  `--dangerously-skip-permissions` acceptable: the agent cannot trash your
  host filesystem or shell config.
- It is **not** a hard boundary against a hostile agent: outbound network is
  open (the API, registries and `git push` need it), and the guard hook narrows
  what a *careless* agent can do; it is not a security boundary either.
- **The host Docker socket is the largest hole, and it is optional.** With
  `DOCKER_SOCKET=1` the agent can start containers on the host daemon, which
  is effectively host-root: a container it starts can mount any host path.
  That is the price of docker-first verification (a compose stack, a database
  or test containers). With `DOCKER_SOCKET=0` nothing is mounted (`/dev/null`
  sits at the socket path) and the agent is left with the project directory,
  its own home and the network. Projects created by `init` start at `0`; a `runner.env` without the setting keeps `1`, so existing projects
  behave as before until you add the line. Set `0` wherever the phases and the
  gate need no containers.
- **The forwarded SSH agent is the runner's, not the agent's.** When an SSH
  agent is forwarded for pushing it would open every host your loaded keys
  open, for as long as the run lasts. So the accidental path is closed: the
  `claude` process of every role and the gate command run without
  `SSH_AUTH_SOCK`, and the guard blocks `ssh`/`scp`/`sftp`/`ssh-add`/`ssh-agent`,
  any mention of `SSH_AUTH_SOCK` or `/ssh-agent`, and git over SSH. What
  remains, honestly: the driver and the agent run as the same user, so the
  socket file at `/ssh-agent` stays reachable by an agent that deliberately
  points `SSH_AUTH_SOCK` at it — the guard turns that into a blocked call and
  a visible transcript line, not into an impossibility. The hard fix is
  running the driver and the agent as different users, which is not done.
- Nothing is published inbound.
- Claude Code refuses to skip permissions as root, so `bootstrap.sh` starts as
  root only to align the docker-socket group (when the socket is mounted) and
  drops to the non-root `node` user (uid 1000, so file ownership matches the
  typical host user).
- The agent's credentials are environment variables in the container; the
  project never sees the file.

