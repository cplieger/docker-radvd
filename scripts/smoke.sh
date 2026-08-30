#!/usr/bin/env bash
# Signal-contract smoke test: proves the assembled image honors the supervising
# entrypoint's lifecycle contract against a running container; the section headers
# below name each scenario. Build-time config parsing is tests/smoke.sh's.
#
# Every container runs with --network none and a config naming an interface that
# does not exist ("IgnoreIfMissing on" keeps radvd alive), so no Router
# Advertisement is ever emitted. The mutable-permission scenarios receive the
# fixture by `docker cp`, which keeps scenario 3's root-only chmod off host
# permissions; the `--read-only` scenarios receive it by a `:ro` bind mount or not
# at all, because the daemon refuses an extract into a read-only rootfs.
#
# Usage:  scripts/smoke.sh [IMAGE]   (default docker-radvd:smoke; build it first)
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-docker-radvd:smoke}"
C1="radvd-smoke-$$"
C2="radvd-smoke-kill-$$"
C3="radvd-smoke-badlevel-$$"
C4="radvd-smoke-nonfile-$$"
C5="radvd-smoke-readonly-$$"
C6="radvd-smoke-hardened-$$"
TMPDIR_FIXTURE=""
TMPDIR_NONFILE=""

fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  for c in "$C1" "$C2" "$C3" "$C4" "$C5" "$C6"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      printf -- '--- %s logs (tail) ---\n' "$c" >&2
      docker logs "$c" 2>&1 | tail -25 >&2 || true
    fi
  done
  exit 1
}

cleanup() {
  docker rm -f "$C1" "$C2" "$C3" "$C4" "$C5" "$C6" >/dev/null 2>&1 || true
  [ -n "$TMPDIR_NONFILE" ] && rm -rf "$TMPDIR_NONFILE"
  [ -n "$TMPDIR_FIXTURE" ] && rm -rf "$TMPDIR_FIXTURE"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (docker build -t docker-radvd:smoke . first)"

# The published deployment contract, read from BOTH sides so editing either alone
# fails here. RAs are ICMPv6 on a real LAN interface, so the compose example a
# stranger copies out of this repo must put the service on the host network; on an
# isolated network radvd runs, `pidof radvd` stays green and nothing reaches the
# LAN. Scoped to the `radvd:` service rather than a file-wide grep, so the setting
# cannot pass by sitting under some other service.
compose_net=$(awk '/^  [[:alnum:]_-]+:[[:space:]]*$/ { svc = ($0 ~ /^  radvd:[[:space:]]*$/) } svc && /^[[:space:]]+network_mode:/ { print $2 }' compose.yaml)
# The sed script matches the README row's literal backticks, so nothing in it may
# expand: the single quotes are required.
# shellcheck disable=SC2016
readme_net=$(sed -n 's/^| `network_mode` *| `\([^`]*\)`.*/\1/p' README.md)
[ -n "$readme_net" ] || fail "could not read the network_mode row from the README's Networking table"
[ "$compose_net" = "host" ] || fail "compose.yaml's radvd service sets network_mode='$compose_net', want host: RAs cannot reach the LAN from an isolated network"
[ "$compose_net" = "$readme_net" ] || fail "compose.yaml ('$compose_net') and the README's Networking table ('$readme_net') disagree on network_mode"
printf '[smoke] PASS  published contract: compose.yaml and the README agree on network_mode=%s\n' "$compose_net"

# Fixture: only the valid config (tests/ also holds radvd.bad.conf, which is not
# the file the daemon is given with -C).
TMPDIR_FIXTURE=$(mktemp -d)
cp tests/radvd.conf "$TMPDIR_FIXTURE/radvd.conf"
# Scenarios 9 and 10 bind-mount this directory under profiles that drop DAC_OVERRIDE,
# so container-root cannot bypass the 0700 `mktemp -d` gives it, and the mode belongs to
# whoever runs the suite. As root that is invisible; as an unprivileged CI user radvd
# exits "permissions on conf_file invalid" before the scenario's first assertion. These
# modes are also what a real mount looks like: a deployed radvd.conf is 0644, and radvd's
# own conf_file check refuses only world-writable or radvd-writable files.
chmod 0755 "$TMPDIR_FIXTURE"
chmod 0644 "$TMPDIR_FIXTURE/radvd.conf"

# Second fixture, for scenario 7: a DIRECTORY where radvd.conf belongs. This is
# the shape a bind mount produces when the host path does not exist, and it is a
# node radvd's own open cannot consume.
TMPDIR_NONFILE=$(mktemp -d)
mkdir "$TMPDIR_NONFILE/radvd.conf"

# Create + inject config + start; wait until radvd runs inside. Any argument after
# the name is passed to `docker create` verbatim, which is how scenario 9 boots the
# same container under the README's hardened profile; NET_RAW comes from the caller
# so a drop of it from that profile fails an assertion. A caller that mounts the
# fixture itself (`:/etc/radvd:`, the only delivery a `--read-only` rootfs accepts)
# is not also sent a `docker cp` copy.
start_container() {
  local name=$1 ready
  shift
  docker create --name "$name" --network none "$@" "$IMAGE" >/dev/null
  case "$*" in
    *":/etc/radvd:"*) ;;
    *) docker cp "$TMPDIR_FIXTURE" "$name:/etc/radvd" >/dev/null ;;
  esac
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
# `docker logs … | grep -q` is a SIGPIPE trap under `pipefail`, and it reads as a flake.
# `grep -q` exits at its FIRST match and closes the pipe, so `docker logs` dies with 141 and
# the whole pipeline fails even though the line was there. Whether it bites depends on
# whether the writer finished before the reader left, so the same assertion passes and fails
# on identical code. It bit this suite when the RadvdConfigError pattern grew alternatives
# that match radvd's own startup lines near the TOP of a long log, maximising the window.
# So capture once and match the capture, per shell.md: a pipeline's status is the last
# command's, so capture and fan out rather than piping into a short-circuiting reader.
log_has() { grep -q -- "$2" <<<"$(docker logs "$1" 2>&1)"; }
log_has_re() { grep -Eq -- "$2" <<<"$(docker logs "$1" 2>&1)"; }

wait_for_log() {
  local name=$1 pattern=$2 what=$3
  for _ in $(seq 1 10); do
    if log_has "$name" "$pattern"; then
      return 0
    fi
    sleep 1
  done
  fail "$what"
}

# --- 1. startup + shipped healthcheck ---------------------------------------
printf '[smoke] starting %s (network none, fixture config)\n' "$C1"
start_container "$C1" --cap-add NET_RAW
logs=$(docker logs "$C1" 2>&1)
grep -q 'msg="starting radvd"' <<<"$logs" || fail "missing startup log line"
# tests/radvd.conf enables IgnoreIfMissing and carries no AdvSendAdvert on, so startup
# validation must emit exactly this warning (proves the preflight ran).
grep -q 'no enabled AdvSendAdvert on directive found' <<<"$logs" || fail "startup directive validation warning not emitted"
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
# The daemon runs as two processes (a root parent plus the dropped --username=radvd worker),
# so the drop is evidenced by the PRESENCE of a radvd-owned one, never by the absence
# of a root-owned one. Dropping `--username=radvd` from the entrypoint fails this by name.
owners=$(docker exec "$C1" ps -o user,comm | awk '$2 ~ /radvd/ { print $1 }' | sort -u)
grep -qx 'radvd' <<<"$owners" || fail "no radvd-owned radvd process; observed owners: $(tr '\n' ' ' <<<"$owners")"
# The directory entrypoint.sh creates must be the one radvd's compiled-in
# --with-pidfile writes into; nothing else reads that Dockerfile coupling.
docker exec "$C1" test -f /run/radvd/radvd.pid \
  || fail "radvd did not write its pid file to /run/radvd (Dockerfile --with-pidfile vs the entrypoint's mkdir)"
printf '[smoke] PASS  startup: radvd up, preflight warned, healthcheck healthy, privileges dropped\n'

# --- 2. HUP reload (world-readable config) -----------------------------------
pid_before=$(docker exec "$C1" pidof radvd) || fail "cannot read radvd pid"
job_status_before=$(docker logs "$C1" 2>&1 | grep -Ec '^(Terminated|Killed|Aborted)$' || true)
docker kill -s HUP "$C1" >/dev/null
pid_after=$(wait_for_reload "$C1" 1 "$pid_before")
[ -n "$pid_after" ] || fail "HUP did not reload radvd (no reload log, or PID unchanged)"
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] || fail "container not running after HUP reload"
[ "$(docker logs "$C1" 2>&1 | grep -c 'no enabled AdvSendAdvert on directive found')" -ge 2 ] \
  || fail "reload did not re-run the directive validation"
job_status_after=$(docker logs "$C1" 2>&1 | grep -Ec '^(Terminated|Killed|Aborted)$' || true)
[ "$job_status_after" -eq "$job_status_before" ] \
  || fail "HUP reload leaked a bare BusyBox ash job-status line into docker logs"
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
log_has "$C1" 'failed to read config file' \
  && fail "radvd attempted its own unprivileged config reread (supervisor bypassed?)"
printf '[smoke] PASS  hardened reload: root-only config reloaded cleanly (pid %s -> %s)\n' "$pid_before" "$pid_after"

# --- HUP replacement waits for the previous generation to be reaped ---------
reload_before=$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)
hup_before=$(docker logs "$C1" 2>&1 | grep -c 'msg="SIGHUP received; restarting radvd to reload config"' || true)
read -r -a held_pids <<<"$pid_after"
[ "${#held_pids[@]}" -gt 0 ] || fail "reap-order setup found no radvd process to hold"
docker exec "$C1" sh -c 'kill -STOP "$@"' _ "${held_pids[@]}"
docker kill -s HUP "$C1" >/dev/null
hup_seen=""
for _ in $(seq 1 20); do
  hup_now=$(docker logs "$C1" 2>&1 | grep -c 'msg="SIGHUP received; restarting radvd to reload config"' || true)
  if [ "$hup_now" -gt "$hup_before" ]; then
    hup_seen=1
    break
  fi
  sleep 0.1
done
[ -n "$hup_seen" ] || fail "PID 1 did not handle HUP while the old radvd generation was held"
for _ in $(seq 1 20); do
  reload_now=$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)
  [ "$reload_now" -eq "$reload_before" ] \
    || fail "replacement startup began before the previous radvd generation was reaped"
  sleep 0.1
done
docker exec "$C1" sh -c 'kill -CONT "$@"' _ "${held_pids[@]}"
pid_before=$pid_after
pid_after=$(wait_for_reload "$C1" "$((reload_before + 1))" "$pid_before")
[ -n "$pid_after" ] || fail "HUP reload did not complete after the held radvd generation resumed"
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] \
  || fail "container stopped after the reap-order reload"
printf '[smoke] PASS  reap order: replacement waited for the previous radvd generation to exit\n'

# --- 4. graceful shutdown survives a second trapped signal during reap -------
held=$(docker exec "$C1" pidof radvd) || fail "cannot read radvd pids before shutdown"
read -r -a held_pids <<<"$held"
docker exec "$C1" sh -c 'kill -STOP "$@"' _ "${held_pids[@]}"
docker kill -s TERM "$C1" >/dev/null
wait_for_log "$C1" 'shutdown signal received; stopping radvd' "PID 1 did not enter shutdown"
docker kill -s HUP "$C1" >/dev/null
sleep 1
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] \
  || fail "a second trapped signal interrupted the shutdown reap while radvd was still held"
log_has "$C1" 'radvd stopped on shutdown signal' \
  && fail "PID 1 reported a graceful stop before the held radvd generation was reaped"
docker exec "$C1" sh -c 'kill -CONT "$@"' _ "${held_pids[@]}"
wait_until_stopped "$C1" "container did not stop after the held radvd generation resumed"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C1")
[ "$ec" = "0" ] || fail "second-signal shutdown exit code $ec, want 0"
wait_for_log "$C1" 'radvd stopped on shutdown signal' "missing graceful shutdown log after the child was reaped"
printf '[smoke] PASS  shutdown reap: a second trapped signal did not let PID 1 outlive its child\n'

# The README's RadvdConfigError rule is an exact-string contract between the
# entrypoint's fatal lines and an operator's Loki rule, so the refusal
# scenarios below match their output against the rule's own `|~` pattern as the
# regex Loki will use, pulled from the README beside this script rather than from
# the copy the test stage puts in the image. Scoped to that one rule, and an empty
# extraction fails here instead of matching silently.
# The sed script matches the README's literal `|~ `pattern` [10m]` line, backticks
# included, so the single quotes are required: nothing here may expand.
# shellcheck disable=SC2016
ALERT_RULE=$(sed -n '/alert: RadvdConfigError/,/^        for:/p' README.md \
  | sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\]$/\1/p')
[ -n "$ALERT_RULE" ] || fail "could not extract the RadvdConfigError pattern from README.md"

# --- a malformed replacement config on HUP is refused, and radvd keeps serving --
# The reload stops radvd before its replacement reads the config, so accepting a
# bad edit costs the segment its RA emitter. The configtest in on_hup refuses
# instead, and radvd's own rejection text still reaches the log for the operator's
# alert rule.
printf '[smoke] restarting %s (malformed HUP replacement scenario)\n' "$C1"
docker start "$C1" >/dev/null
ready=""
for _ in $(seq 1 15); do
  if docker exec "$C1" pidof radvd >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ -n "$ready" ] || fail "$C1: radvd did not return before malformed-reload setup"
pid_before=$(docker exec "$C1" pidof radvd) || fail "cannot read the radvd pid before the malformed reload"
reload_before=$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)
docker cp tests/radvd.bad.conf "$C1:/etc/radvd/radvd.conf" >/dev/null
docker kill -s HUP "$C1" >/dev/null
wait_for_log "$C1" 'SIGHUP reload refused' "the malformed HUP replacement was not refused"
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] \
  || fail "the container died on a refused HUP reload instead of keeping its last good config"
[ "$(docker exec "$C1" pidof radvd)" = "$pid_before" ] \
  || fail "a refused reload replaced the running radvd (pids moved from $pid_before)"
log_has_re "$C1" "$ALERT_RULE" \
  || fail "the refused reload's radvd output does not match the README's RadvdConfigError pattern"
# Absence assertion: single-shot on purpose, and safe here only because the
# wait_for_log above already proved this container's log is flushed.
[ "$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)" -eq "$reload_before" ] \
  || fail "a refused reload still restarted radvd"
# The other direction: the refusal must not wedge the reload path for a config the
# operator then fixes.
docker cp tests/radvd.conf "$C1:/etc/radvd/radvd.conf" >/dev/null
docker kill -s HUP "$C1" >/dev/null
pid_after=$(wait_for_reload "$C1" "$((reload_before + 1))" "$pid_before")
[ -n "$pid_after" ] || fail "a corrected config did not reload after a refused one"
printf '[smoke] PASS  malformed reload: refused with radvd still serving (pids %s), and a corrected config reloads\n' "$pid_before"

# --- unexpected death after an accepted reload still propagates ------------
pid_before=$(docker exec "$C1" pidof radvd) || fail "cannot read radvd pid before the post-reload propagation scenario"
reload_before=$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)
docker kill -s HUP "$C1" >/dev/null
pid_after=$(wait_for_reload "$C1" "$((reload_before + 1))" "$pid_before")
[ -n "$pid_after" ] || fail "the setup reload did not complete before the propagation check"
reload_after=$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)
docker exec "$C1" sh -c 'kill -KILL $(pidof radvd)'
wait_until_stopped "$C1" "container still running after radvd was SIGKILLed following a reload"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C1")
[ "$ec" = "137" ] || fail "post-reload propagated exit code $ec, want 137"
wait_for_log "$C1" 'radvd exited; propagating exit for restart policy' "missing post-reload exit-propagation log line"
[ "$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)" -eq "$reload_after" ] \
  || fail "the unexpected post-reload death was mistaken for another deliberate reload"
printf '[smoke] PASS  post-reload propagation: radvd death exits container with 137\n'

# --- shutdown wins while an accepted HUP is still in flight -----------------
docker start "$C1" >/dev/null
ready=""
for _ in $(seq 1 15); do
  if docker exec "$C1" pidof radvd >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ -n "$ready" ] || fail "$C1: radvd did not return before the overlapping-signal scenario"
held=$(docker exec "$C1" pidof radvd) || fail "cannot read radvd pids for the overlapping-signal scenario"
read -r -a held_pids <<<"$held"
reload_before=$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)
hup_before=$(docker logs "$C1" 2>&1 | grep -c 'msg="SIGHUP received; restarting radvd to reload config"' || true)
docker exec "$C1" sh -c 'kill -STOP "$@"' _ "${held_pids[@]}"
docker kill -s HUP "$C1" >/dev/null
hup_seen=""
for _ in $(seq 1 20); do
  hup_now=$(docker logs "$C1" 2>&1 | grep -c 'msg="SIGHUP received; restarting radvd to reload config"' || true)
  if [ "$hup_now" -gt "$hup_before" ]; then
    hup_seen=1
    break
  fi
  sleep 0.1
done
[ -n "$hup_seen" ] || fail "PID 1 did not accept HUP while the old generation was held"
docker kill -s TERM "$C1" >/dev/null
docker exec "$C1" sh -c 'kill -CONT "$@"' _ "${held_pids[@]}"
wait_until_stopped "$C1" "container restarted radvd instead of honoring shutdown during an in-flight HUP"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C1")
[ "$ec" = "0" ] || fail "overlapping HUP/TERM exit code $ec, want 0"
wait_for_log "$C1" 'radvd stopped on shutdown signal' "missing graceful shutdown log after overlapping HUP and TERM"
[ "$(docker logs "$C1" 2>&1 | grep -c 'msg="reloading radvd (config re-read via restart)"' || true)" -eq "$reload_before" ] \
  || fail "a replacement radvd started after TERM took precedence over the in-flight HUP"
printf '[smoke] PASS  signal precedence: shutdown beat the in-flight HUP reload\n'

# --- 5. a refused reload does not replace a later child exit status -----------
printf '[smoke] starting %s (refused-reload status propagation scenario)\n' "$C2"
start_container "$C2" --cap-add NET_RAW
pid_before=$(docker exec "$C2" pidof radvd) || fail "cannot read radvd pid before the refused-reload status scenario"
docker cp tests/radvd.bad.conf "$C2:/etc/radvd/radvd.conf" >/dev/null
docker kill -s HUP "$C2" >/dev/null
wait_for_log "$C2" 'SIGHUP reload refused' "the C2 malformed HUP replacement was not refused"
[ "$(docker inspect -f '{{.State.Running}}' "$C2")" = "true" ] \
  || fail "C2 stopped after the refused reload"
[ "$(docker exec "$C2" pidof radvd)" = "$pid_before" ] \
  || fail "C2 replaced radvd during the refused reload"
# pidof returns both radvd pids (root parent + dropped -u worker); word
# splitting inside the container shell is deliberate so kill gets each pid.
docker exec "$C2" sh -c 'kill -KILL $(pidof radvd)'
wait_until_stopped "$C2" "C2 still running after radvd was SIGKILLed following a refused reload"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C2")
[ "$ec" = "137" ] || fail "post-refusal propagated exit code $ec, want 137 (128+SIGKILL)"
wait_for_log "$C2" 'status="137"' "post-refusal propagation log did not carry the child status 137"
wait_for_log "$C2" 'radvd exited; propagating exit for restart policy' "missing post-refusal exit-propagation log line"
printf '[smoke] PASS  post-refusal propagation: radvd death exits container with 137\n'

# --- 6. fail-closed RADVD_DEBUG_LEVEL validation -------------------------------
printf '[smoke] starting %s (invalid RADVD_DEBUG_LEVEL scenario)\n' "$C3"
docker create --name "$C3" --network none --cap-add NET_RAW \
  -e "RADVD_DEBUG_LEVEL=$(printf '9"\302\205bogus')" "$IMAGE" >/dev/null
docker cp "$TMPDIR_FIXTURE" "$C3:/etc/radvd" >/dev/null
docker start "$C3" >/dev/null
wait_until_stopped "$C3" "container still running with an invalid RADVD_DEBUG_LEVEL"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C3")
[ "$ec" = "1" ] || fail "invalid RADVD_DEBUG_LEVEL exit code $ec, want 1"
wait_for_log "$C3" 'msg="invalid RADVD_DEBUG_LEVEL' "missing invalid-RADVD_DEBUG_LEVEL error line"
# Both sanitizer stages in one assertion, on the tr that actually ships: the quote
# maps to ? by the first stage, and U+0085's two bytes each map to a space by the
# second — which a no-op `tr -c` would leave raw.
wait_for_log "$C3" 'value="9?  bogus"' "sanitizer did not neutralize the quote and the C1 byte in the echoed value"
# Absence assertion: single-shot on purpose, and safe here only because the two
# wait_for_log calls above already proved this container's log is flushed.
log_has "$C3" 'msg="starting radvd"' && fail "radvd was started despite an invalid RADVD_DEBUG_LEVEL"
printf '[smoke] PASS  validation: invalid RADVD_DEBUG_LEVEL fails closed (exit 1, sanitized error)\n'

# --- 7. a non-regular node at the config path fails closed ---------------------
# radvd cannot consume a non-regular node as its configuration file, so the
# entrypoint refuses instead of degrading to a warning. This case uses a
# DIRECTORY, whose refusal is deterministic in an assembled image; the
# FIFO-with-no-writer variant — where radvd's open blocks while `pidof radvd`
# keeps the healthcheck green — belongs to the bounded shell test
# (tests/shell/ha_directives_test.sh case 11).
printf '[smoke] starting %s (a directory where radvd.conf belongs)\n' "$C4"
docker create --name "$C4" --network none --cap-add NET_RAW "$IMAGE" >/dev/null
docker cp "$TMPDIR_NONFILE" "$C4:/etc/radvd" >/dev/null
docker start "$C4" >/dev/null
wait_until_stopped "$C4" "container still running with a non-regular radvd.conf"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C4")
[ "$ec" = "1" ] || fail "non-regular radvd.conf exit code $ec, want 1"
wait_for_log "$C4" 'msg="radvd.conf is not a regular file' "missing non-regular-config fatal line"
log_has_re "$C4" "$ALERT_RULE" \
  || fail "the non-regular-config fatal does not match the README's RadvdConfigError pattern"
# Absence assertion: single-shot on purpose, and safe here only because the
# wait_for_log above already proved this container's log is flushed.
log_has "$C4" 'msg="starting radvd"' && fail "radvd was started despite a non-regular radvd.conf"
printf '[smoke] PASS  refusal: a non-regular radvd.conf fails closed (exit 1, alert-matching)\n'

# --- 8. read_only without a /run tmpfs fails closed ---------------------------
# The README's hardened profile states this exact failure for an operator who
# takes read_only: true without the tmpfs. Asserted here rather than only as a
# grep of the shipped script (config_triage_test.sh case 4), because the source
# check cannot show the path is reachable or that the exit code is 1. No fixture:
# the daemon refuses a `docker cp` into a read-only rootfs, and the absent config
# only warns, so the boot still reaches the PID-directory fatal.
printf '[smoke] starting %s (read_only, no /run tmpfs)\n' "$C5"
docker create --name "$C5" --network none --cap-add NET_RAW --read-only "$IMAGE" >/dev/null
docker start "$C5" >/dev/null
wait_until_stopped "$C5" "container still running with a read-only /run"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C5")
[ "$ec" = "1" ] || fail "read-only /run exit code $ec, want 1"
wait_for_log "$C5" 'failed to create radvd PID directory' "missing PID-directory fatal line"
log_has_re "$C5" "$ALERT_RULE" \
  || fail "the PID-directory fatal does not match the README's RadvdConfigError pattern"
log_has "$C5" 'msg="starting radvd"' && fail "radvd was started despite a read-only /run"
printf '[smoke] PASS  hardening: read_only without a /run tmpfs fails closed (exit 1)\n'

# --- 9. the README's hardened profile boots AND keeps the signal contract ------
# The README publishes this exact set, so it is read from one place here and any
# capability dropped from it must fail an assertion below; start_container grants
# no capability of its own, so this array is the container's whole set, and
# keeping the list verbatim is what makes it checkable against the README.
HARDENED_FLAGS=(--cap-drop ALL --cap-add NET_RAW --cap-add SETUID --cap-add SETGID
  --cap-add KILL --read-only --tmpfs /run:size=1m --security-opt no-new-privileges)
printf '[smoke] starting %s (README hardened profile: cap_drop ALL + the four documented caps)\n' "$C6"
# The fixture arrives as a `:ro` bind mount, not a `docker cp`: the daemon
# refuses an extract into a read-only rootfs.
start_container "$C6" "${HARDENED_FLAGS[@]}" -v "$TMPDIR_FIXTURE:/etc/radvd:ro"
# SETUID/SETGID: radvd exits 1 before start_container returns without them, so this
# names the cause the boot failure alone would not.
owners=$(docker exec "$C6" ps -o user,comm | awk '$2 ~ /radvd/ { print $1 }' | sort -u)
grep -qx 'radvd' <<<"$owners" \
  || fail "hardened profile: no radvd-owned radvd process (SETUID/SETGID missing from the profile is the usual cause); observed owners: $(tr '\n' ' ' <<<"$owners")"
# KILL, and this reload is the only assertion in the suite that can see it missing:
# the supervisor's child runs as the unprivileged radvd user, so a root PID 1
# without CAP_KILL cannot signal it. A MOVED pid is what sees that: without the
# capability the delivery is never observed, the reload never arms, and radvd keeps
# serving under the pid it already had. A log grep is not that oracle — it is keyed
# to radvd's own wording at the pinned version.
pid_before=$(docker exec "$C6" pidof radvd) || fail "hardened profile: cannot read radvd pid"
docker kill -s HUP "$C6" >/dev/null
pid_after=$(wait_for_reload "$C6" 1 "$pid_before")
[ -n "$pid_after" ] || fail "hardened profile: HUP did not reload radvd (no reload log, PID unchanged, or the container died)"
[ "$(docker inspect -f '{{.State.Running}}' "$C6")" = "true" ] \
  || fail "hardened profile: container not running after HUP reload (the replacement radvd exited)"
docker stop "$C6" >/dev/null
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C6")
[ "$ec" = "0" ] || fail "hardened profile: docker stop exit code $ec, want 0"
wait_for_log "$C6" 'radvd stopped on shutdown signal' "hardened profile: missing graceful shutdown log line"
printf '[smoke] PASS  hardened caps: the published profile boots, drops privileges, reloads on HUP (pid %s -> %s) and stops gracefully\n' "$pid_before" "$pid_after"

# --- 10. without CAP_KILL both signal paths report their own refusal ---------
(
  C7="radvd-smoke-no-kill-$$"
  # shellcheck disable=SC2317,SC2329  # invoked indirectly via trap
  cleanup_no_kill() {
    code=$?
    if [ "$code" -ne 0 ] && docker inspect "$C7" >/dev/null 2>&1; then
      printf -- '--- %s logs (tail) ---\n' "$C7" >&2
      docker logs "$C7" 2>&1 | tail -25 >&2 || true
    fi
    docker rm -f "$C7" >/dev/null 2>&1 || true
  }
  trap cleanup_no_kill EXIT

  # Derived from the published set rather than re-spelled: a hand-copied near-duplicate
  # drops out of step the moment the profile above changes.
  NO_KILL_FLAGS=()
  for f in "${HARDENED_FLAGS[@]}"; do
    if [ "$f" = KILL ] && [ "${NO_KILL_FLAGS[-1]}" = --cap-add ]; then
      unset "NO_KILL_FLAGS[-1]"
      continue
    fi
    NO_KILL_FLAGS+=("$f")
  done
  printf '[smoke] starting %s (hardened profile without CAP_KILL)\n' "$C7"
  start_container "$C7" "${NO_KILL_FLAGS[@]}" -v "$TMPDIR_FIXTURE:/etc/radvd:ro"
  # The root supervisor cannot signal its non-root child here, so the reload is
  # refused and radvd keeps serving. PID 1 staying up is load-bearing rather than
  # incidental: this `docker kill` has already disarmed the restart policy, so an
  # exit would leave the segment with no RA emitter until an operator intervenes.
  pid_before=$(docker exec "$C7" pidof radvd) || fail "no-KILL: cannot read the radvd pid before the HUP"
  docker kill -s HUP "$C7" >/dev/null
  wait_for_log "$C7" 'SIGHUP reload refused: TERM delivery to radvd could not be confirmed' \
    "no-KILL HUP was not refused"
  [ "$(docker inspect -f '{{.State.Running}}' "$C7")" = "true" ] \
    || fail "no-KILL HUP stopped the container instead of leaving radvd serving its last good config"
  [ "$(docker exec "$C7" pidof radvd)" = "$pid_before" ] \
    || fail "no-KILL HUP replaced radvd (pids moved from $pid_before)"
  printf '[smoke] PASS  no-KILL HUP: reload refused, radvd still serving (pids %s), container up\n' "$pid_before"
  docker stop -t 5 "$C7" >/dev/null
  ec=$(docker inspect -f '{{.State.ExitCode}}' "$C7")
  [ "$ec" = "0" ] || fail "no-KILL docker stop exit code $ec, want 0"
  wait_for_log "$C7" 'failed to deliver TERM to radvd' "no-KILL shutdown did not report the refused TERM"
  wait_for_log "$C7" 'a graceful stop cannot be confirmed' "no-KILL shutdown did not report its terminal disposition"
  log_has "$C7" 'radvd stopped on shutdown signal' \
    && fail "no-KILL shutdown falsely reported a graceful stop"
  printf '[smoke] PASS  no-KILL shutdown: refusal reported and PID 1 exited 0\n'
)

# --- 11. a TERM latched during preflight preserves structured logs ----------
(
  C8="radvd-smoke-startup-latch-$$"
  slow_cat="$TMPDIR_FIXTURE/slow-cat"
  # shellcheck disable=SC2317,SC2329  # invoked indirectly via trap
  cleanup_startup_latch() {
    code=$?
    if [ "$code" -ne 0 ] && docker inspect "$C8" >/dev/null 2>&1; then
      printf -- '--- %s logs (tail) ---\n' "$C8" >&2
      docker logs "$C8" 2>&1 | tail -25 >&2 || true
    fi
    docker rm -f "$C8" >/dev/null 2>&1 || true
    rm -f "$slow_cat"
  }
  trap cleanup_startup_latch EXIT

  # The shim IS the entrypoint's only pre-start read, so a TERM raised from inside it
  # lands in the preflight window by construction rather than by beating a sleep.
  printf '%s\n' '#!/bin/sh' 'kill -TERM 1' 'exec /bin/cat "$@"' >"$slow_cat"
  chmod +x "$slow_cat"
  docker create --name "$C8" --network none --cap-add NET_RAW \
    -v "$slow_cat:/usr/local/bin/cat:ro" "$IMAGE" >/dev/null
  docker cp "$TMPDIR_FIXTURE" "$C8:/etc/radvd" >/dev/null
  job_status_before=$(docker logs "$C8" 2>&1 | grep -Ec '^(Terminated|Killed|Aborted)$' || true)
  docker start "$C8" >/dev/null
  # What this scenario can and cannot assert, because the difference cost a red required
  # check on main. PID 1 latches the preflight TERM and then signals the child it has just
  # spawned (entrypoint.sh:318), so the delivery RACES radvd installing its own TERM
  # handler. Lose that race and the signal is swallowed by radvd's startup: the kill
  # reports success, radvd keeps running, and PID 1 blocks in `wait` on a child that will
  # never exit. Measured — 12/12 clean exits on an idle 20-core host, and a reproducible
  # stall on a loaded GitHub runner, where the log ends at `starting radvd` with no refusal
  # line. So neither "the container stops" nor "the child was stopped" is a property of
  # this image; both are properties of who won a race inside radvd. Asserting them made
  # this scenario a coin flip.
  # What IS deterministic is the latch itself, which is this scenario's actual subject and
  # is asserted below: PID 1 handled the TERM during preflight rather than dying on the
  # default disposition, and it did so without corrupting its structured log. The stop is
  # then forced explicitly, so the scenario ends in a known state either way. The delivery
  # path each disposition takes is already pinned deterministically elsewhere — the refused
  # arm by scenario 10, and the latch-to-fresh-child arm stub-free by cases 11/12 of
  # tests/shell/startup_latch_test.sh.
  wait_for_log "$C8" 'shutdown signal received; stopping radvd' \
    "the preflight TERM was not latched by PID 1"
  docker stop -t 10 "$C8" >/dev/null
  wait_until_stopped "$C8" "container did not stop after a latched preflight TERM"
  ec=$(docker inspect -f '{{.State.ExitCode}}' "$C8")
  [ "$ec" = "0" ] || fail "startup-latch TERM exit code $ec, want 0"
  latch_logs=$(docker logs "$C8" 2>&1) || fail "startup-latch: could not read the container logs"
  # on_term's first record (entrypoint.sh:100) precedes the pre-start record
  # (entrypoint.sh:322) only when the TERM was handled during preflight; both are
  # sequential writes from one process to one stderr. One awk pass over one snapshot:
  # nothing can SIGPIPE the producer, and an unreadable log fails above instead of
  # reading as an absent line.
  order=$(printf '%s\n' "$latch_logs" | awk '
    /msg="shutdown signal received; stopping radvd"/ && !latched { latched = NR }
    /msg="starting radvd"/ && !started { started = NR }
    END { print latched + 0, started + 0 }
  ')
  latched_at=${order% *}
  started_at=${order#* }
  [ "$latched_at" -gt 0 ] && [ "$started_at" -gt 0 ] && [ "$latched_at" -lt "$started_at" ] \
    || fail "startup-latch TERM was not handled during preflight (shutdown record $latched_at, startup record $started_at)"
  job_status_after=$(docker logs "$C8" 2>&1 | grep -Ec '^(Terminated|Killed|Aborted)$' || true)
  [ "$job_status_after" -eq "$job_status_before" ] \
    || fail "startup-latch TERM leaked a bare BusyBox ash job-status line into docker logs"
  printf '[smoke] PASS  startup latch: PID 1 handled a preflight TERM in order, without corrupting structured logs\n'
)

printf '[smoke] OK — all signal-contract assertions passed for %s\n' "$IMAGE"
