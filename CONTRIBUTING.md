# Contributing to docker-radvd

This image is a minimal Alpine wrapper around upstream `radvd`, compiled from
the pinned release tarball.
The notes below cover what is specific to this repo; org-wide defaults are
inherited from [`cplieger/.github`](https://github.com/cplieger/.github).

## Layout

The files with real logic are:

- `Dockerfile`: compiles radvd from the pinned upstream release tarball
  (`RADVD_VERSION` + `RADVD_SHA256` build args; the tarball is verified
  fail-closed against the SHA256 before extraction) in a discarded builder
  stage, copies the stripped `radvd`/`radvdump` binaries onto the digest-pinned
  Alpine base, creates an unprivileged `radvd` user/group for the entrypoint's
  privilege drop, and wires up the `HEALTHCHECK` (`pidof radvd`) and
  `ENTRYPOINT`. Renovate bumps `RADVD_VERSION` against upstream tags, and the
  `# repin:` marker above the `RADVD_SHA256` arg lets Renovate's
  `postUpgradeTasks` recompute the SHA256 from the release asset inside the same
  bump commit, so no manual step is needed.
- `entrypoint.sh`: a POSIX `sh` script (runs on Alpine's BusyBox shell, not
  bash) that validates HA directives, creates `/run/radvd`, and supervises radvd
  in the foreground as the non-root `radvd` user (`-u radvd`): it turns `SIGHUP`
  into a config reload, forwards `SIGTERM`/`SIGINT` for graceful shutdown, and
  propagates an unexpected radvd exit to Docker's restart policy.

`compose.yaml` is the reference deployment. There is no build system and no
application source beyond these files. Two smoke tests cover the two failure
modes: a build-time test (`tests/smoke.sh`, run in the Dockerfile `test` stage)
that configtests a valid and a malformed config, and a runtime signal-contract
test (`scripts/smoke.sh`, run against the assembled image by the repo-local
`.github/workflows/smoke.yml`) that exercises the supervisor's lifecycle
contract.

## Design boundaries (please preserve)

- **Generic, upstream-only.** No env-var-to-config translation and no bundled
  prefixes; the operator supplies their own `radvd.conf` via the read-only
  `/etc/radvd` bind mount. Resist adding a config-generation layer; it is a
  deliberate omission, not a missing feature.
- **The entrypoint warns, it does not fail.** The `IgnoreIfMissing on` and
  `AdvRASrcAddress` checks emit `level=warn` lines to stderr and keep going.
  Single-node operators legitimately run without HA, so do not turn these into
  hard failures.
- **grep patterns gate on statement boundaries on purpose.** The directive
  checks strip comments first (so a commented-out `# IgnoreIfMissing on`
  correctly fails the check), fold newlines to spaces (radvd's lexer discards
  them, so a directive whose value sits on the next line is still one
  statement), and then require a statement boundary (start of the stream, `;`,
  `{` or `}`) before the directive name, so a directive
  mid-line in a one-line nested config
  (`interface eth0 { IgnoreIfMissing on; ... };`) is still seen. The
  `IgnoreIfMissing` pattern requires the value `on` so `IgnoreIfMissing off`
  does not pass a substring match. The checks scan the `radvd.conf` the daemon
  itself is given with `-C`, and the
  `AdvRASrcAddress` pattern accepts `AdvRASrcAddress {`, the no-space
  `AdvRASrcAddress{` form, and a bare `AdvRASrcAddress` at end-of-line (the
  opening brace on the next line) so a valid multi-line HA config isn't
  flagged. Keep that behaviour if you touch the patterns.
- **The non-link-local check is per-block.** Beyond presence detection, the
  `awk` scan walks every address inside every `AdvRASrcAddress` block and warns
  if _any_ is not link-local (`fe80::/10`). This is
  deliberate: a correct link-local block must not mask a sibling block that
  points at a global VIP, so a multi-interface config with one
  good and one bad source still warns, and the emitted `level=warn` line names
  each offending address in a `bad=` field so the operator can locate
  it without re-grepping. Preserve the per-block semantics if you touch the
  `awk`; an earlier version stopped at the first link-local address it saw and
  could stay silent on exactly that mixed config.
- **radvd drops to a non-root user.** The Dockerfile creates an unprivileged
  `radvd` user/group and the entrypoint runs `radvd … -u radvd`, which opens
  the raw socket as root then drops the worker to that user. Keep the `-u radvd`
  flag and the Dockerfile user together. radvd has **no `-g`/group flag** (it
  derives the GID from `-u`'s primary group), so do not add one; an unrecognized
  flag makes radvd exit before opening its socket and the container crash-loops.
- **The entrypoint supervises radvd; don't revert it to `exec radvd`.** radvd
  reads its config as root at startup but re-reads it as the unprivileged
  `radvd` user on an in-process `SIGHUP`; a config that user can't read (a
  hardened `0770 root:<group>` bind mount) makes radvd's own reload fail
  (`failed to read config file`) and the process exit. Under the
  `restart: unless-stopped` policy `compose.yaml` ships, a `docker kill -s HUP`
  then wouldn't trip Docker's restart policy either — Docker treats a container
  stopped by a signal it delivered as manually stopped, which `unless-stopped`
  honours; under `always` or `on-failure` the container would come back, so how
  bad the reload death is depends on the operator's policy. The supervisor loop
  turns `SIGHUP` into a radvd restart (re-reads as root), forwards
  `SIGTERM`/`SIGINT`, and propagates an unexpected radvd exit. `exec radvd` is
  simpler but reintroduces the reload-death, so keep the supervise-and-restart
  loop.
- **Logs are structured `key=value` to stderr.** Match the existing
  `level=... msg="..."` shape so `docker logs` output stays greppable.
- **A new fatal owes the README's alert rule an alternative.** Every
  `level=error` line the entrypoint exits non-zero on is an alternative of the
  `RadvdConfigError` pattern in README.md "Alerting" — that rule is the only
  signal an operator gets that the container is crash-looping before radvd
  starts. Adding a fatal means adding its message text to that pattern _and_
  one assertion that matches the emitted line against the rule extracted from
  the README rather than against a hand-copied string, so a reword on either
  side fails a test instead of silently switching the alert off. Copy an
  existing extraction: `tests/shell/config_triage_test.sh`'s `ALERT_RULE` or
  `tests/shell/debug_level_test.sh`'s (unit, against the captured output of the
  shipped block), or `scripts/smoke.sh`'s (runtime, against a real container's
  logs). The counter-rule, so this does not run the other
  way: do **not** add an alternative for a state an existing alternative already
  matches on the same crash-loop — that is why the empty-config warning is not
  in the pattern, and why `radvd exited; propagating exit for restart policy`
  must never be (it reports any unexpected radvd exit, whatever the cause, so it
  would fire a config alert for a crash that has nothing to do with the config).

## Validating locally

CI runs the same checks the README's security table lists; run them before
opening a PR:

```sh
shellcheck entrypoint.sh
hadolint Dockerfile
docker build -t docker-radvd:dev .   # runs tests/smoke.sh in the test stage
```

The `Dockerfile` opens with `# check=error=true`, so BuildKit build checks are
promoted to errors, so a build with check warnings fails.

If you touch the entrypoint's signal handling, run the signal-contract smoke
test against a locally built image:

```sh
docker build -t docker-radvd:smoke .
scripts/smoke.sh docker-radvd:smoke
```

It exercises the supervisor's whole lifecycle contract with no network
attached (`--network none`; `IgnoreIfMissing on` keeps radvd alive with the
interface absent, so no RA is ever emitted): startup validation, HUP reload,
the same reload with the config directory made root-only (where radvd's own
in-process reread would fail, the field failure the supervisor exists to
prevent), graceful SIGTERM shutdown, and unexpected-exit propagation to the
restart policy. CI runs the same script on every PR via the repo-local
`.github/workflows/smoke.yml` (not synced from `cplieger/ci`).

## Most CI workflows are not this repo's to edit

`ci.yaml`, `release.yaml` and `scorecard.yml` carry a `Synced from cplieger/ci …
— DO NOT EDIT` header: build, release, signing (cosign) and SBOM logic all live
in that central repo, so changing pipeline behaviour means changing it there.
`smoke.yml` is the one workflow this repo owns, and its own header says why it is
deliberately kept out of the synced template. `codeql.yml` and `security.yml`
carry no header but are byte-identical across the fleet's image repos — they are
uniform thin callers of `cplieger/ci` reusable workflows, so change them in
`cplieger/ci` or fleet-wide rather than here.

## Commits and PRs

Commits follow [Conventional Commits](https://www.conventionalcommits.org/);
git-cliff parses them for release notes and the version bump (`feat:` → minor,
`fix:`/`sec:` → patch, `chore`/`ci`/`docs` → no release). For a Dockerfile base
image bump, Renovate's `chore(deps):` commits handle it. Open an issue
first for larger changes so the approach can be discussed.

## Conduct & security

By participating you agree to the
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report vulnerabilities through the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md),
never in a public issue.
