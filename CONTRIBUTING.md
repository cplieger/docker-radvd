# Contributing to docker-radvd

This image is a minimal Alpine wrapper around the upstream `radvd` package.
The notes below cover what is specific to this repo; org-wide defaults are
inherited from [`cplieger/.github`](https://github.com/cplieger/.github).

## Layout

The files with real logic are:

- `Dockerfile` — installs the Alpine `radvd` package and wires up the
  `HEALTHCHECK` (`pidof radvd`) and `ENTRYPOINT`. The base image is pinned by
  digest; the `radvd` package is installed **unpinned** so it tracks the
  digest-pinned base — pinning the apk revision strands the build when Alpine
  bumps releases and drops the old revision from the index.
- `entrypoint.sh` — a POSIX `sh` script (runs on Alpine's BusyBox shell, not
  bash) that validates HA directives, creates `/run/radvd`, and `exec`s radvd
  in the foreground.

`compose.yaml` is the reference deployment. There is no build system, no
tests, and no application source beyond these files.

## Design boundaries (please preserve)

- **Generic, upstream-only.** No env-var-to-config translation and no bundled
  prefixes — the operator supplies their own `radvd.conf` via the read-only
  `/etc/radvd` bind mount. Resist adding a config-generation layer; it is a
  deliberate omission, not a missing feature.
- **The entrypoint warns, it does not fail.** The `IgnoreIfMissing on` and
  `AdvRASrcAddress` checks emit `level=warn` lines to stderr and keep going.
  Single-node operators legitimately run without HA, so do not turn these into
  hard failures.
- **grep patterns are anchored on purpose.** The directive checks anchor to
  the start of a line (allowing leading whitespace) so a commented-out
  `# IgnoreIfMissing on` correctly fails the check, and the `IgnoreIfMissing`
  pattern requires the value `on` so `IgnoreIfMissing off` does not pass a
  substring match. Keep that behaviour if you touch the patterns.
- **Logs are structured `key=value` to stderr.** Match the existing
  `level=... msg="..."` shape so `docker logs` output stays greppable.

## Validating locally

CI runs the same checks the README's security table lists; run them before
opening a PR:

```sh
shellcheck entrypoint.sh
hadolint Dockerfile
docker build -t docker-radvd:dev .
```

The `Dockerfile` opens with `# check=error=true`, so BuildKit build checks are
promoted to errors — a build with check warnings fails.

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
