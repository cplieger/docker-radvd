#!/bin/sh
# Build-time smoke test for docker-radvd.
#
# Runs in the Dockerfile `test` stage, so the centralized `ci / validate`
# docker build-ability gate executes it on every PR and push (the final image
# stage depends on this stage's marker). Catches a broken radvd build and
# validates that radvd's config parser accepts a good config and rejects a
# malformed one — the real failure modes for a thin upstream-wrapper image —
# and that the embedded SBOM fragment ships naming radvd at the pinned
# version.
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
#    version (RADVD_EXPECTED_VERSION, passed by the Dockerfile test stage from
#    ARG RADVD_VERSION; a leading "v" is stripped here). A plain local run
#    skips it; the Dockerfile guards the ARG with :? so the in-image gate can
#    never silently skip. radvd's version flag prints to stderr and exits
#    non-zero by design, so only the output is asserted. The version line is
#    compared EXACTLY (not as a substring): a prefix match would accept
#    2.21.1 or 2.210 for an expected 2.21, hiding a fetch/extract mixup.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  expected=${RADVD_EXPECTED_VERSION#v}
  ver_out=$(radvd --version 2>&1) || true
  ver_line=$(printf '%s\n' "$ver_out" | head -n 1)
  if [ "$ver_line" != "Version: $expected" ]; then
    err "FAIL: 'radvd --version' does not report exactly expected version $expected"
    err "$ver_line"
    fail=1
  fi
fi

# 4. Embedded SBOM fragment (Dockerfile builder stage): the CycloneDX file
#    covering the source-built radvd must ship in the image, name the radvd
#    component with a version-shaped string, and — in-image, where
#    RADVD_EXPECTED_VERSION is guaranteed by the Dockerfile — carry exactly
#    the pinned version (proves the ARG wiring into the fragment, not just
#    that some version is present). BusyBox has no jq, so assert shape with
#    grep: non-empty, starts with { and ends with }. Skipped like section 3
#    when the file is absent in a plain local run (needs the built image).
SBOM=/usr/share/sbom/radvd.cdx.json
if [ -e "$SBOM" ] || [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  if [ ! -s "$SBOM" ]; then
    err "FAIL: embedded SBOM fragment missing or empty: $SBOM"
    fail=1
  else
    if [ "$(head -c 1 "$SBOM")" != "{" ] || [ "$(tail -c 2 "$SBOM")" != "}" ]; then
      err "FAIL: embedded SBOM fragment is not a JSON object (bad first/last byte)"
      fail=1
    fi
    grep -q '"name": "radvd"' "$SBOM" || {
      err "FAIL: embedded SBOM fragment missing component: radvd"
      fail=1
    }
    grep -q '"version": "[0-9][0-9.]*"' "$SBOM" || {
      err "FAIL: embedded SBOM fragment has no version-shaped component version"
      fail=1
    }
    if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
      grep -q "\"version\": \"${RADVD_EXPECTED_VERSION#v}\"" "$SBOM" || {
        err "FAIL: embedded SBOM fragment does not carry pinned version ${RADVD_EXPECTED_VERSION#v}"
        fail=1
      }
    fi
  fi
fi

[ "$fail" -eq 0 ] && log "radvd smoke: ok"
exit "$fail"
