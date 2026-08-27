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

# 6. The pinned radvd's own default for the directive the entrypoint's config scan
#    reasons about. A check that warns about a directive's ABSENCE is only correct
#    while upstream's default for it is the unwanted value, and RADVD_VERSION is
#    Renovate-bumped with the SHA recomputed in the same commit, so a default can
#    move with nobody reading upstream's CHANGES. Read from the header the image
#    actually built (copied out of the builder stage) rather than from a constant
#    restated here, the way sections 3 and 4 read the version. A macro that has
#    been renamed or retired fails here too, which is the right outcome: it means
#    upstream moved and the check needs re-reading.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  DEFAULTS=/tmp/radvd-defaults.h
  if [ ! -s "$DEFAULTS" ]; then
    err "FAIL: the pinned radvd's defaults header did not ship into the test stage: $DEFAULTS"
    fail=1
  else
    macro=DFLT_AdvSendAdv
    want=0
    got=$(sed -n "s/^#define ${macro}[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p" "$DEFAULTS")
    if [ -z "$got" ]; then
      err "FAIL: $macro is not defined in the pinned radvd's defaults header; upstream renamed or retired it, so the entrypoint's check for that directive must be re-read against the new default"
      fail=1
    elif [ "$got" != "$want" ]; then
      err "FAIL: the pinned radvd defaults $macro to $got, not $want; the entrypoint's check for that directive was written against $want and must be re-read"
      fail=1
    fi
  fi
fi

# Both blocks below run an extracted entrypoint function against the image's own
# BusyBox userland, so both need every function the extraction depends on present
# and LOADABLE before their own oracle can mean anything. Enumerating the anchors
# rather than naming two supplies any sibling the validator gains; loading each
# extraction is what turns a truncated one (a column-0 closer inside a body, which
# still parses and still defines A function) into one honest refusal here instead
# of two oracles accusing something innocent.
extract_entrypoint_functions() {
  ep_dir=$1
  ep_src=/usr/local/bin/entrypoint.sh
  mkdir -p "$ep_dir/bin"
  ep_anchors=$(grep -o '^[a-z_][a-z_0-9]*() {$' "$ep_src" | sed 's/() {$//')
  if [ -z "$ep_anchors" ]; then
    err "FAIL: no top-level function anchors found in $ep_src"
    return 1
  fi
  for ep_fn in $ep_anchors; do
    if [ "$(grep -c "^$ep_fn() {\$" "$ep_src")" -ne 1 ]; then
      err "FAIL: the entrypoint anchor for $ep_fn() does not appear exactly once"
      return 1
    fi
    sed -n "/^$ep_fn() {\$/,/^}\$/p" "$ep_src" >"$ep_dir/fn-$ep_fn.sh"
    if ! sh -c '. "$1"; command -v "$2" >/dev/null 2>&1' _ "$ep_dir/fn-$ep_fn.sh" "$ep_fn"; then
      err "FAIL: the extraction of $ep_fn() does not define it (a column-0 closer inside its body truncates the range)"
      return 1
    fi
  done
  return 0
}

# The host-side shell suite cannot reproduce ash's job-status output. In the
# image, expire the real production timeout and reject any bare shell record.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  runtime_dir=$(mktemp -d)
  if ! extract_entrypoint_functions "$runtime_dir"; then
    fail=1
  else
    printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$runtime_dir/bin/cat"
    chmod +x "$runtime_dir/bin/cat"
    printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$runtime_dir/radvd.conf"
    runtime_rc=0
    # The sh -c body's $1..$3 are that shell's positional parameters, supplied
    # after the `_` below and expanded when it runs.
    # shellcheck disable=SC2016
    runtime_out=$(PATH="$runtime_dir/bin:$PATH" /bin/busybox timeout 8 sh -c '
      set -u
      . "$1"
      . "$2"
      CONF=$3
      check_config_directives
    ' _ "$runtime_dir/fn-sanitize_log_value.sh" "$runtime_dir/fn-check_config_directives.sh" "$runtime_dir/radvd.conf" 2>&1) || runtime_rc=$?
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
  if ! extract_entrypoint_functions "$reread_dir"; then
    fail=1
  else
    printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$reread_dir/bin/cat"
    # The lines below are the shim's SOURCE, so $TIMEOUT_COUNT, $n and $@ must
    # expand when the shim runs rather than while it is being written.
    # shellcheck disable=SC2016
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
    # As above: the sh -c body's $1..$3 belong to that shell.
    # shellcheck disable=SC2016
    reread_out=$(TIMEOUT_COUNT="$reread_dir/timeout-count" PATH="$reread_dir/bin:$PATH" \
      /bin/busybox timeout 8 sh -c '
        set -u
        . "$1"
        . "$2"
        CONF=$3
        check_config_directives
      ' _ "$reread_dir/fn-sanitize_log_value.sh" "$reread_dir/fn-check_config_directives.sh" "$reread_dir/radvd.conf" 2>&1) || reread_rc=$?
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
