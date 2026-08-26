#!/bin/sh
# radvd entrypoint. Supervises radvd rather than exec'ing it: SIGHUP becomes a
# restart that re-reads the config as root, and an unexpected radvd exit
# propagates to Docker's restart policy.
# Why that matters, and why not `exec radvd`: CONTRIBUTING.md, "Design
# boundaries (please preserve)".
set -u

CONF="/etc/radvd/radvd.conf"

# Arm the signal handlers before any preflight work so a HUP/TERM landing
# during validation is latched instead of lost (as PID 1, default-disposition
# signals from the host are not delivered): a TERM here still exits 0
# gracefully and a HUP still triggers one clean restart cycle, via the pre-pid
# latch in start_radvd.
radvd_pid=""
reload=0
shutdown=0
# Set when a TERM to the child was refused, so the shutdown arm cannot report a
# graceful stop it never observed. Scoped to one child: start_radvd clears it.
signal_failed=0
# SIGHUP: reload config by restarting radvd (re-reads as root, see header).
on_hup() {
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="SIGHUP received during shutdown; reload ignored"\n' >&2
    return
  fi
  reload=1
  printf 'level=info msg="SIGHUP received; restarting radvd to reload config"\n' >&2
  if [ -n "$radvd_pid" ] && ! kill -TERM "$radvd_pid" 2>/dev/null; then
    signal_failed=1
    printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&2
  fi
}
# SIGTERM/SIGINT (docker stop): forward and exit.
on_term() {
  shutdown=1
  printf 'level=info msg="shutdown signal received; stopping radvd"\n' >&2
  if [ -n "$radvd_pid" ] && ! kill -TERM "$radvd_pid" 2>/dev/null; then
    signal_failed=1
    printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&2
  fi
}
trap on_hup HUP
trap on_term TERM INT

# Both tr stages replace 1:1 rather than delete: deletion shifts offsets and
# can splice two fragments into one token of the bad= list. The explicit
# \040-\176 range stands in for [:print:], which BusyBox tr (v1.37.0) does
# not implement, and LC_ALL=C makes what it covers a property of the code and
# not of the container's locale — closing the C1 (U+0080-U+009F),
# Bidi_Control and U+2028/U+2029 classes a [:cntrl:] pass cannot see, at the
# cost of flattening legitimate non-ASCII too. Every surviving byte is then
# single-byte printable ASCII, so the cap cannot split a rune, and
# [truncated] marks a cut value so it cannot be read as a complete one.
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

# radvd's own -d verbosity, per-level detail in the README's configuration
# reference. Fail-closed: a typo'd level is an operator error better caught at
# startup than silently run at an unintended verbosity.
RADVD_DEBUG_LEVEL="${RADVD_DEBUG_LEVEL:-0}"
case "$RADVD_DEBUG_LEVEL" in
  [0-5]) ;;
  *)
    bad_level=$(sanitize_log_value "$RADVD_DEBUG_LEVEL" 32)
    printf 'level=error msg="invalid RADVD_DEBUG_LEVEL; expected an integer 0-5" value="%s"\n' "$bad_level" >&2
    exit 1
    ;;
esac

# Warn-only on every call except the non-regular-node refusal below, which exits
# 1 from BOTH call sites (startup triage and the SIGHUP reload) — a single-node
# operator legitimately deploys without HA, and the SIGHUP branch re-emits these
# warnings for a config edited since startup. Why HA needs these directives, and
# the accepted spellings with the reason for each: CONTRIBUTING.md, "Design
# boundaries (please preserve)".
check_ha_directives() {
  # A FIFO with no writer blocks in open/read and a device node may return EOF
  # immediately (/dev/null does): neither gives the bounded regular-file snapshot
  # this scan needs, and radvd's own open of the same node blocks the same way —
  # leaving no RAs while `pidof radvd` keeps the healthcheck green — so the probe
  # refuses rather than skipping the read. It excludes only the node it can see;
  # the bounded read below covers one substituted after it returns, since no
  # POSIX-sh operation can check the type and open the same node atomically. One
  # read for the whole scan, so the gates and the block scanner cannot see
  # different bytes of a config edited between them.
  warn_scan_degraded() {
    scan_err=$(sanitize_log_value "$1" 200)
    printf 'level=warn msg="unable to scan mounted radvd config; HA-directive validation is incomplete" err="%s" path="%s"\n' "$scan_err" "$CONF" >&2
  }
  if [ -e "$CONF" ] && ! [ -f "$CONF" ]; then
    printf 'level=error msg="radvd.conf is not a regular file" path="%s"\n' "$CONF" >&2
    exit 1
  fi
  # 5s is far above any legitimate read of a kilobyte config and far below
  # `docker stop`'s 10s grace, so a stop during a wedged read still exits cleanly.
  conf_snapshot=$(timeout 5 cat "$CONF" 2>/dev/null)
  read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    if [ "$read_rc" -eq 124 ]; then
      warn_scan_degraded "read of the config exceeded 5s; the node may be a FIFO or a stalled mount"
    else
      # Content and cause must not share a stream: cat writes its output before
      # its error, so a merged read puts config bytes in the field that names
      # the cause. The re-read runs only here, after the scan is abandoned, so
      # no gate sees two versions of the file — and it can SUCCEED, because a
      # short read that completes on retry emits no diagnostic at all, so the
      # field falls back to a phrase rather than shipping an empty cause.
      scan_cause=$(cat "$CONF" 2>&1 >/dev/null)
      warn_scan_degraded "${scan_cause:-re-read of the config succeeded; the first read failed without a diagnostic}"
    fi
    return 0
  fi
  has_directive() {
    printf '%s\n' "$conf_snapshot" | sed 's/#.*//' | tr '\n' ' ' | grep -Eqi "$1"
  }
  # radvd's grammar has no empty production (v2.21 gram.y, `grammar : grammar
  # ifacedef | ifacedef`), so a config with no interface definition fails
  # yyparse and radvd exits with `exiting, failed to read config file`. Gated
  # on the keyword rather than on emptiness: whitespace, comments and
  # top-level-only directives are all non-empty on disk and configure nothing.
  has_directive '(^|[;{}])[[:space:]]*interface[[:space:]]' \
    || printf 'level=warn msg="radvd.conf defines no interface; radvd will exit because at least one interface block is required" path="%s"\n' "$CONF" >&2
  has_directive '(^|[;{}])[[:space:]]*IgnoreIfMissing[[:space:]]+on([[:space:]]|;|$)' \
    || printf 'level=warn msg="no enabled IgnoreIfMissing on directive found in mounted radvd config" path="%s"\n' "$CONF" >&2
  # Warn-only, and the scan walks every block rather than stopping at the first
  # link-local address, so a correct block cannot mask a sibling holding the
  # global-VIP mistake. The rule itself is in the warning this branch prints.
  if has_directive '(^|[;{}])[[:space:]]*AdvRASrcAddress([[:space:]]|\{|$)'; then
    bad_src=$(printf '%s\n' "$conf_snapshot" | awk '
      # Strip CR so the trailing \r of a CRLF config is not parsed as an
      # address token (the sed|grep gates already tolerate CRLF via
      # [[:space:]]).
      { sub(/#.*/, ""); gsub(/\r/, ""); line = tolower($0) }
      {
        rest = line
        for (;;) {
          if (!inblock) {
            if (rest !~ /^[ \t]*advrasrcaddress([ \t]|[{]|$)/) {
              if (!match(rest, /[;{}][ \t]*advrasrcaddress([ \t]|[{]|$)/)) { break }
              rest = substr(rest, RSTART + 1)
            }
            inblock = 1
          }
          work = rest
          sub(/^[ \t]*advrasrcaddress[ \t]*/, "", work)
          # Stop scanning at the block close so a trailing same-line
          # directive (e.g. `}; MinRtrAdvInterval 30;`) is not parsed
          # as an address; the remainder is then re-scanned so a sibling
          # AdvRASrcAddress block opening on the same line is still
          # validated (the comment above promises a correct block never
          # masks a sibling holding the global-VIP mistake).
          closed = (work ~ /[}]/)
          if (closed) { sub(/[}].*/, "", work) }
          gsub(/[{}]/, " ", work)
          n = split(work, addrs, ";")
          for (i = 1; i <= n; i++) {
            tok = addrs[i]
            sub(/^[ \t]+/, "", tok)
            sub(/[ \t]+$/, "", tok)
            if (tok != "" && tok !~ /^fe[89ab][0-9a-f]:/) { bad = bad (bad ? ", " : "") tok }
          }
          if (!closed) { break }
          inblock = 0
          sub(/^[^}]*[}][ \t]*;?/, "", rest)
        }
      }
      END { if (bad != "") print bad }
    ')
    if [ -n "$bad_src" ]; then
      bad_src=$(sanitize_log_value "$bad_src" 200)
      printf 'level=warn msg="AdvRASrcAddress is set to a non-link-local address; RFC 4861 requires an RA source to be link-local (fe80::/10), so hosts will silently discard these RAs" bad="%s" path="%s"\n' "$bad_src" "$CONF" >&2
    fi
  else
    printf 'level=warn msg="no AdvRASrcAddress directive found in mounted radvd config (HA failover will not work correctly)" path="%s"\n' "$CONF" >&2
  fi
}

if [ -r "$CONF" ]; then
  check_ha_directives
elif [ -e "$CONF" ]; then
  printf 'level=error msg="radvd.conf exists but is not readable" path="%s"\n' "$CONF" >&2
  exit 1
else
  printf 'level=warn msg="radvd.conf not found; radvd will fail to start" path="%s"\n' "$CONF" >&2
fi

# radvd writes its own PID file at /run/radvd/radvd.pid and refuses to start
# if the directory is missing.
if ! mkdir -p /run/radvd; then
  printf 'level=error msg="failed to create radvd PID directory; radvd cannot start" path="%s"\n' "/run/radvd" >&2
  exit 1
fi

# -n foreground, -m stderr routes upstream logs to our stderr, -d sets radvd's
# verbosity from RADVD_DEBUG_LEVEL (validated above; radvd's startup banner and
# all warnings/errors log even at 0), -u radvd drops privileges after the raw
# socket is open. Missing config is caught by radvd itself with a clear error
# message.
start_radvd() {
  # Cleared per child: the flag means "the TERM to THIS pid was refused", and
  # start_radvd is the one place the child's identity changes.
  signal_failed=0
  radvd -C "$CONF" -n -m stderr -d "$RADVD_DEBUG_LEVEL" -u radvd &
  radvd_pid=$!
  # A signal delivered before radvd_pid was assigned set the flag but skipped
  # the kill; deliver it now so an early stop/reload is not swallowed. Runs on
  # every start (initial and reload restart) so a HUP/TERM latched during the
  # pre-pid window is always propagated to the freshly assigned child.
  if [ "$shutdown" -eq 1 ] || [ "$reload" -eq 1 ]; then
    if ! kill -TERM "$radvd_pid" 2>/dev/null; then
      signal_failed=1
      printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&2
    fi
  fi
}

printf 'level=info msg="starting radvd" config="%s" debug_level="%s"\n' "$CONF" "$RADVD_DEBUG_LEVEL" >&2
start_radvd

while :; do
  wait "$radvd_pid"
  status=$?
  # A trapped signal interrupts wait before radvd has finished terminating;
  # keep reaping until the child is fully gone so the next start does not race
  # a dying process, preserving the latest exit status from each completed wait.
  while kill -0 "$radvd_pid" 2>/dev/null; do
    wait "$radvd_pid"
    status=$?
  done

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
    # Re-emit the HA-directive warnings for the (possibly edited) mounted config
    # before restarting, matching what startup already checked.
    check_ha_directives
    start_radvd
    continue
  fi
  # radvd exited on its own (crash or fatal config error): propagate the code
  # so Docker's restart policy recreates the container.
  printf 'level=error msg="radvd exited; propagating exit for restart policy" status="%s"\n' "$status" >&2
  exit "$status"
done
