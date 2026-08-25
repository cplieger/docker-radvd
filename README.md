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

- **Validates HA-related directives** (`IgnoreIfMissing on`, `AdvRASrcAddress`) in the mounted `radvd.conf`: warns at startup if they are missing, and also when `AdvRASrcAddress` is set to a non-link-local (global/ULA) address that RFC 4861 requires hosts to silently discard
- **Creates `/run/radvd`** (radvd refuses to start without it)
- **Drops privileges**: radvd opens its raw socket as root, then runs as the unprivileged `radvd` user (`-u radvd`) for the rest of its lifetime
- **Supervises radvd**: turns `SIGHUP` into a clean config reload, forwards `SIGTERM` for graceful shutdown, and propagates an unexpected radvd exit to Docker's restart policy (see [Reloading](#reloading-configuration))
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
3. **`IgnoreIfMissing on`**: radvd tolerates the source address being absent on the BACKUP node (stays running, just doesn't emit RAs)

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

The entrypoint warns at startup if either directive is missing (and also if `AdvRASrcAddress` is set to a non-link-local address, the classic mistake above), so you find out before clients do. To see whether a node is actually emitting, the image ships upstream's own RA decoder: `docker exec radvd radvdump` on the peer node shows whether the BACKUP is emitting while the MASTER holds the link-local, which is the failure this pattern exists to prevent. See [docker-keepalived](https://github.com/cplieger/docker-keepalived) for the sibling container.

Background reading: [Firstyear's blog post on HA radvd on Linux](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/) explains the pattern in detail.

## Reloading configuration

Reload after editing the mounted config with a `SIGHUP`:

```bash
docker kill -s HUP radvd
```

The entrypoint restarts the daemon so it re-reads the config; `docker restart radvd` works too. On reload it also re-runs the HA-directive checks and re-emits any warnings for the (possibly edited) config, so a misconfiguration introduced by an edit shows up in `docker logs` at reload time rather than only at the next full restart. This supervise-and-restart design (rather than `exec`-ing radvd) is what makes reload work regardless of the config file's ownership; see [CONTRIBUTING](CONTRIBUTING.md) for the rationale.

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
| `NET_ADMIN` | Not needed for Router-Advertisement emission, and inert in a default container: Docker mounts `/proc/sys` read-only in every unprivileged container, so the writes radvd makes for kernel-applied interface-parameter directives (`AdvLinkMTU`, `AdvCurHopLimit`, `AdvReachableTime`, `AdvRetransTimer`) to `/proc/sys/net/ipv6/{conf,neigh}/*` fail whether the capability is granted or not. It becomes meaningful only if you make `/proc/sys` writable yourself (`read_only: true` is a different thing — it governs the container's own rootfs). **For pure SLAAC Router-Advertisement emission, keep only `NET_RAW`.** |

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
  documented signal paths fail silently: `docker stop` leaves radvd running while
  PID 1 exits 0, so the final zero-lifetime Router Advertisement is never sent and
  LAN hosts keep this node as their default router until the advertised lifetime
  expires; and `docker kill -s HUP` starts a second radvd that dies on the
  pid-file lock.

### Networking

| Setting        | Value                 | Reason                                                                                      |
| -------------- | --------------------- | ------------------------------------------------------------------------------------------- |
| `network_mode` | `host` (or `macvlan`) | RAs are emitted via ICMPv6 on a real LAN interface; container networking would isolate them |

## Healthcheck

The built-in healthcheck runs `pidof radvd` every 30s (5s timeout, 3 retries, 15s start period), so a container whose daemon is up reports `healthy`. It is a liveness probe only, and it is not what reacts to a crash: when radvd dies the supervising entrypoint propagates the exit and the container stops within a second, so a crash is handled by your `restart` policy rather than by the container ageing into `unhealthy`.

Neither the probe nor that exit propagation covers "RAs aren't being emitted because the source address is missing" (that's the HA case where radvd intentionally stays running but silent). The image ships upstream's own RA decoder, `radvdump`, so `docker exec radvd radvdump` is a first look at what is on the wire — run it on the peer node to confirm the BACKUP is staying silent; whether it sees this container's own RAs depends on multicast loopback. For end-to-end verification, run an off-host probe that listens for RAs on the LAN segment:

```bash
# On any IPv6 host on the LAN:
sudo rdisc6 eth0
```

If you see an RA from your radvd source address within a few seconds, it's working.

## Alerting

radvd has no metrics endpoint; its operational state is in its logs. Ship the
container's logs (stdout and stderr) to Loki (Grafana Alloy's Docker log
discovery does this with no configuration) and evaluate this rule with
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
            |~ `exiting, failed to read config file|exiting, permissions on conf_file invalid|does not exist or is not set up properly \(setup_iface=|unable to drop root privileges|invalid RADVD_DEBUG_LEVEL|radvd.conf exists but is not readable|radvd.conf is not a regular file|failed to create radvd PID directory` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "radvd rejected its config"
          description: >
            radvd logged a config parse or activation failure. radvd exits on
            this error and the supervising entrypoint propagates the exit, so
            the container crash-loops and IPv6 RA emission stops until the
            config is fixed. This applies whether the bad config is present at
            startup or introduced by a later edit and reload, since a reload
            restarts radvd and re-validates the config. Check your radvd.conf.
            The pattern also matches the entrypoint's own fatal startup errors
            (an invalid RADVD_DEBUG_LEVEL, an unreadable radvd.conf, a
            radvd.conf that is not a regular file, a failed /run/radvd
            creation), which crash-loop the container the same way before radvd
            ever starts. One alternative is not a config fault at all: radvd's
            `unable to drop root privileges` means the container was started
            without the SETUID and SETGID capabilities, so the entrypoint's
            `-u radvd` cannot take effect (see the hardened profile above). It
            crash-loops identically.
```

Every pattern above is a string radvd 2.21 or the entrypoint actually emits,
checked against upstream's `radvd.c`. Note that `properly \(setup_iface=` is
anchored on the opening parenthesis so it matches only the fatal form; the
`ignoring the interface (setup_iface=` warning that radvd logs when
`IgnoreIfMissing on` is set is a normal HA-backup state, not an alert.

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
