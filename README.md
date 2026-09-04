# docker-radvd

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-radvd/badges/size.json)](https://github.com/cplieger/docker-radvd/pkgs/container/docker-radvd)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13207/badge)](https://www.bestpractices.dev/projects/13207)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-radvd/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-radvd)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-radvd/releases)

<!-- hub-overview BEGIN -->
Run [radvd](https://radvd.litech.org/) (the Linux IPv6 Router Advertisement Daemon) in a container. Bring your own `radvd.conf`.

## What it does

[radvd](https://radvd.litech.org/) emits IPv6 Router Advertisements (RAs) onto the LAN so hosts can do SLAAC (StateLess Address AutoConfiguration): learn the local prefix(es), default router, and DNS. Without an RA emitter on the LAN, IPv6 hosts stay link-local-only and can't route off-segment.

This image is a minimal Alpine wrapper around upstream `radvd`, compiled from the pinned release tarball, plus a small POSIX entrypoint that:

- **Checks the mounted `radvd.conf` node**: the entrypoint refuses a path that is not a regular file at startup or reload. It warns when its bounded node read fails, then leaves the config settings to radvd. A config radvd rejects outright, such as one defining no interface block, is left to radvd: radvd logs its own error and exits, and the entrypoint reports that exit.
- **Creates `/run/radvd`** (radvd refuses to start without it)
- **Drops privileges**: radvd opens its raw socket as root, then runs as the unprivileged `radvd` user (`--username=radvd`) for the rest of its lifetime
- **Supervises radvd**: turns `SIGHUP` into a config reload, refusing the reload and keeping the running daemon when the config would not start; forwards `SIGTERM` for graceful shutdown. A stop that arrives before radvd has started wins immediately and exits 0 without starting it. An unexpected radvd exit propagates to Docker's restart policy. See [Reloading](#reloading-configuration) for the `docker kill` caveat.
- **Logs to stderr** with structured key=value lines, captured by `docker logs`

### Why this design

- **Generic upstream-only**: no env-var-to-config translation, no bundled prefixes; you supply your own `radvd.conf`. The one env var, `RADVD_DEBUG_LEVEL`, tunes radvd's log verbosity only (see [Configuration reference](#configuration-reference))
- **Bind-mount only**: single read-only `:ro` mount of `/etc/radvd`
- **Healthcheck**: `pidof radvd` (CMD form, no shell needed)
- **Multi-arch**: `linux/amd64` and `linux/arm64`
<!-- hub-overview END -->

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

The container making this mistake reports nothing: radvd matches `AdvRASrcAddress`
against the interface's addresses without testing whether the match is link-local.
Any node on the segment that receives the RA logs `received icmpv6 RA packet with
non-linklocal source address` and names the sender, so the peer's own `docker logs`
is the first place to look; `radvdump` on the peer node or `rdisc6` from a LAN host
confirms what reaches the wire. The image ships upstream's own RA decoder, so `docker exec radvd radvdump` on the peer node shows whether the BACKUP is emitting while the MASTER holds the link-local. See [docker-keepalived](https://github.com/cplieger/docker-keepalived) for the sibling container.

Background reading: [Firstyear's blog post on HA radvd on Linux](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/) explains the pattern in detail.

## Reloading configuration

Reload after editing the mounted config:

```bash
docker restart radvd
```

`docker kill -s HUP radvd` reloads too and keeps the container in place, but it
disarms the container's restart policy for the rest of the run (see the `docker
kill` caveat below). This image's crash recovery IS that policy, so prefer `docker
restart` unless you specifically need the container itself left alone. In that
case, run `docker exec radvd kill -HUP 1`. This sends the same reload signal from
inside the container and keeps the restart policy armed because the Docker API
kill call, not the signal, disarms it.

The entrypoint restarts the daemon so it re-reads the config. On reload it checks
the config path again. It exits if the path is no longer a regular file, and it
warns without stopping if it cannot read the node. A config removed after startup
takes the warning path after radvd stops. This supervise-and-restart design (rather
than `exec`-ing radvd) makes reload work regardless of the config file's ownership;
see [CONTRIBUTING](CONTRIBUTING.md) for the rationale.

Because the reload restarts the daemon, the outgoing radvd sends a final
advertisement with Router Lifetime 0 on its way out (`sending stop adverts` in the
log) -- upstream's default `RemoveAdvOnExit`, and something its own in-process
reload does not do. So every accepted reload, and every `docker restart`, briefly
withdraws this node as an IPv6 default router until the replacement's first
advertisement. Where another box is the real gateway and `AdvDefaultLifetime 0` is
set, that is inert. Where this radvd IS the default router, every config reload
drops the default route on SLAAC hosts for that interval.

A successful reload also logs two upstream ERROR-level lines as the old daemon
exits, `Exiting, privsep_read_loop had readn return 0 bytes` and `Exiting,
privsep_read_loop is complete.`. They come from radvd's privileged privsep helper
noticing its worker is gone, they appear on every reload and every graceful stop,
and they are normal.

On the `SIGHUP` route, most bad edits are refused before anything is stopped: the entrypoint config-tests the mounted file first, so the running radvd keeps serving its last good config. Five shapes are refused, each logging `SIGHUP reload refused`: malformed, absent or not a regular file, a check exceeding 5s, permissions radvd calls insecure, and a TERM to radvd whose delivery could not be confirmed. The malformed and insecure-permissions shapes also carry radvd's text. `docker restart` takes none of that gate -- it re-enters startup, so a bad edit exits radvd and crash-loops the container until the config is fixed.

The check is `radvd --configtest … --username=radvd`: radvd's config parser and nothing after it, so anything radvd checks later slips past unchecked: the interface's presence, every bound radvd checks only after the parse (`MinRtrAdvInterval` against 3/4 of `MaxRtrAdvInterval`, `AdvDefaultLifetime`, MTU), and a config replaced between the check and the daemon's own read. The `radvd.conf` permissions are the exception: the configtest runs under the daemon's own `--username=radvd` identity and prints the verdict, so that edit costs a reload, not the emitter. What happens next depends on `IgnoreIfMissing`: `off` exits radvd and the container with it, `on` (the upstream default) leaves radvd running and healthy while that interface emits nothing at all. Either way the evidence is radvd's own error line, such as `MinRtrAdvInterval for eth0 (200.00) must be at least 3.00 but no more than 3/4 of MaxRtrAdvInterval (180.00)`. Verify with `rdisc6` after any config change, and alert on it: the `RadvdConfigError` rule below carries these lines.

One Docker behaviour to plan for: `docker kill` cancels the container's restart manager for the rest of the run — for any signal when the container configures no `stop_signal` (this image and the `compose.yaml` here set none), and for `SIGKILL` or the configured stop signal otherwise. So crash-recreate stays disarmed until the next `docker start` or `docker restart`; prefer `docker restart` where it matters. An operator who does set `stop_signal` keeps `always` and `on-failure` armed for other signals, while `unless-stopped` is disarmed by the kill regardless.

## Configuration reference

### Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `RADVD_DEBUG_LEVEL` | `0` | radvd's `--debug` level, `0`–`5`. At `0` radvd still logs its startup banner and every warning and error; `1` adds a config `syntax ok` confirmation plus a per-wakeup `polling for ...` line that is noisy under `docker logs`; `2` adds radvd's own `AdvSendAdvert is off for <iface>` line, but only for an interface radvd has brought up, so an HA backup never logs it at any level; higher levels are progressively chattier. An invalid value fails startup with a clear error rather than running at an unintended verbosity. |

Everything else about the daemon comes from the mounted `radvd.conf`; this variable
only controls how much radvd logs.

### Volumes

| Mount | Description |
| --- | --- |
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
  `docker stop` leaves radvd running while PID 1 exits 0 (logging
  `a graceful stop cannot be confirmed`), so the final zero-lifetime
  Router Advertisement is never sent and LAN hosts keep this node as their
  default router until the advertised lifetime expires; and
  `docker kill -s HUP` logs `SIGHUP reload refused: TERM delivery to radvd
  could not be confirmed` and leaves radvd serving its last good config. The
  container stays up, which is load-bearing here: that `docker kill` has
  already disarmed the restart policy (see
  [Reloading](#reloading-configuration)).

### Networking

| Setting | Value | Reason |
| --- | --- | --- |
| `network_mode` | `host` (or `macvlan`) | RAs are emitted via ICMPv6 on a real LAN interface; container networking would isolate them |
| `net.ipv6.conf.all.forwarding` | `1` (or `2`) on the host, when this node advertises a default route | With `network_mode: host`, this is the host's sysctl and cannot be set from compose. With a non-zero `AdvDefaultLifetime`, radvd advertises this node as a default router regardless of the sysctl, so with forwarding off hosts install a default route through a node that drops their off-segment traffic. A prefix-only config (`AdvDefaultLifetime 0`) advertises no default route and needs no forwarding here. radvd logs `IPv6 forwarding seems to be disabled, but continuing anyway` once at startup either way, with a per-interface variant beside it. |

## Healthcheck

The built-in healthcheck runs `pidof radvd` every 30s (5s timeout, 3 retries, 15s start period), so a container whose daemon is up reports `healthy`. It is a liveness probe only, and it is not what reacts to a crash: when radvd dies the supervising entrypoint propagates the exit and the container stops within a second, so a crash is handled by your `restart` policy rather than by the container ageing into `unhealthy` — with the `docker kill` caveat in [Reloading](#reloading-configuration).

Neither the probe nor that exit propagation covers "RAs aren't being emitted because the source address is missing" (that's the HA case where radvd intentionally stays running but silent). radvd does report the state passively: whenever an RS or RA arrives on an interface it never finished bringing up, it logs `<iface> received RS or RA on <iface> but <iface> is not ready and setup_iface failed` at the default `RADVD_DEBUG_LEVEL=0` -- the expected steady state on an HA backup, where the MASTER's own RAs trigger it, and lost emission on a single node, where LAN router solicitations raise it if this node advertises a default route and the host therefore forwards -- with nothing in the line separating those cases, which is why no rule below matches it; add `RADVD_DEBUG_LEVEL=5` for the cause (`no configured AdvRASrcAddress present, skipping send`). With IPv6 forwarding off on the host, radvd also runs and reports `healthy`, and an advertisement carrying a non-zero `AdvDefaultLifetime` still names this node as a default router while the kernel forwards nothing; `rdisc6` shows the RA, but only the host's sysctl shows whether the advertised route works. The image ships upstream's own RA decoder, `radvdump`, so `docker exec radvd radvdump` is a first look at what is on the wire — run it on the peer node to confirm the BACKUP is staying silent; whether it sees this container's own RAs depends on multicast loopback. For end-to-end verification, run an off-host probe that listens for RAs on the LAN segment:

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
            |~ `SIGHUP reload refused|exiting, failed to read config file|exiting, permissions on conf_file invalid|not found:|does not exist or is not set up properly \(setup_iface=|unable to drop root privileges|received icmpv6 RA packet with non-linklocal source address|invalid RADVD_DEBUG_LEVEL|radvd.conf is not a regular file|failed to create radvd PID directory|must be at least|must be between|must be zero or between|must not be greater than|must be set with|must be greater than or equal to AdvPreferredLifetime|invalid prefix length|invalid route prefix length` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "radvd rejected its config, or a peer is advertising from an invalid source address"
          description: >
            radvd logged a config parse or activation failure. Check your
            radvd.conf. Present at startup, radvd exits, the supervising
            entrypoint propagates the exit, and IPv6 RA emission stops until
            the config is fixed; `docker restart` re-enters startup, so it
            crash-loops. Introduced by a later edit and a `SIGHUP` reload, the
            entrypoint config-tests first and refuses the reload, so the
            running radvd keeps serving its last good config and keeps
            emitting: every refused reload matches this rule through its own
            `SIGHUP reload refused` line — for all but one arm a rejected edit
            to fix, not an outage. The remaining arm reports that PID 1 could
            not confirm the TERM reached radvd; its `pid` field says which
            state it was in, and the `KILL` bullet under
            [Capabilities](#capabilities) covers the capability case. The
            pattern also matches the entrypoint's own fatal startup errors (an
            invalid RADVD_DEBUG_LEVEL, a radvd.conf that is not a regular file,
            a failed /run/radvd creation), which crash-loop the container before
            radvd ever starts, and radvd's
            `unable to drop root privileges`, which is not a config fault at
            all: the container was started without the SETUID and SETGID
            capabilities, so `--username=radvd` cannot take effect (see the hardened
            profile above). The pattern also matches a peer on this segment
            sourcing an RA from a non-link-local address, which every host
            silently discards: radvd names the sender and keeps running, so this
            is the sending node's `AdvRASrcAddress` to fix, not this one's
            config.
            Two groups pass the reload config test, so for them the
            rejected-edit reading does not hold: the interface's presence, and
            every bound radvd checks only after the parse (interval bounds,
            `AdvDefaultLifetime`, MTU). With `IgnoreIfMissing off` the container
            crash-loops. With it on, the upstream default, radvd stays running
            and healthy while this alert is the only signal that the segment has
            no RA emitter; the `not found:` alternative names it.
      - alert: RadvdAdvertisementsUnverified
        expr: |
          sum by (hostname) (count_over_time(
            {container="radvd"}
            |~ `radvd.conf could not be read` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "the entrypoint could not read the mounted radvd.conf, so RA output is unverified"
          description: >
            PID 1 could not read the mounted config within its 5s bound, or the
            read failed outright. radvd runs and `pidof radvd` reports healthy,
            but radvd's own open of the same node is unbounded. The warning
            predicts that radvd may block or fail on the node while nothing
            verifies that RAs are emitted. Confirm what reaches the LAN with
            `rdisc6`.
      - alert: RadvdForwardingDisabled
        expr: |
          sum by (hostname) (count_over_time(
            {container="radvd"}
            |~ `seems to be disabled` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "radvd is advertising a default route the host does not forward"
          description: >
            radvd read /proc/sys/net/ipv6/conf/all/forwarding and found a value
            that is neither 1 nor 2, or read a per-interface forwarding value
            below 1. It keeps advertising this node with its configured
            AdvDefaultLifetime, so LAN hosts can install a default route through
            a kernel that will not forward their traffic while `pidof radvd`
            reports healthy. Fix the sysctl on the host; `network_mode: host`
            means compose cannot set it. The global warning is emitted once per
            radvd process, so this alert clears after the window even if the
            state persists. The per-interface warning is emitted each time radvd
            sets an interface up: at startup, on reload, and on a netlink change
            event. Neither arm is a firing guarantee, so confirm the state with
            `rdisc6` and the host sysctl rather than from the alert alone.
            A node that deliberately sets
            AdvDefaultLifetime 0 to advertise prefixes only also matches this
            rule legitimately. Use `rdisc6` and the host sysctl to confirm the
            state is gone.
      - alert: RadvdSupervisorFault
        expr: |
          sum by (hostname) (count_over_time(
            {container="radvd"}
            |~ `failed to deliver TERM to radvd|the TERM could not be delivered to radvd|radvd exited; propagating exit for restart policy` [10m]
          )) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "the radvd supervisor could not stop radvd, or radvd exited"
          description: >
            PID 1 reported a fault of its own rather than a config fault, in one of
            two arms. A refused TERM means the container lacks the KILL capability,
            so `docker stop` leaves radvd running while PID 1 exits 0: the final
            zero-lifetime Router Advertisement is never sent and LAN hosts keep
            this node as their default router until the advertised lifetime
            expires. Grant `KILL` (see the bullet under Capabilities); the
            container's own exit status is 0, so no restart policy reports this.
            An exit propagation means radvd is gone and RA emission has stopped;
            the `status` field carries radvd's own exit status and your `restart`
            policy decides whether the container returns, so a repeating record is
            a crash loop. For a config fault radvd's own line matches
            RadvdConfigError too and that is the one to read first; this rule is
            what covers an exit whose cause radvd words differently, such as an
            out-of-memory kill reported as `status="137"`.
```

Every pattern above is a string radvd 2.21 or the entrypoint actually emits,
checked against upstream's own sources. Note that `properly \(setup_iface=` is
anchored on the opening parenthesis so it matches only the fatal form; the
`ignoring the interface (setup_iface=` form radvd emits when
`IgnoreIfMissing on` is set is a normal HA-backup state, not an alert — and
radvd logs it at debug level 4, so at the default `RADVD_DEBUG_LEVEL=0` it does
not appear in `docker logs` at all. It carries no `not found:` line either:
radvd prints that only when the device is absent. The parameter-bound
fragments are upstream's
wording at the pinned version, so a reword upstream narrows the rule silently;
that costs a missed alert, never a false one.

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

| Dependency | Source |
| --- | --- |
| alpine | [Docker Hub](https://hub.docker.com/_/alpine) |
| radvd | [GitHub](https://github.com/radvd-project/radvd) (pinned source build) |

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
