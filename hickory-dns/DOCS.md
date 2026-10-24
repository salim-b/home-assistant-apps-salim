# hickory-dns

## What it does

This app runs a DNS server on your Home Assistant device that answers every LAN device's DNS queries and resolves them
upstream over **encrypted DNS** (DNS-over-TLS, DNS-over-HTTPS or DNS-over-QUIC), with **DNSSEC validation** of the
answers. The point: point your router at the Home Assistant device once, and every device on the network resolves its
DNS through encrypted upstream connections - no per-device configuration, no plaintext UDP:53 queries leaving your home.

Under the hood it wraps the [hickory-dns](https://github.com/hickory-dns/hickory-dns) server binary (from the Alpine
`hickory-dns` package) in forwarding-resolver mode: everything not answered locally is forwarded to the upstream
recursive resolvers you configure.

## Setup

1. Install the app. The defaults work out of the box: Quad9 (9.9.9.9 and 149.112.112.112) over DoT with DNSSEC
   validation on.
2. In your **router's DHCP settings**, set the DNS server handed out to LAN devices to your Home Assistant device's IP
   address. Every (re)connecting device then picks up the new DNS server automatically.
3. Verify from any LAN device: `nslookup example.com <HAOS-IP>` (or `dig @<HAOS-IP> example.com`).

## Requirements and caveats

- **Give the Home Assistant device a static IP** (or a DHCP reservation). The router configuration points at a single
  IP; if it changes, every LAN device loses its DNS server.
- **Do not point the Home Assistant device's own DNS at this app.** The HAOS host needs a working DNS path of its own
  (the supervisor's DNS); pointing the host's resolv.conf at itself would create a resolution loop.
- **Only one program on the host can use port 53.** If you run another DNS app (AdGuard Home, Pi-hole, a dnsmasq app) on
  the same device, it cannot bind port 53 at the same time - pick one.
- **IPv6 networks**: routers advertise DNS servers both via DHCP (IPv4) and via Router Advertisement (RDNSS, IPv6). Make
  sure the IPv6 advertisement points at the HAOS device too (or disable it), otherwise IPv6-capable devices may bypass
  the app with an IPv6 DNS server learned from the router.

## Configuration

The option reference (upstream resolvers, allowed networks, DNSSEC, static entries, debug mode) lives in the app's
settings dialog: [Configuration](/config/app/f8b2d53d_hickory-dns/config) - the per-field descriptions there are
authoritative.

For orientation, each entry in the upstream resolver list is one resolver with its own protocol and address fields:

```yaml
upstreams:
  - protocol: tls
    host: dns.quad9.net
    ip: 9.9.9.9
  - protocol: https
    host: cloudflare-dns.com
  - protocol: quic
    host: dns.adguard-dns.com
    ip: 94.140.14.14
  - protocol: tls
    host: dns.google
    ip: 8.8.8.8
```

## Security notes

- The daemon runs confined in a custom AppArmor profile and never runs as root: an s6 launcher drops to an unprivileged
  user before the daemon starts, and the daemon holds only the single capability the port-53 bind requires
  (`no_new_privs` set).

## Troubleshooting

- **Query test**: from a LAN device, `dig @<HAOS-IP> example.com A` - `NOERROR` with an answer means the app serves;
  `REFUSED` means the client network is not in **Allowed networks**; `SERVFAIL` usually means the upstream connection
  failed (check the app log).
- **Upstream problems**: enable **Debug mode** and restart - every query and upstream interaction is logged. Also test
  the upstream itself from the HAOS host perspective with the packaged query tool:
  `docker exec -it addon_<slug> dns -n 9.9.9.9:53 query quad9.net A` is a plaintext check, while the app itself uses TLS
  (a failed TLS handshake to the upstream appears in the app log on debug).
- **Port conflict**: if the log shows the daemon failing to bind port 53, another app on the host owns the port - see
  the caveat above.
