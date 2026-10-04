# docker-radvd

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-radvd/badges/size.json)](https://github.com/cplieger/docker-radvd/pkgs/container/docker-radvd) [![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)](https://github.com/cplieger/docker-radvd/pkgs/container/docker-radvd) [![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)](https://github.com/cplieger/docker-radvd/blob/main/Dockerfile) [![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-radvd/releases)

<!-- hub-overview BEGIN -->
docker-radvd runs [radvd](https://radvd.litech.org/), the Linux IPv6 router advertisement daemon, in a container, so the hosts on your LAN configure their IPv6 addresses with SLAAC. You write the `radvd.conf`. The image does not generate one from settings.

## What it does

docker-radvd gives the IPv6 hosts on your network their prefix, default route and DNS servers from a `radvd.conf` you control.

- Sends router advertisements with radvd built from a pinned release.
- Checks a changed `radvd.conf` before an in-place reload, so a malformed edit leaves the last good config running.
- Runs radvd's worker as an unprivileged user once its socket is open.
- Reports config errors in `docker logs`, with four Loki alert rules ready to load.
- Pairs with keepalived so only the node holding a shared address advertises.

## Who it is for

docker-radvd is built for admins who already write radvd configurations and want radvd in a container, on one node or on two nodes with keepalived for failover.

You need a Linux host with Docker on the LAN segment, on `amd64` or `arm64`. The container uses host networking and the `NET_RAW` capability.

Three other options suit other setups:

- Consider your distribution's radvd package to run radvd on the host itself.
- Consider [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) if it already serves DNS or DHCP on your LAN. Its router advertisement subsystem gives IPv6 hosts basic autoconfiguration.
- Consider [CoreRAD](https://github.com/mdlayher/corerad) if you want an advertisement daemon with Prometheus metrics and a sample Grafana dashboard.

docker-radvd is free software under the Apache-2.0 license. radvd is under a BSD-style license.
<!-- hub-overview END -->

## Quick start

The image is on GitHub Container Registry and Docker Hub, for `amd64` and `arm64`. This is the [`compose.yaml`](compose.yaml) in this repository. Besides `latest`, each release is tagged with its full, minor and major version, such as `v3.1.1`, `v3.1` and `v3`. These are the image's own version numbers, separate from the radvd version inside it.

```yaml
services:
  radvd:
    image: ghcr.io/cplieger/docker-radvd:latest
    container_name: radvd
    restart: unless-stopped

    # Advertisements go out on a real LAN interface, so radvd needs host networking.
    # If this host is the default router, set net.ipv6.conf.all.forwarding=1 on the host first.
    network_mode: host
    cap_add:
      - NET_RAW  # required: the raw ICMPv6 socket radvd sends advertisements on

    # Put your radvd.conf in ./radvd before the first start, or radvd exits.
    volumes:
      - "./radvd:/etc/radvd:ro"
```

1. In the folder that holds `compose.yaml`, create a `radvd` folder.
2. Save this as `radvd/radvd.conf`.

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

3. In `radvd.conf`, replace `eth0` with the host's LAN interface, `2001:db8:1::/64` with your prefix and `2001:db8:1::1` with your DNS server.
4. If another device is the default router, add `AdvDefaultLifetime 0;` inside the `interface` block.
5. If this host is the default router, turn on IPv6 forwarding on the host with `sudo sysctl -w net.ipv6.conf.all.forwarding=1`.
6. Run `docker compose up -d`.

Run `docker logs radvd`. You should see `starting radvd` and radvd's own `version ... started` line, and the container stays up. If you see `exiting, failed to read config file`, radvd rejected `radvd.conf`, and its line before that names the problem. Then run `sudo rdisc6 eth0` on another IPv6 host on the LAN. An advertisement from this host within a few seconds means it works.

## High availability with keepalived

On two nodes, both radvd instances advertise by default, and hosts pick whichever router they heard last. To have only one node advertise, let [docker-keepalived](https://github.com/cplieger/docker-keepalived) move a floating link-local address to the MASTER node, and point `AdvRASrcAddress` in `radvd.conf` at it. The address must be link-local, because hosts silently discard an advertisement sent from a global address. Keep `IgnoreIfMissing` on, its default, so radvd stays running and silent on the BACKUP node. On failover, the new MASTER starts advertising within seconds. [High availability](docs/high-availability.md) has the full example and how to check it.

## Reloading configuration

After you edit `radvd.conf`, restart the container:

```bash
docker restart radvd
```

A restart starts radvd again with no check, so a broken edit stops radvd and the container restarts in a loop until you fix it. To have the edit checked first, send the reload signal from inside the container with `docker exec radvd kill -HUP 1`. A malformed edit is then refused, and the running daemon keeps its last good config. A refused edit logs `SIGHUP reload refused`.

`docker kill -s HUP radvd` also reloads with the check. After it, Docker stops applying the restart policy until the next `docker start` or `docker restart`, so prefer `docker restart` where it matters. Neither this image nor the shipped `compose.yaml` sets a `stop_signal`, so this happens whatever signal the kill sends. With a `stop_signal` set, `always` and `on-failure` stay armed for other signals, but `unless-stopped` is disarmed by the kill regardless. [How it works](docs/how-it-works.md#reloading) covers what the check catches and misses.

## Configuration reference

radvd reads every setting from `radvd.conf`. The one environment variable sets how much radvd logs. [Configuration](docs/configuration.md) has the detail of each table.

| Variable | Description | Default |
| --- | --- | --- |
| `RADVD_DEBUG_LEVEL` | radvd's `--debug` level, `0` to `5`. `0` still logs every warning and error. Any other value stops the container at startup | `0` |

| Mount | Description |
| --- | --- |
| `/etc/radvd` | Folder holding your `radvd.conf`. Mount it read-only |

| Capability | Why it is needed |
| --- | --- |
| `NET_RAW` | Required. Opens the raw ICMPv6 socket radvd sends advertisements on. Without it radvd exits at startup |
| `NET_ADMIN` | Not needed. Docker keeps `/proc/sys` read-only, so radvd's interface parameter writes fail either way |

### Networking

| Setting | Value | Reason |
| --- | --- | --- |
| `network_mode` | `host` (or `macvlan`) | Advertisements go out on a real LAN interface, which a container network would isolate |
| `net.ipv6.conf.all.forwarding` | `1` (or `2`) on the host, when this node advertises a default route | Compose cannot set it under host networking. A config with `AdvDefaultLifetime 0` advertises no default route and needs no forwarding |

## Security

radvd opens its raw ICMPv6 socket as root, then runs its worker as the unprivileged `radvd` user, leaving a small root helper beside it. The config mount is read-only. The container needs host networking, so it reaches every interface on the host. It listens on no port. [Security](docs/hardening.md) covers a read-only hardened profile, how to verify the image signature, what the image contains and how it is kept up to date.

## Troubleshooting

The healthcheck runs `pidof radvd` every 30 seconds, so the container is healthy while radvd runs. When radvd exits, the entrypoint passes its exit status on and the container stops within a second, so your `restart` policy handles a crash. The probe does not see a radvd that runs but sends nothing, such as a BACKUP node by design, so check the wire with `rdisc6`.

- `open_icmpv6_socket: Operation not permitted`. The container lacks `NET_RAW`. Add it to `cap_add`.
- `exiting, permissions on conf_file invalid`. `radvd.conf` is writable by others or by the `radvd` user. Run `sudo chown root:root radvd/radvd.conf` and `sudo chmod 644 radvd/radvd.conf`.
- `IPv6 forwarding seems to be disabled, but continuing anyway`. radvd logs this whenever IPv6 forwarding is off on the host. If this node advertises a default route, set the sysctl from step 5. With `AdvDefaultLifetime 0` the line is expected and needs no fix.
- `the TERM could not be delivered to radvd; a graceful stop cannot be confirmed`. The container lacks the `KILL` capability, which a `cap_drop` list such as `ALL` removes. Add it back under `cap_add`.

[Monitoring](docs/monitoring.md#checking-what-reaches-the-lan) shows how to read what radvd sends.

## Monitoring

radvd and the entrypoint log to `docker logs`, and radvd has no metrics endpoint. Four Loki alert rules ship in [`alerts/logql.yaml`](alerts/logql.yaml). [Monitoring and alerts](docs/monitoring.md) lists them and shows how to load them.

## Documentation

- [Configuration](docs/configuration.md) covers debug levels, capabilities, networking and file permissions.
- [High availability](docs/high-availability.md) covers the keepalived pairing and how to check it.
- [How docker-radvd works](docs/how-it-works.md) covers the entrypoint, reloads and the design.
- [Monitoring and alerts](docs/monitoring.md) lists the alert rules and how to check the wire.
- [Security](docs/hardening.md) covers the privilege model, the hardened profile, signatures and what the image contains.

## Credits

This project packages [radvd](https://radvd.litech.org/) into a container image, built from its [source on GitHub](https://github.com/radvd-project/radvd). All credit for the daemon goes to its maintainers. The high-availability pattern follows [Firstyear's post on HA radvd on Linux](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the design rules and the tests, and open an issue first for a larger change.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).

The image carries the license text of every bundled component under `/usr/share/licenses/`. The image packages [radvd](https://github.com/radvd-project/radvd), which carries a BSD-style permissive license.
