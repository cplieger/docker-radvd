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
if bad_out=$(radvd -c -C "$d/radvd.bad.conf" 2>&1); then
  err "FAIL: 'radvd -c' accepted a malformed config"
  fail=1
fi

# The README's RadvdConfigError rule matches radvd's OWN fatal strings, which are
# fixed by the pinned version and bumped by Renovate, so read both sides: pull the
# rule's own |~ pattern out of the README and match radvd's actual reply against it
# as the regex Loki will use. The extraction is the same expression the shell unit
# tests use on the entrypoint's half of the same contract. One repository-relative
# path finds the README in both places this script runs: the repo root in a
# checkout, and /tmp in the image, where the test stage copies it one level above
# tests/.
RULE_SRC="$d/../README.md"
# Forced in-image the way sections 3 and 4 are: a plain local run may skip this,
# the Dockerfile test stage may not — silently losing the drift gate is worse than
# a red build.
if [ -r "$RULE_SRC" ] || [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  # The sed script matches the README's literal `|~ `pattern` [10m]` line, backticks
  # included, so the single quotes are required: nothing here may expand.
  # shellcheck disable=SC2016
  rule=$(sed -n '/alert: RadvdConfigError/,/^        for:/p' "$RULE_SRC" \
    | sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\]$/\1/p')
  if [ -z "$rule" ]; then
    err "FAIL: could not extract the RadvdConfigError pattern from $RULE_SRC"
    fail=1
  elif ! printf '%s\n' "$bad_out" | grep -Eq "$rule"; then
    err "FAIL: radvd's config-rejection output does not match the README's RadvdConfigError pattern"
    err "$bad_out"
    fail=1
  fi
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
#    component, and — in-image, where RADVD_EXPECTED_VERSION is guaranteed by
#    the Dockerfile — carry exactly the pinned version (proves the ARG wiring
#    into the fragment). BusyBox has no jq, so assert shape with
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
    if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
      grep -Fq "\"version\": \"${RADVD_EXPECTED_VERSION#v}\"" "$SBOM" || {
        err "FAIL: embedded SBOM fragment does not carry pinned version ${RADVD_EXPECTED_VERSION#v}"
        fail=1
      }
    fi
  fi
fi

# 5. Both sbin binaries ship: the README's HA and Healthcheck sections tell the
#    operator to run radvdump. Forced in-image the way sections 3 and 4 are.
if [ -e /usr/sbin/radvdump ] || [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  [ -x /usr/sbin/radvdump ] || {
    err "FAIL: radvdump is not executable at /usr/sbin/radvdump"
    fail=1
  }
fi

# The host-side shell suite cannot reproduce ash's job-status output. In the
# image, expire the real production timeout and reject any bare shell record.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  runtime_dir=$(mktemp -d)
  entrypoint=/usr/local/bin/entrypoint.sh
  if [ "$(grep -c '^sanitize_log_value() {$' "$entrypoint")" -ne 1 ] \
    || [ "$(grep -c '^check_ha_directives() {$' "$entrypoint")" -ne 1 ]; then
    err "FAIL: entrypoint function extraction anchors are not unique"
    fail=1
  else
    sed -n '/^sanitize_log_value() {$/,/^}$/p' "$entrypoint" >"$runtime_dir/sanitize.sh"
    sed -n '/^check_ha_directives() {$/,/^}$/p' "$entrypoint" >"$runtime_dir/check.sh"
    mkdir "$runtime_dir/bin"
    printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$runtime_dir/bin/cat"
    chmod +x "$runtime_dir/bin/cat"
    printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$runtime_dir/radvd.conf"
    runtime_rc=0
    runtime_out=$(PATH="$runtime_dir/bin:$PATH" /bin/busybox timeout 8 sh -c '
      set -u
      . "$1"
      . "$2"
      CONF=$3
      check_ha_directives
    ' _ "$runtime_dir/sanitize.sh" "$runtime_dir/check.sh" "$runtime_dir/radvd.conf" 2>&1) || runtime_rc=$?
    if [ "$runtime_rc" -ne 0 ]; then
      err "FAIL: elapsed config-read probe did not return through the degraded warning (rc=$runtime_rc)"
      err "$runtime_out"
      fail=1
    elif ! printf '%s\n' "$runtime_out" | grep -Fq 'read of the config exceeded 5s'; then
      err "FAIL: BusyBox timeout expiry was not classified as the exceeded-budget condition"
      err "$runtime_out"
      fail=1
    elif printf '%s\n' "$runtime_out" | grep -Eq '^(Terminated|Killed)$'; then
      err "FAIL: BusyBox ash leaked an unstructured job-status line during the bounded read"
      err "$runtime_out"
      fail=1
    fi
    rm -rf "$runtime_dir"
  fi
fi

# A prompt first-read failure enters the diagnostic reread. Make that reread
# block and require the production bound to return through one warning.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  reread_dir=$(mktemp -d)
  entrypoint=/usr/local/bin/entrypoint.sh
  if [ "$(grep -c '^sanitize_log_value() {$' "$entrypoint")" -ne 1 ] \
    || [ "$(grep -c '^check_ha_directives() {$' "$entrypoint")" -ne 1 ]; then
    err "FAIL: entrypoint function extraction anchors are not unique"
    fail=1
  else
    sed -n '/^sanitize_log_value() {$/,/^}$/p' "$entrypoint" >"$reread_dir/sanitize.sh"
    sed -n '/^check_ha_directives() {$/,/^}$/p' "$entrypoint" >"$reread_dir/check.sh"
    mkdir "$reread_dir/bin"
    printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$reread_dir/bin/cat"
    printf '%s\n' \
      '#!/bin/sh' \
      ': "${TIMEOUT_COUNT:?}"' \
      'n=0' \
      '[ ! -r "$TIMEOUT_COUNT" ] || n=$(/bin/busybox cat "$TIMEOUT_COUNT")' \
      'n=$((n + 1))' \
      'printf "%s\\n" "$n" >"$TIMEOUT_COUNT"' \
      '[ "$n" -ne 1 ] || exit 2' \
      'exec /bin/busybox timeout "$@"' >"$reread_dir/bin/timeout"
    chmod +x "$reread_dir/bin/cat" "$reread_dir/bin/timeout"
    printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$reread_dir/radvd.conf"
    reread_rc=0
    reread_out=$(TIMEOUT_COUNT="$reread_dir/timeout-count" PATH="$reread_dir/bin:$PATH" \
      /bin/busybox timeout 8 sh -c '
        set -u
        . "$1"
        . "$2"
        CONF=$3
        check_ha_directives
      ' _ "$reread_dir/sanitize.sh" "$reread_dir/check.sh" "$reread_dir/radvd.conf" 2>&1) || reread_rc=$?
    if [ "$reread_rc" -ne 0 ]; then
      err "FAIL: diagnostic config reread exceeded its production bound (rc=$reread_rc)"
      err "$reread_out"
      fail=1
    elif ! printf '%s\n' "$reread_out" | grep -Fq 'unable to scan mounted radvd config'; then
      err "FAIL: bounded diagnostic reread emitted no degraded-scan warning"
      err "$reread_out"
      fail=1
    fi
    rm -rf "$reread_dir"
  fi
fi

[ "$fail" -eq 0 ] && log "radvd smoke: ok"
exit "$fail"
