# Configuration

This page covers every setting the image reads beyond the compose example, and the host settings radvd depends on. It is for operators who need more than the README's tables.

## Settings

| Variable | Description | Default |
| --- | --- | --- |
| `RADVD_DEBUG_LEVEL` | radvd's `--debug` level, `0` to `5`. `0` still logs every warning and error. Any other value stops the container at startup | `0` |

Everything else about the daemon comes from the mounted `radvd.conf`. This variable only controls how much radvd logs.

- At `0`, radvd still logs its startup banner and every warning and error.
- `1` adds a config `syntax ok` confirmation, plus a `polling for ...` line on every wakeup that is noisy under `docker logs`.
- `2` adds radvd's own `AdvSendAdvert is off for <iface>` line. radvd prints it only for an interface it has brought up, so an HA BACKUP node never logs it at any level.
- Higher levels log progressively more.

An invalid value stops the container at startup with `invalid RADVD_DEBUG_LEVEL; expected an integer 0-5`, rather than running at a verbosity you did not ask for.

## The config file

| Mount | Description |
| --- | --- |
| `/etc/radvd` | Folder holding your `radvd.conf`. Mount it read-only |

The entrypoint reads `/etc/radvd/radvd.conf`. It refuses a path that is not a regular file, at startup and on every reload, with `radvd.conf is not a regular file`. When it cannot read the file within 5 seconds, or the read fails, it logs `radvd.conf could not be read; radvd may block or fail on the same node` and leaves the rest to radvd. Everything inside the file is radvd's to check, and radvd's own messages pass through unchanged.

At `RADVD_DEBUG_LEVEL=0`, radvd refuses to start when `radvd.conf` is writable by others, or writable by the `radvd` user or its group, and logs `exiting, permissions on conf_file invalid`. At level 1 and above it logs `Insecure file permissions, but continuing anyway` and starts. A root-owned file with mode `644` passes either way.

## Capabilities

| Capability | Why it is needed |
| --- | --- |
| `NET_RAW` | Required. Opens the raw ICMPv6 socket radvd sends advertisements on. Without it radvd exits at startup |
| `NET_ADMIN` | Not needed. Docker keeps `/proc/sys` read-only, so radvd's interface parameter writes fail either way |

Without `NET_RAW`, radvd exits at startup with `open_icmpv6_socket: Operation not permitted`.

`NET_ADMIN` is not needed for sending advertisements, and it does nothing in a default container. Docker mounts `/proc/sys` read-only in every unprivileged container. So the writes radvd makes to `/proc/sys/net/ipv6/{conf,neigh}/*` for the kernel-applied directives `AdvLinkMTU`, `AdvCurHopLimit`, `AdvReachableTime` and `AdvRetransTimer` fail whether the capability is granted or not. It matters only if you make `/proc/sys` writable yourself. `read_only: true` is a different setting, which governs the container's own root filesystem.

Under `cap_drop: ALL`, three more capabilities are required. [Security](security.md#hardened-profile) lists them.

## Networking

| Setting | Value | Reason |
| --- | --- | --- |
| `network_mode` | `host` (or `macvlan`) | Advertisements go out on a real LAN interface, which a container network would isolate |
| `net.ipv6.conf.all.forwarding` | `1` (or `2`) on the host, when this node advertises a default route | Compose cannot set it under host networking. A config with `AdvDefaultLifetime 0` advertises no default route and needs no forwarding |

With a non-zero `AdvDefaultLifetime`, radvd advertises this node as a default router whatever the sysctl says. With forwarding off, hosts then install a default route through a node that drops their off-segment traffic. radvd logs `IPv6 forwarding seems to be disabled, but continuing anyway` once at startup either way, with a per-interface variant beside it.
