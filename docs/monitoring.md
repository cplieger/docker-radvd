# Monitoring and alerts

This page covers what radvd and the entrypoint log, how to check what reaches the LAN, and the alert rules. It is for operators who watch the container from Loki and Alertmanager.

## What it logs

radvd has no metrics endpoint, and its state is in its logs. The entrypoint writes structured `level=... msg="..."` lines to standard error, and radvd writes its own lines there unchanged. `docker logs radvd` shows both.

At the default `RADVD_DEBUG_LEVEL=0`, radvd logs `<iface> received RS or RA on <iface> but <iface> is not ready and setup_iface failed` whenever a solicitation or advertisement arrives on an interface it never finished bringing up. That is the expected steady state on an HA BACKUP node, where the MASTER's own advertisements trigger it. On a single node it means radvd is not advertising. There, router solicitations from LAN hosts raise the line, but only when this node advertises a default route and the host forwards IPv6. Nothing in the line tells those cases apart, which is why no rule below matches it. Set `RADVD_DEBUG_LEVEL=5` for the cause, `no configured AdvRASrcAddress present, skipping send`.

When radvd sets an interface up with `IgnoreIfMissing on` and the interface is missing, it logs `ignoring the interface (setup_iface=...)`. That is a normal HA BACKUP state, not an alert, and radvd logs it at debug level 4, so at level 0 it does not appear at all. It carries no `not found:` line either, because radvd prints that only when the device is absent.

## Checking what reaches the LAN

The image ships radvd's own advertisement decoder. `docker exec radvd radvdump` reads the advertisements that other routers put on the segment, so run it on the peer node to confirm the BACKUP stays silent. It does not show this container's own advertisements. radvd turns off IPv6 multicast loopback on the socket it sends from, so the kernel never hands them back to a local listener. On a single node `radvdump` therefore stays empty however well radvd works.

For this node's own output, run a probe that listens on the LAN segment from another host:

```bash
# On any IPv6 host on the LAN:
sudo rdisc6 eth0
```

An advertisement from your radvd source address within a few seconds means it works.

## Alerting

Load the rules in [`alerts/logql.yaml`](../alerts/logql.yaml) into Loki's ruler, as [Loading an app's alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-an-apps-alert-rules) shows. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `RadvdConfigError` | radvd or the entrypoint rejects the config or a reload, or a peer advertises from a non-link-local address | warning |
| `RadvdAdvertisementsUnverified` | the entrypoint cannot read the mounted `radvd.conf`, so nothing confirms advertisements are sent | warning |
| `RadvdForwardingDisabled` | radvd advertises a default route while IPv6 forwarding is off on the host | warning |
| `RadvdSupervisorFault` | the entrypoint cannot stop radvd, or radvd exits unexpectedly | warning |

radvd's lines arrive only on a config error or an event, with no periodic heartbeat, so the rules are fault rules only. The healthcheck covers a dead process.

Every pattern is a string radvd or the entrypoint emits, checked against radvd's source at the pinned version. `properly \(setup_iface=` is anchored on the opening parenthesis so it matches only the fatal form, not the normal `ignoring the interface (setup_iface=` form above. The parameter-bound fragments are radvd's wording at the pinned version, so a reword in a later release narrows a rule silently. That costs a missed alert, never a false one.

### RadvdConfigError

When the fault is present at startup, radvd exits and the entrypoint propagates the exit. Router advertisements stop until the config is fixed. A `docker restart` starts again from the same file, so the container restarts in a loop.

When a later edit arrives through a SIGHUP reload, the entrypoint checks the file first and refuses the reload. The running radvd keeps its last good config and keeps advertising. Each refusal logs `SIGHUP reload refused`. For all but one cause that is a rejected edit to fix, not an outage. The remaining cause is a TERM to radvd whose delivery the entrypoint could not confirm, usually in a container without the KILL capability.

The pattern also matches other faults that are not a radvd.conf parse error:

- The entrypoint's own fatal startup errors, an invalid `RADVD_DEBUG_LEVEL` and a radvd.conf that is not a regular file. Both stop the container before radvd starts.
- `unable to drop root privileges`, which means the container lacks the SETUID and SETGID capabilities.
- A peer on this segment that sends an advertisement from a non-link-local address. Every host discards those, and radvd names the sender and keeps running. Fix the sending node's `AdvRASrcAddress`.

Two groups pass the reload check because radvd tests them only after parsing. One is the interface's presence. The other is the parameter bounds, such as the interval bounds, `AdvDefaultLifetime` and MTU. With `IgnoreIfMissing off` the container restarts in a loop. With it on, which is radvd's default, radvd stays running and healthy. This alert is then the only sign that the segment has no advertisement sender, and the `not found:` alternative names that case.

### RadvdAdvertisementsUnverified

The entrypoint reads the mounted config within a 5s bound. This alert fires when that read times out or fails outright. radvd then either runs or exits on the same file. When it runs, `pidof radvd` reports healthy, although radvd's own open of the same file has no bound. When it exits, `RadvdConfigError` fires beside this warning and the container restarts in a loop. Check what reaches the LAN with `rdisc6`.

### RadvdForwardingDisabled

radvd reads `/proc/sys/net/ipv6/conf/all/forwarding` and warns when the value is neither 1 nor 2. It also warns when a per-interface forwarding value is below 1. It keeps advertising this node with its configured `AdvDefaultLifetime`, so LAN hosts can install a default route through a kernel that will not forward their traffic. `pidof radvd` reports healthy throughout. Fix the sysctl on the host. Under host networking, compose cannot set it.

radvd logs the global warning once per process, so this alert clears after the window even if the state persists. It logs the per-interface warning each time it sets an interface up, at startup, on reload and on a netlink change event. So neither line guarantees a firing alert. A node that sets `AdvDefaultLifetime 0` to advertise prefixes only matches this rule legitimately. Confirm with `rdisc6` and the host sysctl rather than from the alert alone.

### RadvdSupervisorFault

The entrypoint reports a fault of its own, for one of two causes.

A refused TERM means the container lacks the KILL capability. `docker stop` then leaves radvd running while the entrypoint exits 0. The final zero-lifetime advertisement is never sent, and LAN hosts keep this node as their default router until the advertised lifetime expires. The container's own exit status is 0, so no restart policy reports this. Grant KILL.

An exit propagation means radvd is gone and advertisements have stopped. The `status` field carries radvd's own exit status. Your restart policy decides whether the container returns, so a repeating record is a restart loop. For a config fault, radvd's own line matches `RadvdConfigError` too, and that is the one to read first. This rule covers an exit whose cause radvd words differently, such as an out-of-memory kill reported as `status="137"`.

### Adapting the rules

Thresholds and the `severity` label are starting points. The `container` selector and the `hostname` grouping label depend on your log collector. Alloy's Docker discovery provides `container`, while `hostname` comes from your own labeling, so adjust or drop `sum by (hostname)` to match. Route by whatever labels your Alertmanager uses.
