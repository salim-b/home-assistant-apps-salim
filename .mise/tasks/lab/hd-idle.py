#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"

"""Fixture adapter for the hd-idle lab: the lab's smoke-test drives (kernel names
from LAB_SPINDOWN_DRIVES, e.g. "sda,sdb") on a short idle so the daemon
exercises its natural spindown path within the check window. Bare kernel names
pass through the app's device resolution unchanged (see
rootfs/etc/cont-init.d/config.sh). Listing only these drives guarantees no
other disk of the lab host is ever touched."""

def lab_adapt_fixture(options):
    import os

    drives = [
        d
        for d in os.environ.get("LAB_SPINDOWN_DRIVES", "").replace(",", " ").split()
        if d
    ]
    adapted = dict(options)
    entries = [
        {"device": d, "idle": 30, "command_type": "scsi", "power_condition": 0}
        for d in drives
    ]
    ## The FIRST drive carries an explicit per-drive power-management
    ## override (disable_drive_pm=no) so the lab exercises the override end
    ## to end: genargs emits pm-flag 0 for it and hd-idle-pmfix logs the
    ## skip at boot (both asserted by the lab hook). All other drives
    ## inherit the global default (pm-flag 1).
    if entries:
        entries[0]["disable_drive_pm"] = "no"
    adapted["disks"] = entries
    return adapted
