#!/usr/bin/env bash
# Runs every entrypoint.sh unit test in this directory. The filename is the
# contract: cplieger/ci's shell-ci.yaml runs this path when it exists and skips
# otherwise, so committing the file is how a repo opts in — keep the name.
#
# Scope (repo-owned, per lib.sh): this suite owns entrypoint.sh's validator arms
# and pre-pid signal latch — warn-only diagnostics a healthy container never
# shows, plus one refusal (a config node radvd itself cannot open); tests/smoke.sh
# owns the radvd binary and scripts/smoke.sh the supervisor's signal contract.
set -u

cd -- "$(dirname -- "$0")" || exit 1

failed=0
ran=0
# Each *_test.sh is a separate process, so one test's stubs, traps and shell
# options cannot leak into another's, and all of them run even when one fails.
for t in ./*_test.sh; do
  # A glob that matches nothing expands to itself; treat that as a harness fault
  # rather than a green run, since an empty suite passing silently is how a
  # test directory quietly stops testing anything.
  if [ ! -f "$t" ]; then
    printf 'harness error: no *_test.sh found in %s\n' "$PWD" >&2
    exit 1
  fi
  printf '=== %s\n' "$(basename "$t")"
  ran=$((ran + 1))
  bash "$t" || failed=$((failed + 1))
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf 'FAILED: %d of %d entrypoint test files failed\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d entrypoint test files passed\n' "$ran"
