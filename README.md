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

This image is a minimal Alpine wrapper around the upstream `radvd` package, plus a small POSIX entrypoint that:

- **Validates HA-related directives** (`IgnoreIfMissing on`, `AdvRASrcAddress`) across the mounted config — warns at startup if they are missing, and also warns when `AdvRASrcAddress` is set to a non-link-local (global/ULA) address that RFC 4861 requires hosts to silently discard
- **Creates `/run/radvd`** (radvd refuses to start without it)
- **Drops privileges** — radvd opens its raw socket as root, then runs as the unprivileged `radvd` user (`-u radvd`) for the rest of its lifetime
- **Supervises radvd** — turns `SIGHUP` into a clean config reload, forwards `SIGTERM` for graceful shutdown, and propagates an unexpected radvd exit to Docker's restart policy (see [Reloading](#reloading-configuration))
- **Logs to stderr** with structured key=value lines, captured by `docker logs`

### Why this design

- **Generic upstream-only** — no env-var-to-config translation, no bundled prefixes; you supply your own `radvd.conf`
- **Bind-mount only** — single read-only `:ro` mount of `/etc/radvd`
- **Entrypoint warns on HA misconfig** — running radvd on two nodes without `AdvRASrcAddress` + `IgnoreIfMissing on` makes BOTH nodes emit RAs, which wrecks SLAAC default-route selection on downstream clients. The entrypoint warns at startup (it doesn't fail — single-node operators may legitimately deploy without HA)
- **Healthcheck** — `pidof radvd` (CMD form, no shell needed)
- **Multi-arch** — `linux/amd64` and `linux/arm64`

## Quick start

Available from both `ghcr.io/cplieger/docker-radvd` and `docker.io/cplieger/docker-radvd` — identical images and tags.

```yaml
services:
  radvd:
    image: ghcr.io/cplieger/docker-radvd:latest
    container_name: radvd
    restart: unless-stopped

    # radvd emits RAs onto the LAN — needs host networking + raw / admin caps.
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW

    volumes:
      - ./radvd:/etc/radvd:ro
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

If you run radvd on two or more nodes for HA, both nodes will emit RAs by default — clients pick whichever they hear last, or alternate randomly, breaking default-route selection. The proper pattern is:

1. **Manage a floating link-local with keepalived** — only the MASTER owns it at any moment
2. **`AdvRASrcAddress` in `radvd.conf`** — point it at that **link-local**. It must be link-local: [RFC 4861 §6.1.2](https://www.rfc-editor.org/rfc/rfc4861#section-6.1.2) requires an RA's source to be a link-local address, and hosts silently discard any RA sourced from a global address. Pointing it at a global service VIP is the classic mistake — radvd emits, `tcpdump` shows the RAs, yet no host ever autoconfigures.
3. **`IgnoreIfMissing on`** — radvd tolerates the source address being absent on the BACKUP node (stays running, just doesn't emit RAs)

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

The entrypoint warns at startup if either directive is missing (and also if `AdvRASrcAddress` is set to a non-link-local address, the classic mistake above), so you find out before clients do. See [docker-keepalived](https://github.com/cplieger/docker-keepalived) for the sibling container.

Background reading: [Firstyear's blog post on HA radvd on Linux](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/) explains the pattern in detail.

## Reloading configuration

Reload after editing the mounted config with a `SIGHUP`:

```bash
docker kill -s HUP radvd
```

The entrypoint restarts the daemon so it re-reads the config; `docker restart radvd` works too. On reload it also re-runs the HA-directive checks and re-emits any warnings for the (possibly edited) config, so a misconfiguration introduced by an edit shows up in `docker logs` at reload time rather than only at the next full restart. This supervise-and-restart design (rather than `exec`-ing radvd) is what makes reload work regardless of the config file's ownership; see [CONTRIBUTING](CONTRIBUTING.md) for the rationale.

## Configuration reference

### Volumes

| Mount        | Description                                              |
| ------------ | -------------------------------------------------------- |
| `/etc/radvd` | Directory containing your `radvd.conf`. Mount read-only. |

### Capabilities

| Capability  | Why needed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NET_RAW`   | **Required.** Opens the raw ICMPv6 socket used to send Router Advertisements. Without it radvd exits at startup (`open_icmpv6_socket: Operation not permitted`).                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `NET_ADMIN` | Only needed when one of the kernel-applied interface-parameter directives (`AdvLinkMTU`, `AdvCurHopLimit`, `AdvReachableTime`, `AdvRetransTimer`) is configured AND `/proc/sys` is writable. radvd writes these to `/proc/sys/net/ipv6/{conf,neigh}/*`, which requires `CAP_NET_ADMIN`. Under a read-only `/proc/sys` (e.g. `read_only: true`) those writes are blocked and `NET_ADMIN` has no effect. **If you use radvd for pure SLAAC Router-Advertisement emission only (no kernel-applied interface parameters), you can safely remove `NET_ADMIN` and keep only `NET_RAW`.** |

### Networking

| Setting        | Value                 | Reason                                                                                      |
| -------------- | --------------------- | ------------------------------------------------------------------------------------------- |
| `network_mode` | `host` (or `macvlan`) | RAs are emitted via ICMPv6 on a real LAN interface; container networking would isolate them |

## Healthcheck

The built-in healthcheck verifies the radvd process is running:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof radvd >/dev/null || exit 1
```

This catches "process crashed" but not "RAs aren't being emitted because the source address is missing" (that's the HA case where radvd intentionally stays running but silent). For end-to-end verification, run an off-host probe that listens for RAs on the LAN segment:

```bash
# On any IPv6 host on the LAN:
sudo rdisc6 eth0
```

If you see an RA from your radvd source address within a few seconds, it's working.

## Security

| Tool                                             | Result                          |
| ------------------------------------------------ | ------------------------------- |
| [shellcheck](https://www.shellcheck.net/)        | Clean (entrypoint passes)       |
| [hadolint](https://github.com/hadolint/hadolint) | Clean                           |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected             |
| [trivy](https://trivy.dev/)                      | Inherits Alpine base image scan |

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-radvd:latest \
    --certificate-identity-regexp "https://github.com/cplieger/docker-radvd/.github/workflows/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest; the `radvd` apk package is installed unpinned so it tracks the digest-pinned base.

| Dependency | Source                                                     |
| ---------- | ---------------------------------------------------------- |
| alpine     | [Docker Hub](https://hub.docker.com/_/alpine)              |
| radvd      | [Alpine](https://pkgs.alpinelinux.org/packages?name=radvd) |

## Credits

This project packages [radvd](https://radvd.litech.org/) ([source on GitHub](https://github.com/radvd-project/radvd)) into a container image. All credit for the daemon goes to the upstream maintainers — radvd has been the canonical Linux IPv6 RA daemon since 1996.

The HA pattern is documented in [Firstyear's blog post](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/) and `radvd.conf(5)`.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
