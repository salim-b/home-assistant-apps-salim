#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"
"""Fixture adapter for the nfs-server lab: rewrite the config.yaml options
so the roundtrip works inside the lab network."""

def lab_adapt_fixture(options):
    def walk(value):
        if isinstance(value, dict):
            return {k: "LABNETWORK" if k == "network" else walk(value[k]) for k in value}
        if isinstance(value, list):
            return [walk(v) for v in value]
        return value
    adapted = walk(options)
    # Short lease: keeps the hook's client-recovery check fast (the client's
    # state-manager renewal/recovery cycle fires at ~lease/3 intervals; with
    # the schema-default 300 s lease it would need ~2 min per run).
    adapted["lease_time"] = 90
    # substituted below by the harness (subnet unknown to this file)
    return adapted
