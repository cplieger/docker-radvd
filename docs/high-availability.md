# High availability

This page shows how to run radvd on two or more nodes so that only one of them advertises at a time. It is for admins who pair docker-radvd with keepalived.

## Why both nodes advertise by default

If you run radvd on two or more nodes, both emit router advertisements. Clients pick whichever they hear last, or alternate, which breaks default-route selection.

## The pattern

1. Let keepalived manage a floating link-local address. Only the MASTER node holds it at any moment. [docker-keepalived](https://github.com/cplieger/docker-keepalived) is the sibling container for this.
2. Set `AdvRASrcAddress` in `radvd.conf` to that link-local address. It must be link-local. [RFC 4861 §6.1.2](https://www.rfc-editor.org/rfc/rfc4861#section-6.1.2) requires an advertisement's source to be a link-local address, and hosts silently discard any advertisement sent from a global address. Pointing it at a global service address is the classic mistake. radvd emits, `tcpdump` shows the advertisements, and yet no host ever autoconfigures.
3. Keep `IgnoreIfMissing on`. radvd then tolerates the source address being absent on the BACKUP node. It stays running and sends nothing. This is radvd's own default, so setting it explicitly is worth doing rather than required. An explicit `IgnoreIfMissing off` is what breaks a BACKUP node.

Both radvd processes run all the time, but only the MASTER node advertises, because only it holds the link-local address. On failover, keepalived moves the address, and the new MASTER's radvd starts advertising within seconds.

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

Add `AdvDefaultLifetime 0;` whenever another device is the real default gateway. Otherwise radvd advertises this node as a default router.

## Checking it

The node that makes the global-address mistake reports nothing. radvd matches `AdvRASrcAddress` against the interface's addresses without testing whether the match is link-local. Any node on the segment that receives such an advertisement logs `received icmpv6 RA packet with non-linklocal source address` and names the sender. So the peer's own `docker logs` is the first place to look.

The image ships radvd's own advertisement decoder, `radvdump`. Run `docker exec radvd radvdump` on the peer node to see whether the BACKUP sends while the MASTER holds the address. `rdisc6` from a LAN host shows what reaches the wire. A node's own `radvdump` never shows its own advertisements, as [Monitoring](monitoring.md#checking-what-reaches-the-lan) explains.

On a BACKUP node, radvd logs `<iface> received RS or RA on <iface> but <iface> is not ready and setup_iface failed` whenever the MASTER's advertisements arrive. That is the expected steady state there. Set `RADVD_DEBUG_LEVEL=5` to see the cause, `no configured AdvRASrcAddress present, skipping send`.

[Firstyear's post on HA radvd on Linux](https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/) explains the pattern in detail.
