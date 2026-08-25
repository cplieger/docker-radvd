#!/usr/bin/env bash
# Runs every entrypoint.sh unit test in this directory.
#
# This filename is the contract: cplieger/ci's shell-ci.yaml runs
# `tests/shell/run.sh` when it exists, and skips otherwise, so a repo opts into
# shell unit testing by committing this file. Keep the name.
#
# The hook tests -f and invokes this through `bash`, so the exec bit is not
# load-bearing (it was committed 100644 once, which under an -x check would have
# skipped the whole suite silently and still reported CI green). The bit is set
# anyway, for anyone running it directly.
#
# WHAT THIS REPO'S SUITE COVERS. This file is repo-owned (lib.sh and
# harness_test.sh beside it are synced from cplieger/ci), so the per-repo scope
# rationale lives here.
#
# The bulk of entrypoint.sh is a hand-written radvd-config validator
# (comment-stripped directive gates plus an awk block-scanner), and its
# consequential branches are warn-only guards a healthy container never shows: a
# config that cannot be scanned, an AdvRASrcAddress pointing at a global VIP whose
# RAs every host silently discards (RFC 4861 §6.1.2), a commented-out
# IgnoreIfMissing that looks configured. tests/smoke.sh (Dockerfile test stage)
# asserts the radvd BINARY; scripts/smoke.sh asserts the supervisor's signal
# contract against a real container. Neither can reach the validator's individual
# arms, nor the pre-pid signal latch, which no container test hits
# deterministically. These do.
#
# Each *_test.sh is a separate process, so one test's stubs, traps and shell
# options cannot leak into another's. All of them run even when an early one
# fails: a boot path's tests are cheap, and a maintainer wants the whole picture
# from one CI log rather than one failure at a time.
set -u

cd -- "$(dirname -- "$0")" || exit 1

failed=0
ran=0
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
