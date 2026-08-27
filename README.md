# docker-radvd

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-radvd/badges/size.json)](https://github.com/cplieger/docker-radvd/pkgs/container/docker-radvd)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13207/badge)](https://www.bestpractices.dev/projects/13207)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-radvd/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-radvd)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-radvd/releases)

Run [radvd](https://radvd.litech.org/) (the Linux IPv6 Router Advertisement Daemon) in a container. Bring your own `radvd.conf`.

## What it does

[radvd](https://radvd.litech.org/) emits IPv6 Router Advertisements (RAs) onto the LAN so hosts can do SLAAC (StateLess Address AutoConfiguration): learn the local prefix(es), default router, and DNS. Without an RA emitter on the LAN, IPv6 hosts stay link-local-only and can't route off-segment.

This image is a minimal Alpine wrapper around upstream `radvd`, compiled from the pinned release tarball, plus a small POSIX entrypoint that:

- **Validates the mounted `radvd.conf`** and warns about the misconfigurations that leave the segment with no usable RA emitter: a config defining no interface block at all (radvd's grammar requires one, so radvd exits), and, per interface block, a block that enables no `AdvSendAdvert on` (radvd defaults it to off, so it runs and emits nothing), a block with no `AdvRASrcAddress`, an `AdvRASrcAddress` set to a non-link-local (global/ULA) address that RFC 4861 requires hosts to silently discard, and an explicit `IgnoreIfMissing off`. An absent `IgnoreIfMissing` draws no warning: radvd already defaults it to on. One shape is refused rather than warned about, at startup and on reload alike: a `radvd.conf` that is not a regular file, which radvd itself cannot consume, exits 1
- **Creates `/run/radvd`** (radvd refuses to start without it)
- **Drops privileges**: radvd opens its raw socket as root, then runs as the unprivileged `radvd` user (`-u radvd`) for the rest of its lifetime
- **Supervises radvd**: turns `SIGHUP` into a clean config reload, refusing the reload and keeping the running daemon when the config would not start, forwards `SIGTERM` for graceful shutdown, and propagates an unexpected radvd exit to Docker's restart policy — until a `docker kill` disarms that policy for the rest of the container's run, unless a `stop_signal` is configured (see [Reloading](#reloading-configuration))
- **Logs to stderr** with structured key=value lines, captured by `docker logs`

### Why this design

- **Generic upstream-only**: no env-var-to-config translation, no bundled prefixes; you supply your own `radvd.conf`. The one env var, `RADVD_DEBUG_LEVEL`, tunes radvd's log verbosity only (see [Configuration reference](#configuration-reference))
- **Bind-mount only**: single read-only `:ro` mount of `/etc/radvd`
- **Entrypoint warns on HA misconfig**: warn-only, never fatal, since single-node operators legitimately deploy without HA (see [High-availability with keepalived](#high-availability-with-keepalived))
- **Healthcheck**: `pidof radvd` (CMD form, no shell needed)
- **Multi-arch**: `linux/amd64` and `linux/arm64`

## Quick start

Available from both `ghcr.io/cplieger/docker-radvd` and `docker.io/cplieger/docker-radvd`; identical images and tags.

```yaml
services:
  radvd:
    image: ghcr.io/cplieger/docker-radvd:latest
    container_name: radvd
    restart: unless-stopped

    # radvd emits RAs onto the LAN, so it needs host networking and a raw ICMPv6 socket.
    network_mode: host
    cap_add:
      - NET_RAW  # required: raw ICMPv6 socket to emit RAs

    volumes:
      - "./radvd:/etc/radvd:ro"
```

Minimal `radvd.conf` (single-node, advertises a /64):

```conf
interface eth0 {
    AdvSendAdvert on;
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;

    prefix 2001:db8:1::/64 {
        AdvOnLink on;
        AdvAutonomous on;
    };

    RDNSS 2001:db8:1::1 {};
    DNSSL example.lan {};
};
```

## High-availability with keepalived

If you run radvd on two or more nodes for HA, both nodes will emit RAs by default: clients pick whichever they hear last, or alternate randomly, breaking default-route selection. The proper pattern is:

1. **Manage a floating link-local with keepalived**: only the MASTER owns it at any moment
2. **`AdvRASrcAddress` in `radvd.conf`**: point it at that **link-local**. It must be link-local: [RFC 4861 §6.1.2](https://www.rfc-editor.org/rfc/rfc4861#section-6.1.2) requires an RA's source to be a link-local address, and hosts silently discard any RA sourced from a global address. Pointing it at a global service VIP is the classic mistake: radvd emits, `tcpdump` shows the RAs, yet no host ever autoconfigures.
3. **`IgnoreIfMissing on`**: radvd tolerates the source address being absent on the BACKUP node (stays running, just doesn't emit RAs). This is radvd's own default, so the directive is worth setting explicitly rather than required; an explicit `IgnoreIfMissing off` is what breaks a BACKUP

Result: both radvd processes run continuously, but only the MASTER node emits RAs (because only it has the link-local). On failover, keepalived moves the address, and the new MASTER's radvd starts emitting RAs within seconds.

Example HA `radvd.conf`:

```conf
interface eth0 {
    AdvSendAdvert on;
    IgnoreIfMissing on;                          # tolerate missing VIP
    AdvRASrcAddress { fe80::1; };                # use the keepalived-managed link-local VIP

    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;

    prefix 2001:db8:1::/64 {
        AdvOnLink on;
        AdvAutonomous on;
    };
};
```

The entrypoint warns at startup when an interface block has no `AdvRASrcAddress`, when `AdvRASrcAddress` is set to a non-link-local address (the classic mistake above), and when `IgnoreIfMissing` is explicitly `off` on a node that needs to tolerate the address being absent, so you find out before clients do. To see whether a node is actually emitting, the image ships upstream's own RA decoder: `docker exec radvd radvdump` on the peer node shows whether the BACKUP is emitting while the MASTER holds the link-local, which is the failure this pattern exists to prevent. See [docker-keepalived](https://github.com/cplieger/docker-keepalived) for the sibling container.

Background reading: [Firstyear's blog post on HA radvd on Linux](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/) explains the pattern in detail.

## Reloading configuration

Reload after editing the mounted config with a `SIGHUP`:

```bash
docker kill -s HUP radvd
```

The entrypoint restarts the daemon so it re-reads the config; `docker restart radvd` works too. On reload it also re-runs the directive checks and re-emits any warnings for the (possibly edited) config, so a misconfiguration introduced by an edit shows up in `docker logs` at reload time rather than only at the next full restart. This supervise-and-restart design (rather than `exec`-ing radvd) is what makes reload work regardless of the config file's ownership; see [CONTRIBUTING](CONTRIBUTING.md) for the rationale.

Most bad edits are refused before anything is stopped. The entrypoint config-tests the mounted file first, so a config that is malformed, absent, or not a regular file at that moment leaves the running radvd serving its last good config, with radvd's own rejection text and a `SIGHUP reload refused` line in `docker logs`. A refused reload does not re-run the directive checks, because those would describe a config that is not in effect.

The check is `radvd -c`, which runs radvd's config parser and stops there, so anything radvd validates after it has parsed the file passes this gate: the permissions on `radvd.conf`, the interface's presence on the host, every per-interface parameter bound (`MinRtrAdvInterval` against 3/4 of `MaxRtrAdvInterval`, lifetimes, prefix lengths, MTU), and a config replaced between the check and the daemon's own read. What happens next depends on `IgnoreIfMissing`. With it `off`, radvd exits, the container exits with it, and `docker logs` carries a line the `RadvdConfigError` rule below matches. With it `on`, the upstream default and what the high-availability section above tells you to set, radvd stays running and the healthcheck stays green while that interface emits nothing at all; the only evidence is radvd's own error line, such as `MinRtrAdvInterval for eth0 (200.00) must be at least 3.00 but no more than 3/4 of MaxRtrAdvInterval (180.00)`. Verify with `rdisc6` after any config change, and alert on it: the `RadvdConfigError` rule below carries these lines.

One Docker behaviour to plan for: any signal delivered with `docker kill` cancels the container's restart manager for the remainder of that run when no `stop_signal` is configured, so crash-recreate stays disarmed until the next `docker start` or `docker restart`. Prefer `docker restart` where crash-recreate matters, since starting a container resets the manager.

## Configuration reference

### Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `RADVD_DEBUG_LEVEL` | `0` | radvd's `-d` debug level, `0`–`5`. At `0` radvd still logs its startup banner and every warning and error; `1` adds a config `syntax ok` confirmation plus a per-wakeup `polling for ...` line that is noisy under `docker logs`; higher levels are progressively chattier. An invalid value fails startup with a clear error rather than running at an unintended verbosity. |

Everything else about the daemon comes from the mounted `radvd.conf`; this variable
only controls how much radvd logs.

### Volumes

| Mount        | Description                                              |
| ------------ | -------------------------------------------------------- |
| `/etc/radvd` | Directory containing your `radvd.conf`. Mount read-only. |

### Capabilities

| Capability | Why needed |
| --- | --- |
| `NET_RAW` | **Required.** Opens the raw ICMPv6 socket used to send Router Advertisements. Without it radvd exits at startup (`open_icmpv6_socket: Operation not permitted`). |
| `NET_ADMIN` | Not needed for Router-Advertisement emission, and inert in a default container: Docker mounts `/proc/sys` read-only in every unprivileged container, so the writes radvd makes for kernel-applied interface-parameter directives (`AdvLinkMTU`, `AdvCurHopLimit`, `AdvReachableTime`, `AdvRetransTimer`) to `/proc/sys/net/ipv6/{conf,neigh}/*` fail whether the capability is granted or not. It becomes meaningful only if you make `/proc/sys` writable yourself (`read_only: true` is a different thing — it governs the container's own rootfs). **No capability beyond `NET_RAW` is needed for Router-Advertisement emission.** Under `cap_drop: ALL` see the hardened profile below, which lists the three further capabilities the privilege drop and the supervisor's signalling require. |

#### Hardened profile

Under `read_only: true`, `/run` must be a writable `tmpfs`: radvd writes its PID
file to the compiled-in `/run/radvd/radvd.pid`, and the entrypoint creates that
directory at startup, so without it the container exits 1 with
`failed to create radvd PID directory` before radvd ever starts. Add to the
service in the [Quick start](#quick-start) example:

```yaml
    read_only: true
    tmpfs:
      - /run:size=1m
    cap_drop:
      - ALL
    cap_add:
      - NET_RAW
      - SETUID
      - SETGID
      - KILL
    security_opt:
      - no-new-privileges:true
```

All four capabilities are already in Docker's default set, so this profile grants
nothing the [Quick start](#quick-start) example does not have; `cap_drop: ALL` is
what makes listing them necessary. None of the four can be dropped further:

- `NET_RAW` opens the raw ICMPv6 socket radvd sends Router Advertisements on.
  Without it radvd exits at startup with
  `open_icmpv6_socket: Operation not permitted`.
- `SETUID` and `SETGID` let the entrypoint drop radvd to the non-root `radvd`
  user. Without them `drop_root_privileges` returns -1 and radvd exits 1 with no
  warn-and-continue arm, which the Quick start's `restart: unless-stopped` turns
  into a crash loop.
- `KILL` lets the root supervisor signal its own non-root child. Without it both
  documented signal paths fail, and the entrypoint can only report the refusal:
  `docker stop` leaves radvd running while PID 1 exits 0 (with a
  `a graceful stop cannot be confirmed` warning), so the final zero-lifetime
  Router Advertisement is never sent and LAN hosts keep this node as their
  default router until the advertised lifetime expires; and
  `docker kill -s HUP` starts a second radvd that dies on the pid-file lock.

### Networking

| Setting        | Value                 | Reason                                                                                      |
| -------------- | --------------------- | ------------------------------------------------------------------------------------------- |
| `network_mode` | `host` (or `macvlan`) | RAs are emitted via ICMPv6 on a real LAN interface; container networking would isolate them |

## Healthcheck

The built-in healthcheck runs `pidof radvd` every 30s (5s timeout, 3 retries, 15s start period), so a container whose daemon is up reports `healthy`. It is a liveness probe only, and it is not what reacts to a crash: when radvd dies the supervising entrypoint propagates the exit and the container stops within a second, so a crash is handled by your `restart` policy rather than by the container ageing into `unhealthy` — with the `docker kill` caveat in [Reloading](#reloading-configuration), which disarms that policy for the rest of the run when no `stop_signal` is configured.

Neither the probe nor that exit propagation covers "RAs aren't being emitted because the source address is missing" (that's the HA case where radvd intentionally stays running but silent). The image ships upstream's own RA decoder, `radvdump`, so `docker exec radvd radvdump` is a first look at what is on the wire — run it on the peer node to confirm the BACKUP is staying silent; whether it sees this container's own RAs depends on multicast loopback. For end-to-end verification, run an off-host probe that listens for RAs on the LAN segment:

```bash
# On any IPv6 host on the LAN:
sudo rdisc6 eth0
```

If you see an RA from your radvd source address within a few seconds, it's working.

## Alerting

radvd has no metrics endpoint; its operational state is in its logs. Ship the
container's logs (stdout and stderr) to Loki (Grafana Alloy's Docker log
discovery does this with no configuration) and evaluate these rules with
[Loki's ruler](https://grafana.com/docs/loki/latest/alert/); firing alerts
deliver through your Alertmanager exactly like Prometheus metric alerts.

```yaml
groups:
  - name: radvd
    rules:
      - alert: RadvdConfigError
        expr: |
          sum by (hostname) (count_over_time(
            {container="radvd"}
            |~ `exiting, failed to read config file|exiting, permissions on conf_file invalid|does not exist or is not set up properly \(setup_iface=|unable to drop root privileges|invalid RADVD_DEBUG_LEVEL|radvd.conf exists but is not readable|radvd.conf is not a regular file|failed to create radvd PID directory|must be at least|must be between|must be zero or between|must not be greater than|must be set with|must be greater than or equal to AdvPreferredLifetime|invalid prefix length|invalid route prefix length` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "radvd rejected its config"
          description: >
            radvd logged a config parse or activation failure. Check your
            radvd.conf. Present at startup, radvd exits, the supervising
            entrypoint propagates the exit, and IPv6 RA emission stops until
            the config is fixed; `docker restart` re-enters startup, so it
            crash-loops. Introduced by a later edit and a `SIGHUP` reload, the
            entrypoint config-tests first and refuses the reload, so the
            running radvd keeps serving its last good config and keeps
            emitting: that line is a rejected edit to fix, not an outage. The
            pattern also matches the entrypoint's own fatal startup errors (an
            invalid RADVD_DEBUG_LEVEL, an unreadable radvd.conf, a radvd.conf
            that is not a regular file, a failed /run/radvd creation), which
            crash-loop the container before radvd ever starts, and radvd's
            `unable to drop root privileges`, which is not a config fault at
            all: the container was started without the SETUID and SETGID
            capabilities, so `-u radvd` cannot take effect (see the hardened
            profile above).
            Three groups pass the reload config test, so for them the
            rejected-edit reading does not hold: the conf_file permissions, the
            interface's presence, and the per-interface parameter bounds
            (interval bounds, lifetimes, prefix lengths, MTU). What follows
            depends on `IgnoreIfMissing`. With it off, the container exits and
            crash-loops. With it on, the upstream default and what the
            high-availability section asks for, radvd stays running, the
            healthcheck stays green, and this alert is the only signal that the
            segment has no RA emitter.
      - alert: RadvdAdvertisementsUnverified
        expr: |
          sum by (hostname) (count_over_time(
            {container="radvd"}
            |~ `no enabled AdvSendAdvert on directive found|AdvRASrcAddress is set to a non-link-local address|unable to scan mounted radvd config` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "radvd accepted its config but its Router Advertisements may not be usable"
          description: >
            The entrypoint validated the mounted radvd.conf and reported one of
            three states. radvd runs and reports `healthy` through all of them,
            which is why this rule exists. An interface block with no
            `AdvSendAdvert on` is a definite zero: radvd defaults that
            directive to off, so it runs and emits nothing. A non-link-local
            `AdvRASrcAddress` is a zero only when that address is the one radvd
            selects, so a list that also holds a present link-local may still
            emit usable RAs. An unscannable config means the checks did not
            run, so nothing was verified either way. Each line is emitted once
            per container start and once per accepted reload, so the alert
            fires when a bad config is deployed and resolves after the window
            while the misconfiguration persists. Read the config, then confirm
            what reaches the LAN with `rdisc6`.
```

Every pattern above is a string radvd 2.21 or the entrypoint actually emits,
checked against upstream's own sources. Note that `properly \(setup_iface=` is
anchored on the opening parenthesis so it matches only the fatal form; the
`ignoring the interface (setup_iface=` form radvd emits when
`IgnoreIfMissing on` is set is a normal HA-backup state, not an alert — and
radvd logs it at debug level 4, so at the default `RADVD_DEBUG_LEVEL=0` it does
not appear in `docker logs` at all. The parameter-bound fragments are upstream's
wording at the pinned version, so a reword upstream narrows the rule silently;
that costs a missed alert, never a false one, which is the trade every other
alternative here already makes.

Thresholds and the `severity` label are starting points. The `container`
selector and the `hostname` grouping label depend on your log collector:
Alloy's Docker discovery provides `container`, while `hostname` comes from your
own labeling, so adjust or drop `sum by (hostname)` to match. Route by whatever
labels your Alertmanager uses.

## Security

radvd opens its raw ICMPv6 socket as root, then drops to the unprivileged `radvd` user for the rest of its lifetime; the config mount is read-only. CI lints the entrypoint with [shellcheck](https://www.shellcheck.net/) and the Dockerfile with [hadolint](https://github.com/hadolint/hadolint), scans for leaked secrets with [gitleaks](https://github.com/gitleaks/gitleaks), and scans the image with [trivy](https://trivy.dev/); current scan results live in the repository's Security tab.

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-radvd:latest \
    --certificate-identity-regexp "https://github.com/cplieger/docker-radvd/.github/workflows/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate).

- **radvd** is compiled from the pinned upstream release tarball (the `RADVD_VERSION` build argument, tracked by Renovate against upstream tags) and verified against a pinned SHA256 before extraction. The shipped daemon version is explicit and updates by pull request instead of floating with the Alpine package index.
- **The Alpine base image** is pinned by SHA digest. The base userland around the radvd binary (musl, busybox, and friends) floats forward at image rebuild time (`apk upgrade` in the Dockerfile), and scheduled rebuilds bound how stale a published image can get.

| Dependency | Source                                                                  |
| ---------- | ----------------------------------------------------------------------- |
| alpine     | [Docker Hub](https://hub.docker.com/_/alpine)                           |
| radvd      | [GitHub](https://github.com/radvd-project/radvd) (pinned source build)  |

**Major-version updates:** a breaking radvd release arrives as a Renovate PR bumping `RADVD_VERSION` and ships as a new major version of this image. Before upgrading, review the [upstream changelog](https://github.com/radvd-project/radvd/blob/master/CHANGES) for `radvd.conf` syntax changes; the mounted config is the only interface that can break.

## Credits

This project packages [radvd](https://radvd.litech.org/) ([source on GitHub](https://github.com/radvd-project/radvd)) into a container image. radvd carries its own BSD-style permissive license (see its `COPYRIGHT` file). All credit for the daemon goes to the upstream maintainers; radvd has been the canonical Linux IPv6 RA daemon since 1996.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).
