# Runner image: executes the Claude Code agent that builds a target project
# phase by phase. Needs git, the Docker CLI + compose plugin (to drive the
# project's stack via the host Docker socket — "Docker-out-of-Docker"), a node
# toolchain, and Claude Code.
#
# Project-specific toolchains: node+pnpm are baked in (covers most JS/TS
# repos). For other stacks, add packages via EXTRA_APT_PACKAGES:
#   docker compose build --build-arg EXTRA_APT_PACKAGES="python3 python3-pip"
FROM node:24-bookworm

ARG EXTRA_APT_PACKAGES=""

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

# pnpm (via corepack) + Claude Code
RUN corepack enable \
 && corepack prepare pnpm@latest --activate \
 && npm install -g @anthropic-ai/claude-code

COPY docker/bootstrap.sh /usr/local/bin/bootstrap.sh
COPY docker/driver.sh /usr/local/bin/driver.sh
RUN chmod +x /usr/local/bin/bootstrap.sh /usr/local/bin/driver.sh

ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]
