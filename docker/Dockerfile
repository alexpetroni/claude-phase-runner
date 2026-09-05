# Runner image: executes the Claude Code agents (builder, reviewer, report
# passes) against a target project mounted at its host path. Needs git, the
# Docker CLI + compose plugin (to drive the project's stack via the host Docker
# socket — "Docker-out-of-Docker"), a node toolchain, jq, and Claude Code.
#
# Project-specific toolchains: node + pnpm are baked in (covers most JS/TS
# repos). For other stacks set EXTRA_APT_PACKAGES in .phase-runner/runner.env.
# Pin CLAUDE_CODE_VERSION there for reproducible runs (default: latest).
FROM node:24-bookworm

ARG EXTRA_APT_PACKAGES=""
ARG CLAUDE_CODE_VERSION="latest"

# Docker CLI + compose plugin (talks to the host daemon via the mounted socket)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git jq gosu openssh-client ${EXTRA_APT_PACKAGES} \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# pnpm (via corepack) + Claude Code. A project that pins a different pnpm in
# `packageManager` makes corepack download it on first use; on a TTY (the gate
# inherits the driver's terminal) that download asks "[Y/n]" and hangs forever.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable \
 && corepack prepare pnpm@latest --activate \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# Baked copy of the kit; docker-compose.yml bind-mounts the live one over it so
# driver/prompt/guard edits take effect without a rebuild.
ENV PHASE_RUNNER_HOME=/opt/phase-runner
COPY docker  /opt/phase-runner/docker
COPY prompts /opt/phase-runner/prompts

ENTRYPOINT ["bash", "/opt/phase-runner/docker/bootstrap.sh"]
