#!/usr/bin/env bash
# Container entrypoint. Starts as root to align the Docker socket group, then
# drops to the non-root `node` user (uid 1000 — matches the typical host repo
# owner) to run the driver. Claude Code refuses --dangerously-skip-permissions
# as root, hence the privilege drop. The container is sandboxed, so skipping
# permissions is safe here.
set -euo pipefail

cd "${PROJECT_DIR:?PROJECT_DIR is not set}"

# ── Credentials: EITHER OAuth token (subscription) OR API key. OAuth wins. ──
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  echo "✓ Authenticating with CLAUDE_CODE_OAUTH_TOKEN (subscription)."
  unset ANTHROPIC_API_KEY
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "✓ Authenticating with ANTHROPIC_API_KEY (API billing)."
else
  echo "ERROR: no credentials. Put CLAUDE_CODE_OAUTH_TOKEN (from 'claude setup-token')" >&2
  echo "       or ANTHROPIC_API_KEY in credentials.env." >&2
  exit 1
fi

# ── Grant the `node` user access to the host Docker socket (DooD) ──
if [[ -S /var/run/docker.sock ]]; then
  SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
  if ! getent group "$SOCK_GID" >/dev/null; then
    groupadd -g "$SOCK_GID" dockerhost
  fi
  usermod -aG "$(getent group "$SOCK_GID" | cut -d: -f1)" node
  if gosu node docker info >/dev/null 2>&1; then
    echo "✓ Docker daemon reachable as 'node' (docker-out-of-docker enabled)."
  else
    echo "⚠ Docker socket present but not reachable as 'node'." >&2
  fi
else
  echo "⚠ /var/run/docker.sock not mounted — docker-first verification disabled." >&2
fi

# ── Git identity + safety for the mounted repo, SSH for pushes ──
export HOME=/home/node
chown node:node /home/node 2>/dev/null || true
chown -R node:node /state 2>/dev/null || true
gosu node git config --global user.email "${GIT_AUTHOR_EMAIL:-runner@phase.local}"
gosu node git config --global user.name  "${GIT_AUTHOR_NAME:-Phase Runner}"
gosu node git config --global --add safe.directory "$(pwd)"

# Forwarded SSH agent (if the host had one) + tolerant host-key handling so an
# unattended push never blocks on an interactive known_hosts prompt.
if [[ -S /ssh-agent ]]; then
  export SSH_AUTH_SOCK=/ssh-agent
  echo "✓ SSH agent forwarded."
else
  unset SSH_AUTH_SOCK
fi
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

# Drop to non-root `node` and hand over to the driver (HOME carried for ~/.claude).
exec gosu node env HOME=/home/node \
  SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" GIT_SSH_COMMAND="$GIT_SSH_COMMAND" \
  /usr/local/bin/driver.sh
