#!/bin/sh
# Build-time smoke test for docker-radvd.
#
# Runs in the Dockerfile `test` stage, so the centralized `ci / validate`
# docker build-ability gate executes it on every PR and push (the final image
# stage depends on this stage's marker). Catches a broken radvd build and
# validates that radvd's config parser accepts a good config and rejects a
# malformed one — the real failure modes for a thin upstream-wrapper image.
#
# Run locally:  sh tests/smoke.sh   (needs the radvd binary on PATH)
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail=0
log() { printf '%s\n' "$*"; }     # progress + final verdict -> stdout
err() { printf '%s\n' "$*" >&2; } # failures + captured output -> stderr

# 1. configtest (-c) accepts a valid config. This also proves the binary runs
#    and links (radvd's own version flag exits non-zero, so it is not a usable
#    liveness check).
if ! out=$(radvd -c -C "$d/radvd.conf" 2>&1); then
  err "FAIL: 'radvd -c' rejected a valid config"
  err "$out"
  fail=1
fi

# 2. configtest (-c) rejects a malformed config (proves the parser is real).
if radvd -c -C "$d/radvd.bad.conf" >/dev/null 2>&1; then
  err "FAIL: 'radvd -c' accepted a malformed config"
  fail=1
fi

# 3. Version assertion: the built binary reports exactly the pinned upstream
#    version. Only runs when RADVD_EXPECTED_VERSION is set (the Dockerfile
#    test stage passes it from ARG RADVD_VERSION); a plain local run skips it.
#    radvd's version flag prints to stderr and exits non-zero by design, so
#    only the output is asserted.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  ver_out=$(radvd --version 2>&1) || true
  case "$ver_out" in
    *"Version: $RADVD_EXPECTED_VERSION"*) ;;
    *)
      err "FAIL: 'radvd --version' does not report expected version $RADVD_EXPECTED_VERSION"
      err "$ver_out"
      fail=1
      ;;
  esac
fi

[ "$fail" -eq 0 ] && log "radvd smoke: ok"
exit "$fail"
