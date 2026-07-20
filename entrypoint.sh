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

# Arm the signal handlers before any preflight work so a HUP/TERM landing
# during validation is latched instead of lost (as PID 1, default-disposition
# signals from the host are not delivered): a TERM here still exits 0
# gracefully and a HUP still triggers one clean restart cycle, via the pre-pid
# latch in start_radvd.
radvd_pid=""
reload=0
shutdown=0
# SIGHUP: reload config by restarting radvd (re-reads as root, see header).
on_hup() {
  reload=1
  printf 'level=info msg="SIGHUP received; restarting radvd to reload config"\n' >&2
  [ -n "$radvd_pid" ] && kill -TERM "$radvd_pid" 2>/dev/null
}
# SIGTERM/SIGINT (docker stop): forward and exit.
on_term() {
  shutdown=1
  printf 'level=info msg="shutdown signal received; stopping radvd"\n' >&2
  [ -n "$radvd_pid" ] && kill -TERM "$radvd_pid" 2>/dev/null
}
trap on_hup HUP
trap on_term TERM INT

# Sanity-check the HA directives. radvd would happily start without them and
# emit RAs from both MASTER and BACKUP simultaneously, wrecking SLAAC default-
# route selection on downstream clients. Warn-only — a single-node operator
# may legitimately deploy without HA.
#
# Directive-presence gates strip comments first (matching the awk scan's own
# `sub(/#.*/, "")`), so a commented-out `# IgnoreIfMissing on` still fails the
# check, while a directive may appear mid-line: radvd's grammar is whitespace-
# insensitive, so a one-line nested config like
# `interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };` is
# valid, and a statement boundary (start of line, `;`, `{` or `}`) must precede
# the directive name. The IgnoreIfMissing check also requires the value `on`,
# rejecting `IgnoreIfMissing off` which would otherwise pass a substring match.
# Gates match case-insensitively (grep -i): radvd's flex scanner is declared
# caseless, so `ignoreifmissing ON` is valid config, and the awk scan below
# already lowercases its input to match.
#
# Factored into a helper so the SIGHUP reload branch can re-emit the same
# warnings before restarting radvd: an operator who edits the mounted config
# and reloads via `docker kill -s HUP` would otherwise silently drop these HA
# directives with no warning. Warn-only on every call; the empty-config warning
# and the unreadable/missing-config paths below stay startup-only (the reload
# branch guards on readability and never triggers the fatal exit).
check_ha_directives() {
  CONF_DIR=$(dirname "$CONF")
  # Comment-stripped directive-presence grep across every *.conf (see the
  # gate rationale above check_ha_directives).
  has_directive() {
    sed 's/#.*//' "$CONF_DIR"/*.conf 2>/dev/null | grep -Eqi "$1"
  }
  has_directive '(^|[;{}])[[:space:]]*IgnoreIfMissing[[:space:]]+on([[:space:]]|;|$)' \
    || printf 'level=warn msg="no enabled IgnoreIfMissing on directive found in mounted radvd config" path="%s"\n' "$CONF_DIR" >&2
  # When AdvRASrcAddress IS set, every address it lists must be link-local. RFC
  # 4861 section 6.1.2 requires a Router Advertisement's source to be link-local
  # (fe80::/10); hosts silently discard an RA sourced from a global or ULA
  # address. Pointing AdvRASrcAddress at a global service VIP is the classic
  # mistake: radvd emits and tcpdump shows the RAs, yet no host autoconfigures.
  # Warn-only, and only when the directive is present (its absence is warned
  # about in the else branch below). The scan walks every
  # AdvRASrcAddress { ... } block across all *.conf
  # and warns if ANY listed address is non-link-local (case-insensitive), so a
  # correct link-local block never masks a sibling block that holds the
  # global-VIP mistake. The warning names each offending <file>:<address> so
  # the operator can fix a multi-*.conf config without re-grepping by hand; the
  # displayed file and address are sanitized (quotes and control characters
  # neutralized) so a malformed config value cannot forge or break the
  # structured key=value log line.
  if has_directive '(^|[;{}])[[:space:]]*AdvRASrcAddress([[:space:]]|\{|$)'; then
    bad_src=$(awk '
      function clean(s) {
        gsub(/["\\]/, "?", s)
        gsub(/[[:cntrl:]]/, "?", s)
        return s
      }
      # Strip CR so the trailing \r of a CRLF config is not parsed as an
      # address token (the sed|grep gates already tolerate CRLF via
      # [[:space:]]).
      { sub(/#.*/, ""); gsub(/\r/, ""); line = tolower($0) }
      FNR == 1 { inblock = 0 }
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
            if (tok != "" && tok !~ /^fe[89ab][0-9a-f]:/) { bad = bad (bad ? ", " : "") clean(FILENAME) ":" clean(tok) }
          }
          if (!closed) { break }
          inblock = 0
          sub(/^[^}]*[}][ \t]*;?/, "", rest)
        }
      }
      END { if (bad != "") print bad }
    ' "$CONF_DIR"/*.conf 2>/dev/null)
    if [ -n "$bad_src" ]; then
      printf 'level=warn msg="AdvRASrcAddress is set to a non-link-local address; RFC 4861 requires an RA source to be link-local (fe80::/10), so hosts will silently discard these RAs" bad="%s" path="%s"\n' "$bad_src" "$CONF_DIR" >&2
    fi
  else
    printf 'level=warn msg="no AdvRASrcAddress directive found in mounted radvd config (HA failover will not work correctly)" path="%s"\n' "$CONF_DIR" >&2
  fi
}

if [ -r "$CONF" ]; then
  [ -s "$CONF" ] \
    || printf 'level=warn msg="radvd.conf is empty; radvd will exit because no interface is configured" path="%s"\n' "$CONF" >&2
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

# -n foreground, -m stderr routes upstream logs to our stderr, -d 1 is the
# minimal verbosity that still logs startup success, -u radvd drops privileges
# after the raw socket is open. Missing config is caught by radvd itself with a
# clear error message.
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
    # Re-emit the HA-directive warnings for the (possibly edited) mounted config
    # before restarting, matching what startup already checked. Guarded on
    # readability so this stays warn-only — the unreadable-config fatal path is
    # startup-only by design.
    if [ -r "$CONF" ]; then
      check_ha_directives
    else
      printf 'level=warn msg="config not readable at reload; skipping HA-directive validation (radvd will report its own config error)" path="%s"\n' "$CONF" >&2
    fi
    start_radvd
    continue
  fi
  # radvd exited on its own (crash or fatal config error): propagate the code
  # so Docker's restart policy recreates the container.
  printf 'level=error msg="radvd exited; propagating exit for restart policy" status="%s"\n' "$status" >&2
  exit "$status"
done
