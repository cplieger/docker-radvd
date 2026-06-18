#!/bin/sh
# Build-time smoke test for docker-radvd.
#
# Runs in the Dockerfile `test` stage, so the centralized `ci / validate`
# docker build-ability gate executes it on every PR and push (the final image
# stage depends on this stage's marker). Catches a broken radvd package and
# validates that radvd's config parser accepts a good config and rejects a
# malformed one — the real failure modes for a thin upstream-wrapper image.
#
# Run locally:  sh tests/smoke.sh   (needs the radvd binary on PATH)
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail=0
log() { printf '%s\n' "$*"; }

# 1. configtest (-c) accepts a valid config. This also proves the binary runs
#    and links (radvd's own version flag exits non-zero, so it is not a usable
#    liveness check).
if ! radvd -c -C "$d/radvd.conf" > /dev/null 2>&1; then
  log "FAIL: 'radvd -c' rejected a valid config"
  fail=1
fi

# 2. configtest (-c) rejects a malformed config (proves the parser is real).
if radvd -c -C "$d/radvd.bad.conf" > /dev/null 2>&1; then
  log "FAIL: 'radvd -c' accepted a malformed config"
  fail=1
fi

[ "$fail" -eq 0 ] && log "radvd smoke: ok"
exit "$fail"
