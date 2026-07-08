#!/bin/sh
# radvd entrypoint. Supervises radvd so a SIGHUP is a reliable config reload
# and an unexpected radvd exit propagates to Docker's restart policy.
#
# Why supervise instead of `exec radvd`: radvd reads its config as root at
# startup (before dropping to -u radvd), but re-reads it as the unprivileged
# radvd user on SIGHUP. If the mounted config is not readable by that user
# (e.g. a 0770 root:<group> bind mount, common in hardened deployments), the
# in-process reread fails with "failed to read config file" and radvd exits.
# Worse, when that SIGHUP was delivered via `docker kill -s HUP`, Docker's
# restart policy does not fire, so the daemon stays down. Turning SIGHUP into a
# supervised restart re-reads the config as root every time, so reload works
# regardless of the config's ownership while radvd itself keeps running -u.
#
# Paired with a keepalived sibling container that manages a floating link-local
# address. radvd on both nodes references it via AdvRASrcAddress in radvd.conf,
# so only the MASTER emits RAs; IgnoreIfMissing on tolerates it being absent on
# the BACKUP. See radvd.conf(5) and
# https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/
set -u

CONF="/etc/radvd/radvd.conf"

# Sanity-check the HA directives. radvd would happily start without them and
# emit RAs from both MASTER and BACKUP simultaneously, wrecking SLAAC default-
# route selection on downstream clients. Warn-only — a single-node operator
# may legitimately deploy without HA.
#
# Patterns are anchored to the start of a line (allowing leading whitespace)
# so commented-out directives (`# IgnoreIfMissing on`) correctly fail the
# check. The IgnoreIfMissing check also requires the value `on`, rejecting
# `IgnoreIfMissing off` which would otherwise pass a substring match.
if [ -r "$CONF" ]; then
  [ -s "$CONF" ] \
    || printf 'level=warn msg="radvd.conf is empty; radvd will exit because no interface is configured" path="%s"\n' "$CONF" >&2
  CONF_DIR=$(dirname "$CONF")
  grep -Eq '^[[:space:]]*IgnoreIfMissing[[:space:]]+on([[:space:]]|;|$)' "$CONF_DIR"/*.conf 2>/dev/null \
    || printf 'level=warn msg="no enabled IgnoreIfMissing on directive found in mounted radvd config" path="%s"\n' "$CONF_DIR" >&2
  grep -Eq '^[[:space:]]*AdvRASrcAddress([[:space:]]|\{|$)' "$CONF_DIR"/*.conf 2>/dev/null \
    || printf 'level=warn msg="no AdvRASrcAddress directive found in mounted radvd config (HA failover will not work correctly)" path="%s"\n' "$CONF_DIR" >&2
  # When AdvRASrcAddress IS set, its value must be a link-local address. RFC
  # 4861 section 6.1.2 requires a Router Advertisement's source to be link-local
  # (fe80::/10); hosts silently discard an RA sourced from a global or ULA
  # address. Pointing AdvRASrcAddress at a global service VIP is the classic
  # mistake: radvd emits and tcpdump shows the RAs, yet no host autoconfigures.
  # Warn-only, and only when the directive is present (its absence is covered
  # above). The scan reads each AdvRASrcAddress { ... } block and stays silent
  # if any address is fe80:-prefixed (case-insensitive); otherwise it warns.
  if grep -Eq '^[[:space:]]*AdvRASrcAddress([[:space:]]|\{|$)' "$CONF_DIR"/*.conf 2>/dev/null; then
    awk '
      { sub(/#.*/, ""); line = tolower($0) }
      FNR == 1 { inblock = 0 }
      line ~ /^[ \t]*advrasrcaddress([ \t]|[{]|$)/ { inblock = 1 }
      inblock {
        if ((" " line) ~ /[ \t{;]fe80:/) {
          found = 1
          exit
        }
        if (line ~ /[}]/) { inblock = 0 }
      }
      END { exit(found ? 0 : 1) }
    ' "$CONF_DIR"/*.conf 2>/dev/null \
      || printf 'level=warn msg="AdvRASrcAddress is set to a non-link-local address; RFC 4861 requires an RA source to be link-local (fe80::/10), so hosts will silently discard these RAs" path="%s"\n' "$CONF_DIR" >&2
  fi
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

# -n foreground, -m stderr routes upstream logs to our stderr, -d 1 is the
# minimal verbosity that still logs startup success, -u radvd drops privileges
# after the raw socket is open. Missing config is caught by radvd itself with a
# clear error message.
radvd_pid=""
start_radvd() {
  radvd -C "$CONF" -n -m stderr -d 1 -u radvd &
  radvd_pid=$!
  # A signal delivered before radvd_pid was assigned set the flag but skipped
  # the kill; deliver it now so an early stop/reload is not swallowed. Runs on
  # every start (initial and reload restart) so a HUP/TERM latched during the
  # pre-pid window is always propagated to the freshly assigned child.
  if [ "$shutdown" -eq 1 ] || [ "$reload" -eq 1 ]; then
    kill -TERM "$radvd_pid" 2>/dev/null
  fi
}

reload=0
shutdown=0
# SIGHUP: reload config by restarting radvd (re-reads as root, see header).
on_hup() {
  reload=1
  [ -n "$radvd_pid" ] && kill -TERM "$radvd_pid" 2>/dev/null
}
# SIGTERM/SIGINT (docker stop): forward and exit.
on_term() {
  shutdown=1
  [ -n "$radvd_pid" ] && kill -TERM "$radvd_pid" 2>/dev/null
}
trap on_hup HUP
trap on_term TERM INT

printf 'level=info msg="starting radvd" config="%s"\n' "$CONF" >&2
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
    printf 'level=info msg="radvd stopped on shutdown signal (SIGTERM/SIGINT)"\n' >&2
    exit 0
  fi
  if [ "$reload" -eq 1 ]; then
    reload=0
    printf 'level=info msg="reloading radvd (config re-read via restart)"\n' >&2
    start_radvd
    continue
  fi
  # radvd exited on its own (crash or fatal config error): propagate the code
  # so Docker's restart policy recreates the container.
  printf 'level=error msg="radvd exited; propagating exit for restart policy" status="%s"\n' "$status" >&2
  exit "$status"
done
