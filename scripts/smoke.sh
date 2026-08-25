#!/usr/bin/env bash
# Signal-contract smoke test: proves the assembled image honors the supervising
# entrypoint's lifecycle contract — the reason the supervisor exists (see the
# entrypoint.sh header and CONTRIBUTING "Design boundaries"). The build-time
# tests/smoke.sh covers config parsing; this covers the running container:
#
#   1. startup      radvd comes up under the supervisor, Docker reports the
#                   shipped HEALTHCHECK healthy, and the daemon has dropped to
#                   the unprivileged radvd user
#   2. HUP reload   `docker kill -s HUP` restarts radvd (new PID), re-runs the
#                   HA-directive validation on the mounted config, and the
#                   container stays Up
#   3. hardened     the same reload with /etc/radvd root-only (0700) — the
#      reload       field failure the supervisor fixed (commit 8e7a792): radvd's
#                   own unprivileged reread would die here; the supervisor
#                   re-reads as root, so reload must still work
#   4. shutdown     `docker stop` (SIGTERM) exits 0 with the graceful log line
#   5. propagation  an unexpected radvd death (SIGKILL to the daemon) exits the
#                   container with the propagated code (137) so a restart
#                   policy would fire
#   6. validation   an invalid RADVD_DEBUG_LEVEL fails closed — the entrypoint
#                   exits 1 with a sanitized structured error line before
#                   radvd ever starts
#
# The container runs with --network none and a config for an interface that
# does not exist ("IgnoreIfMissing on" keeps radvd alive), so no Router
# Advertisement is ever emitted onto a real network segment. The config enters
# via `docker cp` (no bind mount), so the root-only chmod in scenario 3 never
# touches host permissions.
#
# Usage:  scripts/smoke.sh [IMAGE]
#   IMAGE defaults to docker-radvd:smoke. Build it first:
#     docker build -t docker-radvd:smoke .
#
# Requires docker. Exits non-zero on the first failed assertion and always
# removes the containers it started.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-docker-radvd:smoke}"
C1="radvd-smoke-$$"
C2="radvd-smoke-kill-$$"
C3="radvd-smoke-badlevel-$$"
TMPDIR_FIXTURE=""

fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  for c in "$C1" "$C2" "$C3"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      printf -- '--- %s logs (tail) ---\n' "$c" >&2
      docker logs "$c" 2>&1 | tail -25 >&2 || true
    fi
  done
  exit 1
}

cleanup() {
  docker rm -f "$C1" "$C2" "$C3" >/dev/null 2>&1 || true
  [ -n "$TMPDIR_FIXTURE" ] && rm -rf "$TMPDIR_FIXTURE"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (docker build -t docker-radvd:smoke . first)"

# Fixture: only the valid config (tests/ also holds radvd.bad.conf, which is not
# the file the daemon is given with -C).
TMPDIR_FIXTURE=$(mktemp -d)
cp tests/radvd.conf "$TMPDIR_FIXTURE/radvd.conf"

# Create + inject config + start; wait until radvd runs inside.
start_container() {
  local name=$1 ready
  docker create --name "$name" --network none --cap-add NET_RAW "$IMAGE" >/dev/null
  docker cp "$TMPDIR_FIXTURE" "$name:/etc/radvd" >/dev/null
  docker start "$name" >/dev/null
  ready=""
  for _ in $(seq 1 15); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
      fail "$name exited during startup"
    fi
    if docker exec "$name" pidof radvd >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ -n "$ready" ] || fail "$name: radvd never came up"
}

# Poll up to 10s until the container's reload log-line count reaches $2 and
# radvd runs with a PID set different from $3; prints the new PID set (empty
# on timeout) for the caller to assert on.
wait_for_reload() {
  local name=$1 want_count=$2 prev_pid=$3 pid=""
  for _ in $(seq 1 10); do
    if [ "$(docker logs "$name" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"')" -ge "$want_count" ]; then
      pid=$(docker exec "$name" pidof radvd 2>/dev/null || true)
      [ -n "$pid" ] && [ "$pid" != "$prev_pid" ] && break
      pid=""
    fi
    sleep 1
  done
  printf '%s' "$pid"
}

# Poll up to 10s until the container stops running; fails with $2 if it never does.
wait_until_stopped() {
  local name=$1 what=$2 running="true"
  for _ in $(seq 1 10); do
    running=$(docker inspect -f '{{.State.Running}}' "$name")
    [ "$running" = "false" ] && break
    sleep 1
  done
  [ "$running" = "false" ] || fail "$what"
}

# Poll up to 10s until $2 appears in the container's logs; fails with $3 if it
# never does.
#
# Required for any line written during shutdown. `docker stop` returns once the
# container has exited, but the json-file log driver can still be behind it, so
# a single grep reads a truncated log and reports a line the container did in
# fact write. Measured 2026-08-15: the scenario-4 assertion failed on main while
# the very failure dump it printed contained the line it had just missed, and
# the same commit had passed on its PR branch seven minutes earlier. An absence
# assertion cannot be polled, so keep those single-shot and place them AFTER a
# wait_for_log on the same container has proven the log flushed.
wait_for_log() {
  local name=$1 pattern=$2 what=$3
  for _ in $(seq 1 10); do
    if docker logs "$name" 2>&1 | grep -q "$pattern"; then
      return 0
    fi
    sleep 1
  done
  fail "$what"
}

# --- 1. startup + shipped healthcheck ---------------------------------------
printf '[smoke] starting %s (network none, fixture config)\n' "$C1"
start_container "$C1"
logs=$(docker logs "$C1" 2>&1)
grep -q 'msg="starting radvd"' <<<"$logs" || fail "missing startup log line"
# tests/radvd.conf carries IgnoreIfMissing but no AdvRASrcAddress, so startup
# validation must emit exactly this warning (proves the preflight ran).
grep -q 'no AdvRASrcAddress directive found' <<<"$logs" || fail "startup HA validation warning not emitted"
# Read Docker's own verdict instead of re-running the predicate: the shipped probe is
# exec form, so a shell-form `docker exec ... pidof radvd` would verify neither the
# probe nor its wiring, and start_container already required the predicate itself.
# The first probe lands one 30s interval after start, so this has to poll.
health=""
for _ in $(seq 1 12); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$C1")
  [ "$health" = "healthy" ] && break
  sleep 5
done
[ "$health" = "healthy" ] || fail "shipped HEALTHCHECK never reported healthy (last status: $health)"
# The daemon runs as two processes (a root parent plus the dropped -u radvd worker),
# so the drop is evidenced by the PRESENCE of a radvd-owned one, never by the absence
# of a root-owned one. Dropping `-u radvd` from the entrypoint fails this by name.
owners=$(docker exec "$C1" ps -o user,comm | awk '$2 ~ /radvd/ { print $1 }' | sort -u)
grep -qx 'radvd' <<<"$owners" || fail "no radvd-owned radvd process; observed owners: $(tr '\n' ' ' <<<"$owners")"
printf '[smoke] PASS  startup: radvd up, preflight warned, healthcheck healthy, privileges dropped\n'

# --- 2. HUP reload (world-readable config) -----------------------------------
pid_before=$(docker exec "$C1" pidof radvd) || fail "cannot read radvd pid"
docker kill -s HUP "$C1" >/dev/null
pid_after=$(wait_for_reload "$C1" 1 "$pid_before")
[ -n "$pid_after" ] || fail "HUP did not reload radvd (no reload log, or PID unchanged)"
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] || fail "container not running after HUP reload"
[ "$(docker logs "$C1" 2>&1 | grep -c 'no AdvRASrcAddress directive found')" -ge 2 ] \
  || fail "reload did not re-run the HA-directive validation"
printf '[smoke] PASS  HUP reload: radvd restarted (pid %s -> %s), validation re-ran, container Up\n' "$pid_before" "$pid_after"

# --- 3. HUP reload with a root-only config (the 8e7a792 field failure) -------
docker exec "$C1" sh -c 'chown -R root:root /etc/radvd && chmod -R 0700 /etc/radvd'
mode=$(docker exec "$C1" stat -c '%a %U' /etc/radvd)
[ "$mode" = "700 root" ] || fail "restricted-perms setup did not take effect (got: $mode)"
pid_before=$pid_after
docker kill -s HUP "$C1" >/dev/null
pid_after=$(wait_for_reload "$C1" 2 "$pid_before")
[ -n "$pid_after" ] || fail "HUP under a root-only config did not reload radvd"
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] || fail "container died on HUP under a root-only config (the 8e7a792 regression)"
docker logs "$C1" 2>&1 | grep -q 'failed to read config file' \
  && fail "radvd attempted its own unprivileged config reread (supervisor bypassed?)"
printf '[smoke] PASS  hardened reload: root-only config reloaded cleanly (pid %s -> %s)\n' "$pid_before" "$pid_after"

# --- 4. graceful shutdown on SIGTERM -----------------------------------------
docker stop "$C1" >/dev/null
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C1")
[ "$ec" = "0" ] || fail "docker stop exit code $ec, want 0"
wait_for_log "$C1" 'radvd stopped on shutdown signal' "missing graceful shutdown log line"
printf '[smoke] PASS  shutdown: SIGTERM exits 0 with graceful log\n'

# --- 5. unexpected radvd death propagates to the container --------------------
printf '[smoke] starting %s (exit-propagation scenario)\n' "$C2"
start_container "$C2"
# pidof returns both radvd pids (root parent + dropped -u worker); word
# splitting inside the container shell is deliberate so kill gets each pid.
docker exec "$C2" sh -c 'kill -KILL $(pidof radvd)'
wait_until_stopped "$C2" "container still running after radvd was SIGKILLed"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C2")
[ "$ec" = "137" ] || fail "propagated exit code $ec, want 137 (128+SIGKILL)"
wait_for_log "$C2" 'radvd exited; propagating exit for restart policy' "missing exit-propagation log line"
printf '[smoke] PASS  propagation: radvd death exits container with 137\n'

# --- 6. fail-closed RADVD_DEBUG_LEVEL validation -------------------------------
printf '[smoke] starting %s (invalid RADVD_DEBUG_LEVEL scenario)\n' "$C3"
docker create --name "$C3" --network none --cap-add NET_RAW \
  -e 'RADVD_DEBUG_LEVEL=9"bogus' "$IMAGE" >/dev/null
docker cp "$TMPDIR_FIXTURE" "$C3:/etc/radvd" >/dev/null
docker start "$C3" >/dev/null
wait_until_stopped "$C3" "container still running with an invalid RADVD_DEBUG_LEVEL"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C3")
[ "$ec" = "1" ] || fail "invalid RADVD_DEBUG_LEVEL exit code $ec, want 1"
wait_for_log "$C3" 'msg="invalid RADVD_DEBUG_LEVEL' "missing invalid-RADVD_DEBUG_LEVEL error line"
wait_for_log "$C3" 'value="9?bogus"' "sanitizer did not neutralize the quote in the echoed value"
# Absence assertion: single-shot on purpose, and safe here only because the two
# wait_for_log calls above already proved this container's log is flushed.
docker logs "$C3" 2>&1 | grep -q 'msg="starting radvd"' && fail "radvd was started despite an invalid RADVD_DEBUG_LEVEL"
printf '[smoke] PASS  validation: invalid RADVD_DEBUG_LEVEL fails closed (exit 1, sanitized error)\n'

printf '[smoke] OK — all signal-contract assertions passed for %s\n' "$IMAGE"
