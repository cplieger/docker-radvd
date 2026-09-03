#!/bin/sh
# Supervision lets SIGHUP re-read the config as root.
set -u

CONF="/etc/radvd/radvd.conf"

# BusyBox tr lacks [:print:], so preserve positions with a portable ASCII range.
sanitize_log_value() {
  # shellcheck disable=SC1003 # not an escape attempt: tr maps `"` and `\` to literal `?` (verified on BusyBox v1.37.0)
  _clean=$(printf '%s' "$1" | tr '"\\' '??' | LC_ALL=C tr -c '\040-\176' ' ')
  _capped=$(printf '%s' "$_clean" | cut -c1-"$2")
  if [ "${#_clean}" -gt "${#_capped}" ]; then
    printf '%s[truncated]' "$_capped"
  else
    printf '%s' "$_capped"
  fi
}

# Armed before the debug-level gate and preflight, so PID 1 can latch a stop
# before start_radvd decides whether a child may start.
radvd_pid=""
reload=0
shutdown=0
# Set when a TERM to the child was refused, so the shutdown arm cannot claim a
# graceful stop it never observed. Scoped to one child: start_radvd clears it.
signal_failed=0
# Set by every trap handler so the loop can tell a trap-interrupted wait from a real
# radvd exit. A status above 128 cannot: a HUP or TERM interrupting the wait returns
# 129 or 143 with the child alive, and a SIGKILLed radvd exits 137.
sig_seen=0
hup_pending=0
term_pending=0

on_hup() {
  sig_seen=1
  hup_pending=1
  # The arrival is logged HERE because a HUP consumed between the drain and `wait`
  # is never serviced, and without this line that case is indistinguishable from a
  # signal that never reached PID 1. Every disposition below prints its own line.
  printf 'level=info msg="SIGHUP received; queued for reload"\n' >&2
}

# The delivery happens here rather than at a drain point a signal arriving just
# before `wait` would miss: radvd's own exit is then what makes `wait` return.
# Only the kill moves -- once any trapped signal nests, a FORKING command inside a
# handler reports 128+signo of the handler's OWN signal instead of the command's
# status, so the reload's bounded check stays in the drained loop.
on_term() {
  sig_seen=1
  if [ "$shutdown" -eq 1 ]; then
    return
  fi
  shutdown=1
  printf 'level=info msg="shutdown signal received; stopping radvd"\n' >&2
  if [ -z "$radvd_pid" ]; then
    term_pending=1
  elif ! kill -TERM "$radvd_pid" 2>/dev/null; then
    # A reaped child has no /proc entry; a live child PID 1 may not signal does. Only the
    # second is a delivery failure -- the first is a stop that is already complete, and the
    # loop's disposition arm reports it.
    if [ -e "/proc/$radvd_pid" ]; then
      printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL" pid="%s"\n' "$radvd_pid" >&2
      printf 'level=warn msg="the TERM could not be delivered to radvd; a graceful stop cannot be confirmed"\n' >&2
      exit 0
    fi
  fi
}

request_reload() {
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="SIGHUP received during shutdown; reload ignored"\n' >&2
    return
  fi
  # Reject bad replacement configs before stopping the last good daemon.
  if ! [ -f "$CONF" ]; then
    printf 'level=error msg="SIGHUP reload refused: radvd.conf is absent or not a regular file" path="%s"\n' "$CONF" >&2
    return
  fi
  hup_rc=0
  hup_ct=$({ timeout 5 radvd --configtest --config="$CONF" --username=radvd 2>&1; } 2>/dev/null) || hup_rc=$?
  # A TERM latched during the bounded check wins over the reload it interrupted,
  # whatever the check returned. The check itself stays out of the trap handlers: once
  # any trapped signal nests, a forking command inside one reports 128+signo of the
  # handler's own signal (ash/dash) -- 129 in on_hup, which the classifier below reads
  # as a verdict rather than a timeout -- which is why only the shutdown kill lives in
  # on_term.
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="SIGHUP received during shutdown; reload ignored"\n' >&2
    return
  fi
  if [ "$hup_rc" -ne 0 ]; then
    # Neither timeout call site passes -k, so an elapsed budget is 124 (GNU) or
    # 143 (BusyBox, the shipped one) and 137 is unreachable at both.
    if [ "$hup_rc" -eq 124 ] || [ "$hup_rc" -eq 143 ]; then
      printf 'level=error msg="SIGHUP reload refused: the config check did not finish within 5s" path="%s"\n' "$CONF" >&2
    else
      printf 'level=error msg="SIGHUP reload refused: radvd rejected the mounted config" path="%s"\n' "$CONF" >&2
      # radvd's own text, verbatim and unstructured on purpose: README's
      # RadvdConfigError rule matches these bytes and scripts/smoke.sh asserts it.
      printf '%s\n' "$hup_ct" >&2
    fi
    return
  fi
  # `radvd -c` forces debuglevel 1 (radvd.c:289-290), which turns the conf_file
  # permission refusal into a warning it exits 0 on (radvd.c:319-325); the daemon at
  # debuglevel 0 exits 1 on the same file. At level 1 and above the daemon takes the
  # same warn arm, so refusing there would refuse a reload that would have worked.
  if [ "$RADVD_DEBUG_LEVEL" -eq 0 ] \
    && printf '%s\n' "$hup_ct" | grep -q 'Insecure file permissions'; then
    printf 'level=error msg="SIGHUP reload refused: radvd reports the config file permissions insecure and would exit at debug level 0" path="%s"\n' "$CONF" >&2
    printf '%s\n' "$hup_ct" >&2
    return
  fi
  # reload=1 promises the loop that an exit is coming, so only an observed
  # delivery may arm it.
  if [ -n "$radvd_pid" ] && kill -TERM "$radvd_pid" 2>/dev/null; then
    reload=1
    printf 'level=info msg="SIGHUP received; restarting radvd to reload config"\n' >&2
  else
    printf 'level=error msg="SIGHUP reload refused: TERM delivery to radvd could not be confirmed; radvd may not be running yet, the child may already have been reaped, or the container may lack CAP_KILL" pid="%s"\n' "$radvd_pid" >&2
  fi
}

request_shutdown() {
  if [ -n "$radvd_pid" ] && ! kill -TERM "$radvd_pid" 2>/dev/null && [ -e "/proc/$radvd_pid" ]; then
    signal_failed=1
    printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL" pid="%s"\n' "$radvd_pid" >&2
  fi
}

drain_signals() {
  while [ "$term_pending" -eq 1 ] || [ "$hup_pending" -eq 1 ]; do
    if [ "$term_pending" -eq 1 ]; then
      term_pending=0
      request_shutdown
    fi
    if [ "$hup_pending" -eq 1 ]; then
      hup_pending=0
      if [ "$shutdown" -eq 1 ]; then
        printf 'level=info msg="SIGHUP received during shutdown; reload ignored"\n' >&2
      elif [ "$reload" -eq 1 ]; then
        printf 'level=info msg="SIGHUP received while a reload is already in flight; the pending restart re-reads the config"\n' >&2
      else
        request_reload
      fi
    fi
  done
}

trap on_hup HUP
trap on_term TERM INT

# Resolve and validate before the supervisor loop can call request_reload or
# start_radvd; neither trap handler reads this value.
RADVD_DEBUG_LEVEL="${RADVD_DEBUG_LEVEL:-0}"
case "$RADVD_DEBUG_LEVEL" in
  [0-5]) ;;
  *)
    bad_level=$(sanitize_log_value "$RADVD_DEBUG_LEVEL" 32)
    printf 'level=error msg="invalid RADVD_DEBUG_LEVEL; expected an integer 0-5" value="%s"\n' "$bad_level" >&2
    exit 1
    ;;
esac

# Warn-only except the non-regular-node refusal below, which exits 1 from both call
# sites: radvd cannot consume a FIFO or a directory as its config file.
check_config_node() {
  # No POSIX-sh operation can type-check and open a node atomically, so the bounded
  # read is the backstop for the probe below: a FIFO with no writer blocks in
  # open/read, radvd's own open of the same node is unbounded, and a radvd blocked
  # there leaves a container the healthcheck calls healthy while it emits nothing.
  warn_unreadable_node() {
    node_err=$(sanitize_log_value "$1" 200)
    printf 'level=warn msg="radvd.conf could not be read; radvd may block or fail on the same node" err="%s" path="%s"\n' "$node_err" "$CONF" >&2
  }
  if [ -e "$CONF" ] && ! [ -f "$CONF" ]; then
    printf 'level=error msg="radvd.conf is not a regular file" path="%s"\n' "$CONF" >&2
    exit 1
  fi
  # 5s: above any legitimate read of this config, below `docker stop`'s 10s grace.
  # The substitution's subshell keeps 2>/dev/null off PID 1's own stderr; a bare
  # brace group would discard on_term's arrival record.
  read_rc=0
  _conf_probe=$({ timeout 5 cat "$CONF" >/dev/null; } 2>/dev/null) || read_rc=$?
  if [ "$read_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$read_rc" -eq 124 ] || [ "$read_rc" -eq 143 ]; then
    warn_unreadable_node "read of the config exceeded 5s; the node may be a FIFO or a stalled mount"
  else
    # Cause only, never content: cat writes its output before its error, so a merged
    # read would put config bytes in the field naming the cause. Bounded because this
    # arm also runs on the reload path, where an unbounded read wedges PID 1. The brace
    # groups catch ash's job-status word.
    read_cause=$({ timeout 5 cat "$CONF" 2>&1 >/dev/null; } 2>/dev/null)
    warn_unreadable_node "${read_cause:-the re-read reported no diagnostic either}"
  fi
}

if [ -r "$CONF" ]; then
  check_config_node
fi

# radvd refuses to start without the directory holding its --with-pidfile path.
if ! mkdir -p /run/radvd; then
  printf 'level=error msg="failed to create radvd PID directory; radvd cannot start" path="%s"\n' "/run/radvd" >&2
  exit 1
fi

start_radvd() {
  signal_failed=0
  # A shutdown latched while no radvd existed (preflight, or the reload gap
  # between reaping one generation and starting the next) is a stop that arrived
  # first. Starting radvd just to signal it races its own handler installation:
  # a lost race swallows the TERM and leaves PID 1 in `wait` until the stop
  # grace expires in SIGKILL — measured at 29-59% per hit under CPU contention.
  # The stop wins instead.
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="shutdown signal received before radvd started; exiting without starting it"\n' >&2
    exit 0
  fi
  if [ "$hup_pending" -eq 1 ]; then
    hup_pending=0
    printf 'level=info msg="SIGHUP received before radvd started; the daemon reads the config as it starts, so no reload is needed"\n' >&2
  fi
  printf 'level=info msg="starting radvd" config="%s" debug_level="%s"\n' "$CONF" "$RADVD_DEBUG_LEVEL" >&2
  radvd --config="$CONF" --nodaemon --logmethod=stderr --debug="$RADVD_DEBUG_LEVEL" --username=radvd &
  radvd_pid=$!
}

start_radvd

while :; do
  drain_signals
  # A shutdown latched before this loop whose TERM was refused has no exit still
  # coming: there is nothing to wait for, so fall through to the disposition below.
  if [ "$shutdown" -eq 1 ] && [ "$signal_failed" -eq 1 ]; then
    status=0
  else
    # ash writes a bare job-status word to fd2 for a child killed BY a signal (reachable
    # through the pre-pid latch); a per-command redirect never reaches the traps' own fd2.
    wait "$radvd_pid" 2>/dev/null
    wait_status=$?
    # 127 means an earlier wait already took radvd's status and request_reload's configtest
    # substitution has since evicted the job, so the status saved above stands.
    if [ "$wait_status" -ne 127 ]; then
      status="$wait_status"
    fi
    if [ "$sig_seen" -eq 1 ]; then
      sig_seen=0
      continue
    fi
  fi
  # Cleared before the next start: left set, request_shutdown can target a reaped child.
  # start_radvd's gate resolves a reload-gap TERM; exit has nothing to stop.
  radvd_pid=""

  if [ "$shutdown" -eq 1 ]; then
    # Exit 0 either way: an explicit `docker stop` must not read as a crash to a
    # restart policy, so the refused delivery is reported rather than propagated.
    if [ "$signal_failed" -eq 1 ]; then
      printf 'level=warn msg="the TERM could not be delivered to radvd; a graceful stop cannot be confirmed"\n' >&2
    else
      printf 'level=info msg="radvd stopped on shutdown signal (SIGTERM/SIGINT)"\n' >&2
    fi
    exit 0
  fi

  if [ "$reload" -eq 1 ]; then
    reload=0
    printf 'level=info msg="reloading radvd (config re-read via restart)"\n' >&2
    check_config_node
    start_radvd
    continue
  fi
  printf 'level=error msg="radvd exited; propagating exit for restart policy" status="%s"\n' "$status" >&2
  exit "$status"
done
