---
name: ha-app-scaffolding
description: How to create a new Home Assistant app in this repository — required files, config schema and translation
  conventions, Dockerfile rules, security-rating engineering, and the apk pin/float decision. Use when adding or
  bootstrapping a new app subdirectory.
---

# Creating a new app

An app is a subdirectory containing: `config.yaml`, `Dockerfile`, `rootfs/` (s6-overlay tree), `translations/en.yaml`,
`DOCS.md`, `CHANGELOG.md`, `README.md`, `KNOWLEDGE.md`, `TODO.md`, `apparmor.txt`, and icons (`icon.svg`, `icon.png`,
`logo.svg`, `logo.png`). See the existing apps as references.

## Steps

1. **config.yaml** — schema reference: the [app configuration
   reference](https://contributors.home-assistant.io/apps/reference/configuration/). Conventions:
   - Option values are USER DATA: existing installs never receive `config.yaml` default changes. New options need
     absent-key handling in app code (`bashio::config '<key>' <default>`), and changing a default is not a behavior
     change for existing users. Facts: root `KNOWLEDGE.md` §"Supervisor: option schema quirks".
   - Grant device access exclusively via device-typed option fields (`device(subsystem=…)`) — they render as a dropdown
     of stable by-id paths, grant kernel cgroup rules per entry (list-of-object fields are recursed), re-grant on
     hotplug without a restart, and refuse system-used devices. Facts: root `KNOWLEDGE.md` §"Supervisor: device access".
   - Schema quirks: `match()` uses search semantics (anchor with `^…$`), literal `\t`/`\n` break the supervisor's schema
     parser, and the options DSL has no uniqueness construct — enforce cross-entry constraints in runtime scripts as
     defense in depth. Facts: root `KNOWLEDGE.md` §"Supervisor: option schema quirks".
2. **translations/en.yaml** — the option field descriptions live here (rendered in the HA UI). `DOCS.md` must NOT
   duplicate them — it points at the UI instead.
3. **Dockerfile** — must not pull from Docker Hub at build time, including the `# syntax=docker/dockerfile:1` directive
   (its frontend image comes from Docker Hub; buildx's builtin frontend suffices). Decide the apk pin/float policy per
   package: pin with full `pkgver-pkgrel` when the app's runtime logic encodes the package's interface, float when
   chasing pkgrel rebuilds adds churn without user value. Policy and drift-check mechanics: root `KNOWLEDGE.md` §"apk
   package version policy".
4. **rootfs** — s6-overlay layout: user-bundle service directories live under `/etc/s6-overlay/user-bundles.d/` (never
   under `s6-rc.d/` — a stray directory there fails the whole boot while the supervisor still reports "started"), and
   every user-bundle service needs an empty `dependencies.d/base` file. Facts: root `KNOWLEDGE.md` §"s6-overlay: user
   bundles live OUTSIDE s6-rc.d". Shell-script gotchas: skill `ha-app-base-image`.
5. **AppArmor** — write the custom profile (rating +1) following skill `ha-app-apparmor`.
6. **Security rating** — engineer the option set and profile toward the highest reachable rating; the formula with every
   branch and its sources: root `KNOWLEDGE.md` §"Supervisor: app security rating". Worked per-app examples:
   `hd-idle/KNOWLEDGE.md` and `nfs-server/KNOWLEDGE.md` (rating sections).
7. **Docs** — `DOCS.md` (end-user usage, shown in the HA UI), `CHANGELOG.md` (user-visible changes per version),
   `TODO.md`, `KNOWLEDGE.md` (app-specific facts only; placement rule in `AGENTS.md`).
8. **Testing** — the lab boots a new app with no hook needed (boot-only lab). Add per-app hooks later per skill
   `ha-app-lab-testing`. Release rules: skill `ha-app-workflow`.
9. Register the app in `AGENTS.md` ("What this repository is").
