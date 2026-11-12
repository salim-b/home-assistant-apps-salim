# fmt: off
#MISE hide=true
#MISE description="⚠️ internal helper script (fixture adapter, sourced by the lab task)"
# fmt: on

"""Fixture adapter for the hd-idle lab: drive the daemon's natural spindown path.

Configures the smoke-test drives (kernel names from LAB_SPINDOWN_DRIVES, e.g. "sda,sdb") on a
short idle so the daemon exercises its natural spindown path within the check window. Bare
kernel names pass the app's device resolution unchanged (rootfs/etc/cont-init.d/config.sh);
only these drives are listed, so no other disk of the lab host is ever touched.
"""


def lab_adapt_fixture(options: dict[str, object]) -> dict[str, object]:
    """Adapt the lab options: list the smoke-test drives, first one with keep_drive_pm=true.

    The drives come from LAB_SPINDOWN_DRIVES (comma-separated kernel names); the first drive
    opts out of the drive-PM treatment so the pm-flag skip path is exercised end to end.
    """
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
    ## The FIRST drive carries keep_drive_pm=true so the opt-out is exercised end to end: pm-flag 0 in
    ## the drives file, hd-idle-pmfix logs the skip (asserted by the lab hook); all other drives carry
    ## no key at all – absent = the treatment applies (pm-flag 1, the default).
    if entries:
        entries[0]["keep_drive_pm"] = True
    adapted["disks"] = entries
    return adapted
