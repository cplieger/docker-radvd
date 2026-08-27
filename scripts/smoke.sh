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
start_container "$C1" --cap-add NET_RAW
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
# The directory entrypoint.sh creates must be the one radvd's compiled-in
# --with-pidfile writes into; nothing else reads that Dockerfile coupling.
docker exec "$C1" test -f /run/radvd/radvd.pid \
  || fail "radvd did not write its pid file to /run/radvd (Dockerfile --with-pidfile vs the entrypoint's mkdir)"
printf '[smoke] PASS  startup: radvd up, preflight warned, healthcheck healthy, privileges dropped\n'

# --- 2. HUP reload (world-readable config) -----------------------------------
pid_before=$(docker exec "$C1" pidof radvd) || fail "cannot read radvd pid"
job_status_before=$(docker logs "$C1" 2>&1 | grep -Ec '^(Terminated|Killed)$' || true)
docker kill -s HUP "$C1" >/dev/null
pid_after=$(wait_for_reload "$C1" 1 "$pid_before")
[ -n "$pid_after" ] || fail "HUP did not reload radvd (no reload log, or PID unchanged)"
[ "$(docker inspect -f '{{.State.Running}}' "$C1")" = "true" ] || fail "container not running after HUP reload"
[ "$(docker logs "$C1" 2>&1 | grep -c 'no AdvRASrcAddress directive found')" -ge 2 ] \
  || fail "reload did not re-run the HA-directive validation"
job_status_after=$(docker logs "$C1" 2>&1 | grep -Ec '^(Terminated|Killed)$' || true)
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
docker logs "$C1" 2>&1 | grep -q 'failed to read config file' \
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

# --- 4. graceful shutdown on SIGTERM -----------------------------------------
job_status_before=$(docker logs "$C1" 2>&1 | grep -Ec '^(Terminated|Killed)$' || true)
docker stop "$C1" >/dev/null
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C1")
[ "$ec" = "0" ] || fail "docker stop exit code $ec, want 0"
wait_for_log "$C1" 'radvd stopped on shutdown signal' "missing graceful shutdown log line"
job_status_after=$(docker logs "$C1" 2>&1 | grep -Ec '^(Terminated|Killed)$' || true)
[ "$job_status_after" -eq "$job_status_before" ] \
  || fail "graceful shutdown leaked a bare BusyBox ash job-status line into docker logs"
printf '[smoke] PASS  shutdown: SIGTERM exits 0 with graceful log\n'

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
docker logs "$C1" 2>&1 | grep -Eq "$ALERT_RULE" \
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

# --- 5. unexpected radvd death propagates to the container --------------------
printf '[smoke] starting %s (exit-propagation scenario)\n' "$C2"
start_container "$C2" --cap-add NET_RAW
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
docker logs "$C3" 2>&1 | grep -q 'msg="starting radvd"' && fail "radvd was started despite an invalid RADVD_DEBUG_LEVEL"
printf '[smoke] PASS  validation: invalid RADVD_DEBUG_LEVEL fails closed (exit 1, sanitized error)\n'

# --- 7. a non-regular node at the config path fails closed ---------------------
# radvd cannot consume a non-regular node as its configuration file, so the
# entrypoint refuses instead of degrading to a warning. This case uses a
# DIRECTORY, whose refusal is deterministic in an assembled image; the
# FIFO-with-no-writer variant — where radvd's open blocks while `pidof radvd`
# keeps the healthcheck green — belongs to the bounded shell test
# (tests/shell/ha_directives_test.sh case 12).
printf '[smoke] starting %s (a directory where radvd.conf belongs)\n' "$C4"
docker create --name "$C4" --network none --cap-add NET_RAW "$IMAGE" >/dev/null
docker cp "$TMPDIR_NONFILE" "$C4:/etc/radvd" >/dev/null
docker start "$C4" >/dev/null
wait_until_stopped "$C4" "container still running with a non-regular radvd.conf"
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C4")
[ "$ec" = "1" ] || fail "non-regular radvd.conf exit code $ec, want 1"
wait_for_log "$C4" 'msg="radvd.conf is not a regular file' "missing non-regular-config fatal line"
docker logs "$C4" 2>&1 | grep -Eq "$ALERT_RULE" \
  || fail "the non-regular-config fatal does not match the README's RadvdConfigError pattern"
# Absence assertion: single-shot on purpose, and safe here only because the
# wait_for_log above already proved this container's log is flushed.
docker logs "$C4" 2>&1 | grep -q 'msg="starting radvd"' && fail "radvd was started despite a non-regular radvd.conf"
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
docker logs "$C5" 2>&1 | grep -Eq "$ALERT_RULE" \
  || fail "the PID-directory fatal does not match the README's RadvdConfigError pattern"
docker logs "$C5" 2>&1 | grep -q 'msg="starting radvd"' && fail "radvd was started despite a read-only /run"
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
# without CAP_KILL cannot signal it. A new pid plus a still-running container is
# what sees that: the refused kill is logged but the reload proceeds anyway, a
# second radvd is started beside the live one, dies on the pid-file lock, and the
# container exits on the propagated failure. A log grep is not that oracle — it is
# keyed to radvd's own wording at the pinned version.
pid_before=$(docker exec "$C6" pidof radvd) || fail "hardened profile: cannot read radvd pid"
docker kill -s HUP "$C6" >/dev/null
pid_after=$(wait_for_reload "$C6" 1 "$pid_before")
[ -n "$pid_after" ] || fail "hardened profile: HUP did not reload radvd (no reload log, PID unchanged, or the container died)"
[ "$(docker inspect -f '{{.State.Running}}' "$C6")" = "true" ] \
  || fail "hardened profile: container not running after HUP reload (KILL missing from the profile is the usual cause: a second radvd then races the live one and dies on the pid-file lock)"
docker stop "$C6" >/dev/null
ec=$(docker inspect -f '{{.State.ExitCode}}' "$C6")
[ "$ec" = "0" ] || fail "hardened profile: docker stop exit code $ec, want 0"
wait_for_log "$C6" 'radvd stopped on shutdown signal' "hardened profile: missing graceful shutdown log line"
printf '[smoke] PASS  hardened caps: the published profile boots, drops privileges, reloads on HUP (pid %s -> %s) and stops gracefully\n' "$pid_before" "$pid_after"

printf '[smoke] OK — all signal-contract assertions passed for %s\n' "$IMAGE"
