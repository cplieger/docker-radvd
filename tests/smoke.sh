#!/bin/sh
# Build-time smoke test for the pinned radvd build.
# Usage: sh tests/smoke.sh (radvd must be on PATH)
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail=0
log() { printf '%s\n' "$*"; }     # progress + final verdict -> stdout
err() { printf '%s\n' "$*" >&2; } # failures + captured output -> stderr

# 1. configtest accepts a valid config. This also proves the binary runs
#    and links (radvd's own version flag exits non-zero, so it is not a usable
#    liveness check).
if ! out=$(radvd --configtest --config="$d/radvd.conf" 2>&1); then
  err "FAIL: 'radvd --configtest' rejected a valid config"
  err "$out"
  fail=1
fi

# 2. configtest rejects a malformed config (proves the parser is real).
if bad_out=$(radvd --configtest --config="$d/radvd.bad.conf" 2>&1); then
  err "FAIL: 'radvd --configtest' accepted a malformed config"
  fail=1
fi

# Verify the README alert regex against radvd's actual rejection text.
RULE_SRC="$d/../README.md"
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

# Pin the upstream behavior consumed by request_reload's permission gate.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  insecure_conf=$(mktemp)
  cp "$d/radvd.conf" "$insecure_conf"
  chmod 0666 "$insecure_conf"
  insecure_rc=0
  insecure_out=$(radvd --configtest --config="$insecure_conf" --username=radvd 2>&1) || insecure_rc=$?
  rm -f "$insecure_conf"
  if [ "$insecure_rc" -ne 0 ]; then
    err "FAIL: pinned radvd no longer accepts an insecure config in configtest mode"
    err "$insecure_out"
    fail=1
  elif ! printf '%s\n' "$insecure_out" | grep -Fq 'Insecure file permissions'; then
    err "FAIL: pinned radvd configtest no longer emits the permission marker used by the reload gate"
    err "$insecure_out"
    fail=1
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
      check_config_node
    ' _ "$runtime_dir/fn-sanitize_log_value.sh" "$runtime_dir/fn-check_config_node.sh" "$runtime_dir/radvd.conf" 2>&1) || runtime_rc=$?
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

    printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$runtime_dir/bin/radvd"
    chmod +x "$runtime_dir/bin/radvd"
    hup_rc_probe=0
    # As above: the sh -c body's $1..$2 belong to that shell.
    # shellcheck disable=SC2016
    hup_out=$(PATH="$runtime_dir/bin:$PATH" /bin/busybox timeout 8 sh -c '
      set -u
      . "$1"
      CONF=$2
      RADVD_DEBUG_LEVEL=0
      radvd_pid=""
      reload=0
      shutdown=0
      signal_failed=0
      sig_seen=0
      request_reload
    ' _ "$runtime_dir/fn-request_reload.sh" "$runtime_dir/radvd.conf" 2>&1) || hup_rc_probe=$?
    if [ "$hup_rc_probe" -ne 0 ]; then
      err "FAIL: elapsed SIGHUP configtest probe did not return through its refusal (rc=$hup_rc_probe)"
      err "$hup_out"
      fail=1
    elif ! printf '%s\n' "$hup_out" | grep -Fq 'SIGHUP reload refused: the config check did not finish within 5s'; then
      err "FAIL: elapsed SIGHUP configtest emitted no structured refusal"
      err "$hup_out"
      fail=1
    elif printf '%s\n' "$hup_out" | grep -Eq '^(Terminated|Killed|Aborted)$'; then
      err "FAIL: BusyBox ash leaked an unstructured job-status line during SIGHUP configtest"
      err "$hup_out"
      fail=1
    fi
    rm -rf "$runtime_dir"
  fi
fi

# Preserve a reaped child's status when ash evicts the job-table entry.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  sentinel_dir=$(mktemp -d)
  sentinel="$sentinel_dir/wait-status-sentinel.sh"
  sed -n '/^    if \[ "\$wait_status" -ne 127 \]; then$/,/^    fi$/p' \
    /usr/local/bin/entrypoint.sh >"$sentinel"
  if [ ! -s "$sentinel" ]; then
    err "FAIL: could not extract the wait-status sentinel from the entrypoint"
    fail=1
  else
    sentinel_rc=0
    sentinel_out=$(/bin/busybox sh -c '
      set -u
      /bin/busybox sh -c "exit 3" &
      child=$!
      wait "$child"
      status=$?
      evicted=$(/bin/busybox true)
      wait "$child" 2>/dev/null
      wait_status=$?
      . "$1"
      printf "wait_status=%s status=%s\n" "$wait_status" "$status"
    ' _ "$sentinel") || sentinel_rc=$?
    if [ "$sentinel_rc" -ne 0 ] \
      || [ "$sentinel_out" != "wait_status=127 status=3" ]; then
      err "FAIL: wait-status sentinel did not preserve the reaped child status"
      err "${sentinel_out:-no output}"
      fail=1
    fi
  fi
  rm -rf "$sentinel_dir"
fi

# A failed first exec must remain a failure after the 127 job-table sentinel.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  exec_failure_rc=0
  exec_failure_out=$(PATH=/usr/local/bin:/usr/bin:/bin \
    /usr/local/bin/entrypoint.sh 2>&1) || exec_failure_rc=$?
  if [ "$exec_failure_rc" -ne 127 ]; then
    err "FAIL: an unresolvable radvd exited $exec_failure_rc, want 127"
    err "$exec_failure_out"
    fail=1
  elif ! printf '%s\n' "$exec_failure_out" \
    | grep -Fq 'msg="radvd exited; propagating exit for restart policy" status="127"'; then
    err "FAIL: an unresolvable radvd did not report propagated status 127"
    err "$exec_failure_out"
    fail=1
  fi
fi

# A failed read returns through the degraded warning inside the bound.
if [ -n "${RADVD_EXPECTED_VERSION:-}" ]; then
  failed_read_dir=$(mktemp -d)
  if ! extract_entrypoint_functions "$failed_read_dir"; then
    fail=1
  else
    # The lines below are the shim's source, so its diagnostic is written when
    # the shim runs rather than while it is being created.
    printf '%s\n' \
      '#!/bin/sh' \
      'printf "%s\n" "shimmed timeout failure" >&2' \
      'exit 2' >"$failed_read_dir/bin/timeout"
    chmod +x "$failed_read_dir/bin/timeout"
    printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$failed_read_dir/radvd.conf"
    failed_read_rc=0
    # As above: the sh -c body's $1..$3 belong to that shell.
    # shellcheck disable=SC2016
    failed_read_out=$(PATH="$failed_read_dir/bin:$PATH" \
      /bin/busybox timeout 8 sh -c '
        set -u
        . "$1"
        . "$2"
        CONF=$3
        check_config_node
      ' _ "$failed_read_dir/fn-sanitize_log_value.sh" "$failed_read_dir/fn-check_config_node.sh" "$failed_read_dir/radvd.conf" 2>&1) || failed_read_rc=$?
    if [ "$failed_read_rc" -ne 0 ]; then
      err "FAIL: failed config read did not return through its degraded warning (rc=$failed_read_rc)"
      err "$failed_read_out"
      fail=1
    elif ! printf '%s\n' "$failed_read_out" | grep -Fq 'radvd.conf could not be read'; then
      err "FAIL: failed config read emitted no unreadable-node warning"
      err "$failed_read_out"
      fail=1
    elif ! printf '%s\n' "$failed_read_out" | grep -Fq 'err="shimmed timeout failure"'; then
      err "FAIL: failed config read did not capture the read diagnostic"
      err "$failed_read_out"
      fail=1
    fi
    rm -rf "$failed_read_dir"
  fi
fi

[ "$fail" -eq 0 ] && log "radvd smoke: ok"
exit "$fail"
