#!/usr/bin/env bash
# Host launcher. Usage:
#   bash run.sh [path/to/runner.env]      # defaults to ./runner.env
#   DRY_RUN=1 bash run.sh                 # validate config + print first prompt, no agent
#
# Reads the config, validates it, builds the image, and runs the container.
# Re-running after a crash resumes from the first unfinished phase (state/).
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$KIT_DIR/runner.env}"

die() { echo "✗ $*" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG (copy runner.env.example to runner.env and edit it)"
[[ -f "$KIT_DIR/credentials.env" ]] || die "credentials.env not found (copy credentials.env.example and add your token)"

set -a
# shellcheck source=/dev/null
source "$CONFIG"
set +a

[[ -n "${PROJECT_DIR:-}" ]] || die "PROJECT_DIR is not set in $CONFIG"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)" || die "PROJECT_DIR does not exist: $PROJECT_DIR"
export PROJECT_DIR
[[ -d "$PROJECT_DIR/.git" ]] || die "PROJECT_DIR is not a git repository: $PROJECT_DIR"
[[ -n "${ENTRY_FILE:-}" ]] || die "ENTRY_FILE is not set in $CONFIG"
[[ -f "$PROJECT_DIR/$ENTRY_FILE" ]] || die "entry file not found: $PROJECT_DIR/$ENTRY_FILE"
[[ -n "${PHASE_FILES:-}" ]] || die "PHASE_FILES is not set in $CONFIG"
for p in $PHASE_FILES; do
  [[ -f "$PROJECT_DIR/$p" ]] || die "phase file not found: $PROJECT_DIR/$p"
done

# SSH agent passthrough for pushes (falls back to /dev/null → HTTPS-token
# remotes still work; SSH remotes won't without an agent).
export HOST_SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-/dev/null}"
if [[ "$HOST_SSH_AUTH_SOCK" == "/dev/null" && "${PUSH:-1}" == "1" ]]; then
  remote_url="$(git -C "$PROJECT_DIR" remote get-url "${GIT_REMOTE:-origin}" 2>/dev/null || true)"
  if [[ "$remote_url" == git@* || "$remote_url" == ssh://* ]]; then
    echo "⚠ No SSH agent (SSH_AUTH_SOCK unset) but the push remote is SSH: $remote_url" >&2
    echo "  Start an agent (eval \$(ssh-agent); ssh-add) or switch the remote to HTTPS+token." >&2
  fi
fi

export DRY_RUN="${DRY_RUN:-}"
mkdir -p "$KIT_DIR/state/logs"

echo "▶ Project:  $PROJECT_DIR"
echo "▶ Entry:    $ENTRY_FILE"
echo "▶ Phases:   $PHASE_FILES"
echo "▶ Retries:  ${RETRY_SCHEDULE:-30 300 3600 10800} (seconds between attempts)"
echo "▶ Push:     ${PUSH:-1} → ${GIT_REMOTE:-origin}/${GIT_BRANCH:-<current>}"
[[ -n "$DRY_RUN" ]] && echo "▶ DRY RUN — no agent will be launched"

cd "$KIT_DIR"
docker compose build runner
exec docker compose run --rm runner
