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
  bash) that validates the mounted `radvd.conf`, creates `/run/radvd`, and
  supervises radvd in the foreground as the non-root `radvd` user (`-u radvd`):
  it turns `SIGHUP`
  into a config reload (refusing it, and keeping the running daemon, when the
  mounted config would not start), forwards `SIGTERM`/`SIGINT` for graceful
  shutdown, and propagates an unexpected radvd exit to Docker's restart policy.

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
- **The directive checks warn; they do not fail.** Every `level=warn` line
  `check_config_directives` emits goes to stderr and the boot continues, because
  single-node operators legitimately run without HA and a warning about a
  misconfiguration is not a reason to refuse the whole container. Do not turn
  these into hard failures. The one exception is the non-regular-node refusal at
  the top of the function: radvd cannot consume a FIFO or a directory as its
  config file, so that arm exits 1, and it does so from both call sites on
  purpose (see the comment above it).
- **The scan lexes the config; it does not grep it.** Comments are stripped
  first (so a commented-out `# AdvSendAdvert on` correctly fails the check), and
  a double-quoted value becomes ONE opaque token: its quotes are kept, and every
  byte that means something to the walk (`{`, `}`, `;`, `#`, whitespace, and the
  newline that ends a record) is neutralised inside them. Keeping the quotes
  matches upstream. `scanner.l`'s `string` macro is
  `[a-zA-Z0-9…]+|L?\"(\\.|[^\\"])*\"`, so the delimiters are part of the match
  and reach `yylval.str`. Two consequences. A quoted value decides nothing,
  wrapped across lines or not and however short — `"AdvRASrcAddress"` is a STRING
  to radvd, never the directive. And a quoted interface name keeps its quotes,
  because radvd's name for `interface "eth0"` is the 6-byte `"eth0"`; report
  `eth0` and the operator looks for a device radvd never asked about. What is
  left is
  tokenized with `{`, `}` and `;` as tokens of their own, so a name is only a
  directive on a statement boundary (`MyIgnoreIfMissing on` is not one), a
  directive whose value sits on the next line is still one statement (radvd's
  lexer discards newlines), and all three `AdvRASrcAddress` spellings —
  `AdvRASrcAddress {`, the no-space `AdvRASrcAddress{`, and a bare
  `AdvRASrcAddress` at end-of-line with the brace on the next — need no special
  case. The scan reads the `radvd.conf` the daemon itself is given with `-C`.
  Keep those properties if you touch the walk.
- **Each directive is credited to the interface block it sits directly inside.**
  A directive lexed in a nested block belongs to that block, not to the
  enclosing interface, and every warning names its block in an `iface=` field.
  That name is operator-supplied config text (radvd's scanner accepts a quoted,
  escaped string there), so it goes through `sanitize_log_value` like every
  other config value reaching the log stream.
- **Absence is not the defect; the wrong VALUE is.** `IgnoreIfMissing` defaults
  to on upstream, so an absent directive is a correct config and only an explicit
  `IgnoreIfMissing off` warns. `AdvSendAdvert` defaults to off, so its absence
  from an interface block does warn: radvd runs and emits nothing. Both defaults
  are read out of the pinned source's `defaults.h` by `tests/smoke.sh`, which
  fails the build if upstream moves one — a gate about a directive's absence is
  only correct while upstream's default for it is the unwanted value.
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
  (`failed to read config file`) and the process exit. A `docker kill -s HUP`
  then wouldn't trip Docker's restart policy either, whatever the policy: the
  daemon cancels the container's restart manager at kill time when the container
  configures no stop signal, and neither this image nor the `compose.yaml` here
  sets one. An operator who does set `stop_signal` — even one that only restates
  SIGTERM — keeps crash-recreate armed under `always` or `on-failure`, so how bad
  a reload death is depends on that setting. The supervisor loop turns `SIGHUP`
  into a radvd restart (re-reads as root), forwards `SIGTERM`/`SIGINT`, and
  propagates an unexpected radvd exit. `exec radvd` is simpler but reintroduces
  the reload-death, so keep the supervise-and-restart loop.
- **The reload config-tests before it stops anything, and that is a filter, not
  a guarantee.** `on_hup` refuses the reload on a `radvd.conf` that is absent or
  not a regular file, and otherwise on any non-zero status from
  `radvd -c -C "$CONF"` under a bound, so a bad edit costs the operator a reload
  rather than the segment its RA emitter. `radvd -c` refuses nothing the daemon
  accepts, which is what makes the gate safe to add; startup stays ungated,
  because at boot there is no last good config to keep serving. What the gate
  cannot cover is everything radvd checks AFTER `readin_config`: `radvd -c` is
  the parser and exits there, so the `radvd.conf` permissions, the interface's
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
  deliberate exception: `on_hup`'s refusal arm republishes radvd's captured
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
  alternative: none of those states produces a fatal, so no alternative of
  `RadvdConfigError` matches them and the log is the operator's only channel. And
  a newly discovered class of radvd's OWN diagnostics that does not exit the
  process owes `RadvdConfigError` an alternative, because `radvd -c` runs the
  parser only, so the reload gate cannot refuse those configs either.
  The counter-rule applies to all three, so this does not run the other
  way: do **not** add an alternative for a state something already matched
  reports, and do **not** add one for a warning that does not predict zero RA
  output. That is why the no-interface warning
  (`radvd.conf defines no interface`) is in neither pattern (radvd's own
  `exiting, failed to read config file` fires), why an explicit
  `IgnoreIfMissing off` is not (on the backup where it bites, radvd's
  `setup_iface=` fatal fires), why an absent `AdvRASrcAddress` is not (it breaks
  failover, not this node's emission), and why
  `radvd exited; propagating exit for restart policy`
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
