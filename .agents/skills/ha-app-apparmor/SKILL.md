---
name: ha-app-apparmor
description: How to author, update, and debug custom AppArmor profiles (apparmor.txt) for Home Assistant apps on HAOS,
  including the no-audit-log denial forensics procedure. Use when creating or changing an app's profile or diagnosing
  on-device permission denials.
---

# AppArmor profiles for HA apps

## Mechanics (facts — root `KNOWLEDGE.md`, section "AppArmor: mediation and profile mechanics")

Capabilities are mediated (list every one the binaries need — a profile without explicit capability rules denies them
all at the LSM hook); network mediation is opt-in per class ("no rules" is not "no networking"); ioctls are mediated via
the file's r/w permission only; mount rules use `options=` (no `flags=`), and `fstype=` matches new mounts only (bind
rules are conditioned on `options=(bind)`); mounting a filesystem whose module is unloaded triggers kernel-context
module autoload outside the label (no `sys_module`, no modprobe, no `/lib/modules`, no `kernel_modules: true` needed).
Read that section before writing rules.

## Authoring

- Exactly one top-level (non-indented) `profile` declaration; nested sub-profiles must be indented. The supervisor
  renames the profile to the installed slug on install/update — the declared name is arbitrary.
- HA convention: a `file,` blanket. Tightening file rules is impractical without audit logs; the profile's confinement
  value sits in the non-file classes (network, capability, mount). Rationale: root `KNOWLEDGE.md`, AppArmor section.
- Enumerate capabilities from what the binaries actually do (strace, errno evidence). Sub-profile subtlety:
  self-capability-management (`prctl(PR_CAPBSET_DROP)`, `capset(2)`) needs `capability setpcap,` — daemons that prune
  their whole bounding set at startup exit in a restart loop without it.
- Sub-profiles that need no sockets: `deny network,` (any network rule enables mediation for the class, so this denies
  everything).

## Iterating on denials (no audit logs on HAOS)

HAOS produces no AppArmor audit messages in the host journal (`ha host logs` carries kernel lines but nothing
apparmor/DENIED), so complain-mode iteration is impossible. Diagnose from:

- busybox `mount` errno text: `mounting SRC on DST failed: Permission denied` = EACCES = mount-rule denial;
  `permission denied (are you root?)` = EPERM = capability denial.
- In-container ground truth: `cat /proc/self/attr/current` (profile plus mode) and `grep CapEff /proc/self/status`.
- The lab has NO AppArmor enforcement — it cannot catch capability or mount denials; only device testing can.

## Shipping profile changes

Profile changes require a `config.yaml` version bump: the supervisor re-installs and reloads profiles on app update
only; `rebuild` does not re-apply them. Release rules: skill `ha-app-workflow`.

## Device verification

Verify functionally — run the workload under enforcement and assert zero error/denial lines in the app log and dmesg —
not via audit logs. Worked per-app examples: `hd-idle/KNOWLEDGE.md` (SG_IO privileges section) and
`nfs-server/KNOWLEDGE.md` (AppArmor profile section).
