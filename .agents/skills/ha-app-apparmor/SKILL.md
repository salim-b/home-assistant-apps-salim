---
name: ha-app-apparmor
description: How to author, update, and debug custom AppArmor profiles (apparmor.txt) for Home Assistant apps on HAOS,
  including the no-audit-log denial forensics procedure. Use when creating or changing an app's profile or diagnosing
  on-device permission denials.
---

# AppArmor profiles for HA apps

Facts: root `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics"

## Mechanics

Root `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics" is the fact base – capability mediation, opt-in network
mediation, ioctl mediation, mount-rule grammar, kernel-context module autoload. Read it before writing rules.

## Authoring

- Exactly one top-level (non-indented) `profile` declaration; nested sub-profiles indented (supervisor mechanics: root
  `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics").
- HA convention: a `file,` blanket – the confinement value sits in the non-file classes (why: root `KNOWLEDGE.md`
  §"AppArmor: mediation and profile mechanics").
- Enumerate capabilities from what the binaries actually do (strace, errno evidence), including self-capability
  management (`prctl(PR_CAPBSET_DROP)`, `capset(2)` need `capability setpcap,` – facts: root `KNOWLEDGE.md` §"AppArmor:
  mediation and profile mechanics").
- Sub-profiles that need no sockets: `deny network,`.

## Iterating on denials (no audit logs on HAOS)

HAOS produces no AppArmor audit messages in the host journal, so complain-mode iteration is impossible. Diagnose from
the signal catalogue in root `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics" (busybox `mount` errno text;
`/proc/self/attr/current`; `CapEff`). The lab has NO AppArmor enforcement – it cannot catch capability or mount denials;
only device testing can.

## Shipping profile changes

Profile changes require a `config.yaml` version bump (mechanics: root `KNOWLEDGE.md` §"AppArmor: mediation and profile
mechanics"; release rules: skill `ha-app-workflow`).

## Device verification

Verify functionally – run the workload under enforcement and assert zero error/denial lines in the app log and dmesg –
not via audit logs. Worked per-app examples: `hd-idle/KNOWLEDGE.md` (§"SG_IO privileges") and `nfs-server/KNOWLEDGE.md`
(§"AppArmor profile – app-specific grants").
