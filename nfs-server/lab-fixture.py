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
    # substituted below by the harness (subnet unknown to this file)
    return adapted
