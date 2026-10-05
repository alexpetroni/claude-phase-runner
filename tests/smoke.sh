#!/usr/bin/env bash
# The real container, end to end, without an API call: builds the runner image
# under its own tag (RUNNER_IMAGE, so the image real runs use is never
# replaced), runs the real CLI in `build --dry-run` mode against a throwaway
# project with a dummy ANTHROPIC_API_KEY once per DOCKER_SOCKET value, and
# checks the lines only a container shows: the bootstrap's socket line, the
# dry-run banner, the no-Docker note in the printed builder prompt. With
# DOCKER_SOCKET=0 an entrypoint override also proves `docker info` fails inside.
#   bash tests/smoke.sh      # needs a Docker daemon: one SKIP line and rc 0 without one
# Leaves behind: the image claude-phase-runner:smoke (a cache hit next time;
# `docker image rm claude-phase-runner:smoke` drops it). The throwaway project
# and the credentials file are removed on exit, pass or fail.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: no Docker daemon reachable — the container smoke test did not run"
  exit 0
fi

export RUNNER_IMAGE=claude-phase-runner:smoke
S="$(mktemp -d "${TMPDIR:-/tmp}/phase-runner-smoke.XXXXXX")"
P="$S/project"
cleanup() {
  rm -rf "$S" 2>/dev/null
  # The container writes as uid 1000. On a host whose user is someone else
  # (GitHub's runner is uid 1001) files it created inside directories of its
  # own cannot be deleted from the host, so finish as root through the image.
  if [[ -e "$S" ]]; then
    docker run --rm -v "$S:/scratch" --entrypoint bash "$RUNNER_IMAGE" -c 'rm -rf /scratch/*' >/dev/null 2>&1
    rm -rf "$S"
  fi
}
trap cleanup EXIT

FAILED=0
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { FAILED=$((FAILED + 1)); printf '  ✗ %s\n' "$*"; }
assert_eq()       { [[ "$1" == "$2" ]] && ok "$3" || fail "$3: expected '$2', got '$1'"; }
assert_grep()     { grep -qE -- "$1" "$2" && ok "$3" || fail "$3: '$1' not in ${2#"$S"/}"; }
assert_not_grep() { if grep -qE -- "$1" "$2"; then fail "$3: '$1' unexpectedly in ${2#"$S"/}"; else ok "$3"; fi; }

# ── Throwaway project: a git repository with an entry file and one phase ────
# state/logs and home are created up front and the whole project is made
# world-writable: the container's `node` user (uid 1000) must be able to write
# it whoever the host user is (GitHub's runner is uid 1001).
mkdir -p "$P/plan" "$P/.phase-runner/state/logs" "$P/.phase-runner/home"
git -C "$P" init -q -b main
git -C "$P" config user.email smoke@phase.local
git -C "$P" config user.name Smoke
printf '# Entry\n\nSmoke test: no agent is launched.\n' > "$P/plan/ENTRY.md"
printf '# Phase A\n\n## Definition of Done\n\n- [ ] A works\n' > "$P/plan/A.md"
git -C "$P" add -A && git -C "$P" commit -q -m init
printf 'plan/A.md\n' > "$P/.phase-runner/phases"
printf 'ANTHROPIC_API_KEY=smoke-dummy-key-never-used\n' > "$S/creds.env"
chmod -R a+rwX "$P"

dry_run() {  # dry_run DOCKER_SOCKET → RC, OUT (the CLI's output, bootstrap and driver included)
  printf 'ENTRY_FILE=plan/ENTRY.md\nPUSH=0\nDOCKER_SOCKET=%s\n' "$1" > "$P/.phase-runner/runner.env"
  OUT="$S/dry-run-$1.log"
  PHASE_RUNNER_CREDENTIALS="$S/creds.env" \
    bash "$KIT/bin/phase-runner" --project "$P" build --dry-run >"$OUT" 2>&1 </dev/null
  RC=$?
}

echo "▶ DOCKER_SOCKET=0: build --dry-run through the CLI (builds $RUNNER_IMAGE on first use)"
dry_run 0
assert_eq "$RC" 0 "exit status"
assert_grep 'DRY RUN' "$OUT" "dry-run banner"
assert_grep 'No Docker socket \(DOCKER_SOCKET=0\)' "$OUT" "bootstrap: no Docker socket"
assert_grep 'docker socket: off' "$OUT" "driver banner: docker socket off"
assert_grep 'No Docker in this run' "$OUT" "builder prompt: the no-Docker note"

echo "▶ DOCKER_SOCKET=0: docker info inside the container (entrypoint override)"
# Compose directly, with the variables the CLI exports for it.
PROBE="$S/probe-0.log"
( cd "$KIT" && CREDENTIALS_FILE="$S/creds.env" PROJECT_DIR="$P" ENTRY_FILE=plan/ENTRY.md \
    PHASE_FILES=plan/A.md AGENT_HOME="$P/.phase-runner/home" HOST_SSH_AUTH_SOCK=/dev/null \
    RUNNER_MODE=dry-run PUSH=0 DOCKER_SOCKET=0 HOST_DOCKER_SOCK=/dev/null \
    docker compose -f docker-compose.yml run --rm -T --entrypoint bash runner \
      -c 'docker info >/dev/null 2>&1 && echo REACHABLE || echo UNREACHABLE' ) >"$PROBE" 2>&1
assert_grep '^UNREACHABLE$' "$PROBE" "docker info fails inside the container"
assert_not_grep '^REACHABLE$' "$PROBE" "no daemon reachable inside the container"

echo "▶ DOCKER_SOCKET=1: build --dry-run through the CLI with the host socket"
dry_run 1
assert_eq "$RC" 0 "exit status"
assert_grep 'DRY RUN' "$OUT" "dry-run banner"
assert_grep "Docker daemon reachable as 'node'" "$OUT" "bootstrap: daemon reachable"
assert_grep 'docker socket: on' "$OUT" "driver banner: docker socket on"
assert_not_grep 'No Docker in this run' "$OUT" "builder prompt: no no-Docker note"

echo
if (( FAILED )); then
  printf '✗ %d smoke assertion(s) failed\n' "$FAILED"
  for f in "$S"/*.log; do
    echo "── ${f#"$S"/} (last 40 lines)"; tail -n 40 "$f"
  done
  exit 1
fi
echo "✓ smoke test passed ($RUNNER_IMAGE kept for the next run)"
