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
    # Second share on the hotplug path (/media): the nfsd-watch runtime check exercises the mirror refresh with an
    # in-container unplug/replug cycle of a "drive" mounted there (the hook mounts/unmounts it).
    adapted["shares"].append(
        {"path": "/media/usb0", "network": "LABNETWORK", "options": "rw,anonuid=1000,anongid=1000,no_subtree_check"}
    )
    # Short lease: keeps the hook's client-recovery check fast (the client's
    # state-manager renewal/recovery cycle fires at ~lease/3 intervals; with
    # the schema-default 300 s lease it would need ~2 min per run) and caps
    # the watcher-cycle client stalls: every kernel-server restart enters a
    # grace period of lease_time during which client state ops (the check
    # client's NFSv4 OPEN) are delayed until grace ends - with the old 90 s
    # lease each watcher phase stalled ~90 s on top of the poll interval.
    adapted["lease_time"] = 15
    # substituted below by the harness (subnet unknown to this file)
    return adapted
