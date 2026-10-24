#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"

"""Fixture adapter for the hickory-dns lab: add one static entry so the runtime
check can probe an authoritative leaf-zone answer (the default options serve
none).

The lab harness forwards a generic LAB_FIXTURE_ENV string to the fake-API
container; the `upstreams=<variant>` item selects an upstream-pool variant for
the boot: `upstreams=https` / `upstreams=quic` replace the default pool with a
single hostname-only upstream of that protocol, so the forwarded probe proves
exactly that encrypted transport end-to-end through the real daemon (DoT is
covered by the default pool; the resolve CLI cannot dial DoH/DoQ directly).
Hostname-only upstreams additionally exercise the boot-time name resolution
path (fresh lookup + last-known-good cache) that the default IP-based pool
skips. Run all three after transport-affecting changes:
`LAB_FIXTURE_ENV=upstreams=https mise run lab hickory-dns` (and quic)."""

import os


def lab_adapt_fixture(options):
    options["static_entries"] = [{"hostname": "lab-probe.home.arpa", "ip": "192.0.2.1"}]
    variant = ""
    for item in os.environ.get("LAB_FIXTURE_ENV", "").split():
        if item.startswith("upstreams="):
            variant = item.split("=", 1)[1]
    if variant == "https":
        options["upstreams"] = [{"protocol": "https", "host": "cloudflare-dns.com"}]
    elif variant == "quic":
        options["upstreams"] = [{"protocol": "quic", "host": "dns.adguard-dns.com"}]
    elif variant not in ("", "tls"):
        raise ValueError(f"unknown upstreams lab variant: {variant}")
    return options
