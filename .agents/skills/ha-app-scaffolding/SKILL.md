---
name: ha-app-scaffolding
description: How to create a new Home Assistant app in this repository – required files, config schema and translation
  conventions, Dockerfile rules, security-rating engineering, and the apk pin/float decision. Use when adding or
  bootstrapping a new app subdirectory.
---

# Creating a new app

An app is a subdirectory containing: `config.yaml`, `Dockerfile`, `.dockerignore` (build-context allow-list), `rootfs/`
(s6-overlay tree), `translations/en.yaml`, `DOCS.md`, `CHANGELOG.md`, `README.md`, `KNOWLEDGE.md`, `TODO.md`,
`apparmor.txt`, and icons (`icon.png` is the floor; `icon.svg`/`logo.svg`/`logo.png` optional – see the existing apps).

## Steps

1. **config.yaml** – schema reference: the [app configuration
   reference](https://contributors.home-assistant.io/apps/reference/configuration/). Conventions:
   - Option values are user data: existing installs never receive `config.yaml` default changes – write optional keys
     with `bashio::config '<key>' <default>` (facts: root `KNOWLEDGE.md` §"Supervisor: option schema quirks").
   - Grant device access exclusively via device-typed option fields (`device(subsystem=…)` – facts and mechanics: root
     `KNOWLEDGE.md` §"Supervisor: device access").
   - Read root `KNOWLEDGE.md` §"Supervisor: option schema quirks" before writing the schema: anchored `match()` regexes,
     and cross-entry constraints enforced in runtime scripts (the options DSL has no uniqueness construct).
2. **translations/en.yaml** – the option field descriptions live here (rendered in the HA UI); `DOCS.md` points at the
   UI instead (placement rule: `AGENTS.md`).
3. **Dockerfile** – must not pull from Docker Hub at build time, including the `# syntax=docker/dockerfile:1` directive
   (its frontend image comes from Docker Hub; buildx's builtin frontend suffices). `.dockerignore` allow-lists the build
   context (`*` then `!rootfs/` and `!Dockerfile`): the image content is the rootfs tree; if a COPY ever reads beyond
   `rootfs/`, re-include the file there. Decide the apk pin/float policy per package: pin with full `pkgver-pkgrel` when
   the app's runtime logic encodes the package's interface, float when chasing pkgrel rebuilds adds churn without user
   value. Policy and drift-check mechanics: root `KNOWLEDGE.md` §"apk package version policy".
4. **rootfs** – s6-overlay layout per root `KNOWLEDGE.md` §"s6-overlay: user bundles live OUTSIDE s6-rc.d"; shell-script
   gotchas: skill `ha-app-base-image`.
5. **AppArmor** – write the custom profile (rating +1) following skill `ha-app-apparmor`.
6. **Security rating** – engineer the option set and profile toward the highest reachable rating; the formula with every
   branch and its sources: root `KNOWLEDGE.md` §"Supervisor: app security rating". Worked per-app examples:
   `hd-idle/KNOWLEDGE.md` and `nfs-server/KNOWLEDGE.md` (rating sections).
7. **Docs** – `DOCS.md` (end-user usage, shown in the HA UI), `CHANGELOG.md` (user-visible changes per version),
   `TODO.md`, `KNOWLEDGE.md` (app-specific facts only; placement rule in `AGENTS.md`).
8. **Testing** – the lab boots a new app with no hook needed (skill `ha-app-lab-testing`). Release rules: skill
   `ha-app-workflow`.
9. Register the app in `AGENTS.md` ("What this repository is").
