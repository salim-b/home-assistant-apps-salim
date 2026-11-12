#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"

"""Fixture adapter for the hd-idle lab: configures the smoke-test drives
(kernel names from LAB_SPINDOWN_DRIVES, e.g. "sda,sdb") on a short idle so the daemon
exercises its natural spindown path within the check window. Bare kernel names pass the app's
device resolution unchanged (rootfs/etc/cont-init.d/config.sh); only these drives are listed,
so no other disk of the lab host is ever touched."""

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
    ## The FIRST drive carries a per-drive override (disable_drive_pm=no) so the override is
    ## exercised end to end: pm-flag 0 in the drives file, hd-idle-pmfix logs the skip (asserted
    ## by the lab hook); all other drives inherit the global default (pm-flag 1).
    if entries:
        entries[0]["disable_drive_pm"] = "no"
    adapted["disks"] = entries
    return adapted
