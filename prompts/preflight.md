{{ENTRY}}

---

# Runner instructions for this run

PRE-FLIGHT TOOLING ASSESSMENT — this runs BEFORE any building, read-only (edit tools are disabled). The phase plan for this project, in execution order:

{{PHASE_LIST}}

Read the entry prompt above and every phase file listed, then assess what TOOLING would make this build faster and more reliable: Claude Code skills, MCP servers, plugins, system/apt packages, and external services or credentials the phases will need. Check what is already present in this environment (installed packages, reachable docker daemon, project `.mcp.json`, existing skills) before recommending it.

For each recommendation state: what it is, which phase(s) need it, why, and exactly how the human provisions it here — a secret in `credentials.env`, a package in `EXTRA_APT_PACKAGES`, a skill or plugin dropped into the agent home (`.phase-runner/home/`), an MCP server in the project's `.mcp.json`, an image pre-pulled on the host, a Docker daemon for the agent via `DOCKER_SOCKET=1` in `.phase-runner/runner.env`. Flag anything requiring secrets or OAuth up front: the unattended runner cannot authenticate mid-build, so those must be in place before launch. Also list what should explicitly NOT be provisioned (live keys for services the plan says to mock, for example, or the host's Docker socket — `DOCKER_SOCKET=0` — when no phase needs containers).

Push access is checked by the runner itself, which holds the push credentials: do not probe SSH, the agent socket or the push remote in this assessment. Do not modify the project. Return the assessment as the `report` field, in Markdown, starting with a short table of items ordered by priority.
