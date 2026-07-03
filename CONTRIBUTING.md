# Contributing to docker-radvd

This image is a minimal Alpine wrapper around the upstream `radvd` package.
The notes below cover what is specific to this repo; org-wide defaults are
inherited from [`cplieger/.github`](https://github.com/cplieger/.github).

## Layout

The files with real logic are:

- `Dockerfile` — installs the Alpine `radvd` package, creates an unprivileged
  `radvd` user/group for the entrypoint's privilege drop, and wires up the
  `HEALTHCHECK` (`pidof radvd`) and `ENTRYPOINT`. The base image is pinned by
  digest; the `radvd` package is installed **unpinned** so it tracks the
  digest-pinned base — pinning the apk revision strands the build when Alpine
  bumps releases and drops the old revision from the index.
- `entrypoint.sh` — a POSIX `sh` script (runs on Alpine's BusyBox shell, not
  bash) that validates HA directives, creates `/run/radvd`, and supervises radvd
  in the foreground as the non-root `radvd` user (`-u radvd`): it turns `SIGHUP`
  into a config reload, forwards `SIGTERM`/`SIGINT` for graceful shutdown, and
  propagates an unexpected radvd exit to Docker's restart policy.

`compose.yaml` is the reference deployment. There is no build system and no
application source beyond these files; the only test is a build-time smoke test
(`tests/smoke.sh`, run in the Dockerfile `test` stage) that configtests a valid
and a malformed config.

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
  substring match. The checks scan every `*.conf` in the mounted directory (not
  just `radvd.conf`) so directives in `include`d files are seen, and the
  `AdvRASrcAddress` pattern accepts `AdvRASrcAddress {`, the no-space
  `AdvRASrcAddress{` form, and a bare `AdvRASrcAddress` at end-of-line (the
  opening brace on the next line) so a valid multi-line HA config isn't
  flagged. Keep that behaviour if you touch the patterns.
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

If you touch the entrypoint's signal handling, exercise the supervisor by hand:
run the built image with a valid config for an interface that exists in the
container, then `docker kill -s HUP <container>` — it should log
`reloading radvd` and stay `Up`, not exit. Repeat with the config directory made
unreadable to the `radvd` user (`chown root:root` + `chmod 700`) to confirm the
reload still succeeds where radvd's own in-process reread would fail.

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
