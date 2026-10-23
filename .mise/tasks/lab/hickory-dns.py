#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"

"""Fixture adapter for the hickory-dns lab: add one static entry so the runtime
check can probe an authoritative leaf-zone answer (the default options serve
none)."""

def lab_adapt_fixture(options):
    options["static_entries"] = [{"hostname": "lab-probe.home.arpa", "ip": "192.0.2.1"}]
    return options
