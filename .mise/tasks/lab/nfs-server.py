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
    # Second share on the hotplug path (/media): the runtime check replugs a "drive" mounted there in-container.
    adapted["shares"].append(
        {"path": "/media/usb0", "network": "LABNETWORK", "options": "rw,anonuid=1000,anongid=1000,no_subtree_check"}
    )
    # Short lease: the client's renewal/recovery cycle fires at ~lease/3 (300 s default => ~2 min per
    # run), and every kernel-server restart stalls client state ops (NFSv4 OPEN) for the grace period
    # (= lease) - a long lease stalls each watcher phase on top of the poll interval.
    adapted["lease_time"] = 15
    # substituted below by the harness (subnet unknown to this file)
    return adapted
