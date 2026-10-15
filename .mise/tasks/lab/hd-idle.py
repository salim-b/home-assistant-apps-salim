#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"
"""Fixture adapter for the hd-idle lab: opt-in mode with the lab's smoke-test
drives (kernel names from LAB_SPINDOWN_DRIVES, e.g. "sda,sdb") on a short
idle so the daemon exercises its natural spindown path within the check
window. Bare kernel names pass through the app's device resolution
unchanged (see rootfs/etc/cont-init.d/config.sh). Opt-in mode guarantees no
other disk of the lab host is ever touched."""

def lab_adapt_fixture(options):
    import os

    drives = [
        d
        for d in os.environ.get("LAB_SPINDOWN_DRIVES", "").replace(",", " ").split()
        if d
    ]
    adapted = dict(options)
    adapted["mode"] = "opt-in"
    adapted["disks"] = [
        {"device": d, "idle": 30, "command_type": "scsi", "power_condition": 0}
        for d in drives
    ]
    return adapted
