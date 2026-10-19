[claude-phase-runner](../README.md) · [Documentation](README.md)

# Enforcement — the guard hook

`docker/guard.sh` runs as a `PreToolUse` hook on every `Bash`, `Edit`, `Write`,
`MultiEdit` and `NotebookEdit` call of every role (injected with `--settings`,
so nothing is added to the project). A blocked call returns its reason to the
model, which then routes around it instead of retrying blindly.

Every role: no `git push` (the runner pushes), no `reset --hard`, `clean -f`,
`checkout .`, `branch -D`, rebase or other history rewriting, no `--no-verify`,
no `sudo`, no `rm -rf` of root/home/`.git`, no `docker … prune` (the socket is
the host's), no `curl | sh`, and **no modification of the entry file, the
phase files or `.phase-runner/`** — through file tools or shell redirects.
Reading them is fine. **No SSH**, because the forwarded agent is the runner's
push credential: no `ssh`, `scp`, `sftp`, `ssh-add` or `ssh-agent` at a
command position (also after `timeout N`, `env VAR=…`, `&&`, `;`, `|` or
inside `$( )`; named by its path, `/usr/bin/ssh` or `./ssh`; as the command
of `bash -c`, `sh -c` or `xargs`), no `rsync` with `-e ssh` or `--rsh=ssh`,
no command that mentions `SSH_AUTH_SOCK` or `/ssh-agent`, and
no git command with its own SSH transport (a `git@host:` or `ssh://` URL,
`core.sshCommand`, `GIT_SSH`, `GIT_SSH_COMMAND`). Public sources over HTTPS
(`git clone https://…`, `git ls-remote https://…`), `git fetch` on the
existing remote, `rsync` between local paths, and reading or grepping files
that contain the word (`cat /etc/ssh/ssh_config`, `ls ~/.ssh`) stay allowed.

Read-only roles (reviewer, preflight, final review): additionally no edit
tools at all, no git mutation of any kind, no publishing. After a read-only
role finishes, a dirty working tree is reset to HEAD and logged.

The guard fails open on unparseable input and is covered by `tests/guard.sh`;
add a case there for every new rule — an unverified guardrail is a decoration.

