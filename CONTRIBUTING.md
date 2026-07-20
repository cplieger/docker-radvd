# Contributing to docker-radvd

This image is a minimal Alpine wrapper around upstream `radvd`, compiled from
the pinned release tarball.
The notes below cover what is specific to this repo; org-wide defaults are
inherited from [`cplieger/.github`](https://github.com/cplieger/.github).

## Layout

The files with real logic are:

- `Dockerfile` — compiles radvd from the pinned upstream release tarball
  (`RADVD_VERSION` + `RADVD_SHA256` build args; the tarball is verified
  fail-closed against the SHA256 before extraction) in a discarded builder
  stage, copies the stripped `radvd`/`radvdump` binaries onto the digest-pinned
  Alpine base, creates an unprivileged `radvd` user/group for the entrypoint's
  privilege drop, and wires up the `HEALTHCHECK` (`pidof radvd`) and
  `ENTRYPOINT`. Renovate bumps `RADVD_VERSION` against upstream tags; the
  SHA256 must be recomputed by hand on each bump (the bump PR body carries the
  command).
- `entrypoint.sh` — a POSIX `sh` script (runs on Alpine's BusyBox shell, not
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
  prefixes — the operator supplies their own `radvd.conf` via the read-only
  `/etc/radvd` bind mount. Resist adding a config-generation layer; it is a
  deliberate omission, not a missing feature.
- **The entrypoint warns, it does not fail.** The `IgnoreIfMissing on` and
  `AdvRASrcAddress` checks emit `level=warn` lines to stderr and keep going.
  Single-node operators legitimately run without HA, so do not turn these into
  hard failures.
- **grep patterns gate on statement boundaries on purpose.** The directive
  checks strip comments first (so a commented-out `# IgnoreIfMissing on`
  correctly fails the check) and then require a statement boundary — start
  of line, `;`, `{` or `}` — before the directive name, so a directive
  mid-line in a one-line nested config
  (`interface eth0 { IgnoreIfMissing on; ... };`) is still seen. The
  `IgnoreIfMissing` pattern requires the value `on` so `IgnoreIfMissing off`
  does not pass a substring match. The checks scan every `*.conf` in the
  mounted directory (not just `radvd.conf`) so directives in `include`d files
  are seen, and the
  `AdvRASrcAddress` pattern accepts `AdvRASrcAddress {`, the no-space
  `AdvRASrcAddress{` form, and a bare `AdvRASrcAddress` at end-of-line (the
  opening brace on the next line) so a valid multi-line HA config isn't
  flagged. Keep that behaviour if you touch the patterns.
- **The non-link-local check is per-block.** Beyond presence detection, the
  `awk` scan walks every address inside every `AdvRASrcAddress` block (across
  all `*.conf`) and warns if _any_ is not link-local (`fe80::/10`). This is
  deliberate: a correct link-local block must not mask a sibling block that
  points at a global VIP, so a multi-interface or multi-file config with one
  good and one bad source still warns, and the emitted `level=warn` line names
  each offending `<file>:<address>` in a `bad=` field so the operator can locate
  it without re-grepping. Preserve the per-block semantics if you touch the
  `awk` — an earlier version stopped at the first link-local address it saw and
  could stay silent on exactly that mixed config.
- **radvd drops to a non-root user.** The Dockerfile creates an unprivileged
  `radvd` user/group and the entrypoint runs `radvd … -u radvd`, which opens
  the raw socket as root then drops the worker to that user. Keep the `-u radvd`
  flag and the Dockerfile user together. radvd has **no `-g`/group flag** — it
  derives the GID from `-u`'s primary group — so do not add one; an unrecognized
  flag makes radvd exit before opening its socket and the container crash-loops.
- **The entrypoint supervises radvd — don't revert it to `exec radvd`.** radvd
  reads its config as root at startup but re-reads it as the unprivileged
  `radvd` user on an in-process `SIGHUP`; a config that user can't read (a
  hardened `0770 root:<group>` bind mount) makes radvd's own reload fail
  (`failed to read config file`) and the process exit — and a `docker kill -s
  HUP` then wouldn't trip Docker's restart policy either. The supervisor loop
  turns `SIGHUP` into a radvd restart (re-reads as root), forwards
  `SIGTERM`/`SIGINT`, and propagates an unexpected radvd exit. `exec radvd` is
  simpler but reintroduces the reload-death, so keep the supervise-and-restart
  loop.
- **Logs are structured `key=value` to stderr.** Match the existing
  `level=... msg="..."` shape so `docker logs` output stays greppable.

## Validating locally

CI runs the same checks the README's security table lists; run them before
opening a PR:

```sh
shellcheck entrypoint.sh
hadolint Dockerfile
docker build -t docker-radvd:dev .   # runs tests/smoke.sh in the test stage
```

The `Dockerfile` opens with `# check=error=true`, so BuildKit build checks are
promoted to errors — a build with check warnings fails.

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
in-process reread would fail — the field failure the supervisor exists to
prevent), graceful SIGTERM shutdown, and unexpected-exit propagation to the
restart policy. CI runs the same script on every PR via the repo-local
`.github/workflows/smoke.yml` (not synced from `cplieger/ci`).

## CI workflows are synced — don't edit them

The files under `.github/workflows/` carry a `DO NOT EDIT` header and are
synced from `cplieger/ci`. Build, release, signing (cosign), and SBOM logic
all live in that central repo; changing pipeline behaviour means changing it
there, not here.

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
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md) —
never in a public issue.
