#!/bin/sh
# radvd entrypoint. Runs radvd in the foreground so Docker's restart policy
# supervises it. No wrapper-level crash loop handling, no watchdog.
#
# Paired with a keepalived sibling container that manages the IPv6 VIP. radvd
# on both nodes references the VIP via AdvRASrcAddress in radvd.conf, so only
# the MASTER node emits RAs; IgnoreIfMissing on tolerates the VIP being absent
# on the BACKUP node. See radvd.conf(5) and
# https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/
set -eu

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
  [ -s "$CONF" ] ||
    printf 'level=warn msg="radvd.conf is empty; radvd will exit because no interface is configured" path="%s"\n' "$CONF" >&2
  CONF_DIR=$(dirname "$CONF")
  grep -Eq '^[[:space:]]*IgnoreIfMissing[[:space:]]+on([[:space:]]|;|$)' "$CONF_DIR"/*.conf 2> /dev/null ||
    printf 'level=warn msg="no enabled IgnoreIfMissing on directive found in mounted radvd config" path="%s"\n' "$CONF_DIR" >&2
  grep -Eq '^[[:space:]]*AdvRASrcAddress([[:space:]]|\{)' "$CONF_DIR"/*.conf 2> /dev/null ||
    printf 'level=warn msg="no AdvRASrcAddress directive found in mounted radvd config (HA failover will not work correctly)" path="%s"\n' "$CONF_DIR" >&2
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

printf 'level=info msg="starting radvd" config="%s"\n' "$CONF" >&2

# exec so radvd becomes PID 1 and receives SIGTERM directly on docker stop.
# -n foreground, -m stderr routes upstream logs to our stderr, -d 1 is the
# minimal verbosity that still logs startup success. Missing config is
# caught by radvd itself with a clear error message.
exec radvd -C "$CONF" -n -m stderr -d 1 -u radvd
