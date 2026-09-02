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
  bash) that checks a readable mounted `radvd.conf` is a regular file,
  creates `/run/radvd`, and
  supervises radvd in the foreground as the non-root `radvd` user (`--username=radvd`):
  it turns `SIGHUP`
  into a config reload (refusing it, and keeping the running daemon, when the
  mounted config would not start), forwards `SIGTERM`/`SIGINT` for graceful
  shutdown, forwards `SIGUSR1` to radvd's own lifetime-reset handler, and
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
- **The node check separates one warning from one refusal.** The unreadable-node
  line is warn-only and boot continues, because a config the entrypoint cannot
  read may still be readable by radvd. Do not turn this warning into a hard
  failure. The non-regular-node arm exits 1 from both call sites because radvd
  cannot consume a FIFO or directory, and its own open of one is unbounded.
- **The wrapper reports what the config composes; radvd reports its own
  diagnostics.** A state radvd announces unconditionally through
  `flog(LOG_ERR, …)` is left to radvd's own line and to the supervisor's exit
  report: a config it rejects outright (`radvd.c:330`, `:812`), and an interface
  it cannot set up under `IgnoreIfMissing off` (`radvd.c:780-786`, then
  `exit(1)`). The wrapper does not read the config's directive composition. An
  interface block with no enabled `AdvSendAdvert on` and an `AdvRASrcAddress`
  pinned to a global VIP both run silently. radvd reports the first only at
  debug 2 and only for an interface it has brought up, and it never reports the
  second. Use `rdisc6` from a LAN host or `radvdump` on the peer to check these
  states. So before adding a warning, state three things: the
  upstream line, its level, and whether radvd reaches it in the HA topology the
  README mandates. A worked example
  of a warning that FAILS the test, so both sides of the rule are visible: a
  quoted interface name is not filable, because `update_device_index` prints
  `%s not found: %s` through `flog(LOG_ERR)` — unfiltered, so readable at the
  shipped debug 0 — and because a six-byte name whose first and last bytes are
  quotes is a legal Linux device name (`dev_valid_name` does not reject quotes),
  so the warning would fire on a valid interface.
- **radvd drops to a non-root user.** The Dockerfile creates an unprivileged
  `radvd` user/group and the entrypoint runs `radvd … --username=radvd`, which opens
  the raw socket as root then drops the worker to that user. Keep the `--username=radvd`
  flag and the Dockerfile user together. radvd has **no `-g`/group flag** (it
  derives the GID from `-u`'s primary group), so do not add one; an unrecognized
  flag makes radvd exit before opening its socket and the container crash-loops.
- **The entrypoint supervises radvd; don't revert it to `exec radvd`.** radvd
  reads its config as root at startup but re-reads it as the unprivileged
  `radvd` user on an in-process `SIGHUP`; a config that user can't read (a
  hardened `0770 root:<group>` bind mount) makes radvd's own reload fail
  (`failed to read config file`) and the process exit. A `docker kill -s HUP`
  then wouldn't trip Docker's restart policy either, whatever the policy: the
  daemon cancels the container's restart manager at kill time when the container
  configures no stop signal, and neither this image nor the `compose.yaml` here
  sets one. An operator who does set `stop_signal` — even one that only restates
  SIGTERM — keeps crash-recreate armed under `always` or `on-failure`, so how bad
  a reload death is depends on that setting. The supervisor loop turns `SIGHUP`
  into a radvd restart (re-reads as root), forwards `SIGTERM`/`SIGINT`, forwards
  `SIGUSR1`, and propagates an unexpected radvd exit. A stop that lands while no
  radvd exists
  (during preflight, or the reload gap between generations) wins without radvd
  starting: `start_radvd`'s gate exits 0 rather than forking a daemon whose own
  handler installation the forwarded TERM would race — a lost race swallows the
  signal and strands PID 1 in `wait` until the stop grace SIGKILLs it (measured
  at 29-59% per hit under CPU contention). Keep the gate ahead of the fork.
  `exec radvd` is simpler
  but reintroduces the reload-death, so keep the supervise-and-restart loop.
- **The reload config-tests before it stops anything, and that is a filter, not
  a guarantee.** `request_reload` refuses the reload when `radvd.conf` is absent
  or not a regular file, and otherwise on any non-zero status from
  `radvd --configtest --config="$CONF" --username=radvd` under a bound, so a bad edit costs the operator a
  reload rather than the segment its RA emitter. The `--username=radvd` is load-bearing:
  `check_conffile_perm` judges the config file against that user, so a gate
  running without it asks a different question from the one the replacement
  daemon answers. One verdict then needs reading rather than status alone.
  `radvd -c` forces debuglevel 1 (`radvd.c:289-290`), which turns the
  insecure-`conf_file` refusal into a warning it exits 0 on (`radvd.c:319-325`),
  while the daemon at debuglevel 0 exits 1 on the same file — so at
  `RADVD_DEBUG_LEVEL=0` the gate refuses on radvd's own captured
  `Insecure file permissions` text, and above it does not, because there the
  daemon takes the warn arm too. That is a read of radvd's reply, never a replica
  of its check. `radvd -c` refuses nothing the daemon
  accepts, which is what makes the gate safe to add; startup stays ungated,
  because at boot there is no last good config to keep serving. What the gate
  cannot cover is everything radvd checks AFTER `readin_config`: `radvd -c` is
  the parser and exits there, so the interface's
  presence on the host, every per-interface parameter bound, and a config
  replaced between the check and the daemon's own read all pass it. That residue
  is published in the README's Reloading section by cause rather than closed. Do
  not close it by replicating radvd's startup checks in shell: `check_conffile_perm`
  is upstream's and still moving (it carries its own TODO about supplementary
  groups), `check_iface` is a dozen parameter bounds that move with every
  release, and Renovate lands `RADVD_VERSION` bumps unattended, so a replica goes
  stale silently and in the unsafe direction. Alert on radvd's own text instead;
  the `RadvdConfigError` pattern carries those lines.
- **Logs are structured `key=value` to stderr.** Match the existing
  `level=... msg="..."` shape so `docker logs` output stays greppable. One
  deliberate exception: `request_reload`'s refusal arm republishes radvd's captured
  stderr verbatim and unstructured, because the README's `RadvdConfigError` rule
  matches those bytes and `scripts/smoke.sh` asserts it. Do not route that
  through `sanitize_log_value`.
- **A new emitted signal owes the README's alert rules an alternative.** Every
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
  logs). Two further arms carry the same obligation and the same assertion
  requirement. A new `level=warn` line that predicts, or leaves unknown, zero
  usable Router Advertisement output owes `RadvdAdvertisementsUnverified` an
  alternative. That rule now carries only the unreadable-node line. The state
  produces no fatal, so no alternative of `RadvdConfigError` matches it and the
  log is the operator's only channel. And
  a newly discovered class of radvd's OWN diagnostics that does not exit the
  process owes `RadvdConfigError` an alternative, because `radvd -c` runs the
  parser only, so the reload gate cannot refuse those configs either.
  The counter-rule applies to all three, so this does not run the other
  way: do **not** add an alternative for a state something already matched
  reports, and do **not** add one for a warning that does not predict zero RA
  output. That is why
  `radvd exited; propagating exit for restart policy`
  must never be one (it reports any unexpected radvd exit, whatever the cause, so
  it would fire a config alert for a crash that has nothing to do with the config).

## Validating locally

CI runs the same checks the README's security table lists; run them before
opening a PR:

```sh
shellcheck entrypoint.sh
hadolint --ignore DL3018 --ignore DL3066 Dockerfile
bash tests/shell/run.sh   # entrypoint unit tests; two cases are uid-gated and skip as root
docker build -t docker-radvd:dev .   # runs tests/smoke.sh in the test stage
```

Those two `--ignore` flags are what CI passes for every repo, so a bare
`hadolint Dockerfile` reports findings the gate does not have.

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
interface absent, so no RA is ever emitted): startup and the shipped healthcheck, HUP reload,
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
