# AGENTS.md

Instructions for coding agents working on this repository. Human-relevant information lives elsewhere — see the
placement rule below.

## What this repository is

A [Home Assistant app repository](https://contributors.home-assistant.io/apps/) (formerly "add-ons"): each app is a
subdirectory with a `config.yaml`, `Dockerfile`, `.dockerignore`, `rootfs/`, docs, translations, and its own `TODO.md` /
`KNOWLEDGE.md`. Currently contains:

- `nfs-server` — an NFSv4 server app running the NFS server in the host kernel via the HAOS kernel module.
- `hd-idle` — spins down idle USB/SATA hard disk drives via the Alpine `hd-idle` package (CLI-only configuration).
- `hickory-dns` — a DNS server that forwards to user-configured encrypted upstream resolvers (DoT/DoH/DoQ) with DNSSEC
  validation, wrapping the Alpine `hickory-dns` package (generated `named.toml` configuration).

All apps' architecture and gotchas are non-obvious: consult their runtime skills (index below) before touching their
runtime code.

## Information placement rule

Never duplicate information across files. Place it where it belongs and reference it from everywhere else:

- `README.md` — human users: what the repo is, how to install/test on a device.
- `KNOWLEDGE.md` (repo root) — cross-app technical **facts** (supervisor behaviors, AppArmor mechanics, base-image shell
  gotchas, apk policy). Skills and code comments cite its sections by exact name — keep section names stable.
- `.agents/skills/<name>/` — **procedures** for coding agents (how to do things), in the
  [agentskills.io](https://agentskills.io/specification) format (`SKILL.md` with YAML frontmatter; optional `scripts/`,
  `references/`, `assets/`). Skills cite facts from the knowledge files by section (`§"..."`), never restate them.
- `<app>/KNOWLEDGE.md` — app-specific cross-session facts (same discipline as the root file). Write a new entry whenever
  you learn something non-obvious about *this app* that outlives the current change; repository-wide facts go to the
  root `KNOWLEDGE.md` instead.
- `<app>/DOCS.md` — end-user documentation (shown in the HA UI). Must not duplicate the option field descriptions from
  `translations/en.yaml` — point at the UI instead.
- `<app>/CHANGELOG.md` — user-visible changes per version.
- `TODO.md` (repo root) and `<app>/TODO.md` — open work items only (cross-app vs. app-specific). Resolved items are
  deleted, not archived: Git history is the record.
- Code and config comments — reduce to a minimum; purpose plus pointer (`# See <app>/KNOWLEDGE.md §…`,
  `# see .agents/skills/<skill>…`); parsimony rules below.
- `AGENTS.md` (this file) — agent process, placement rule, and the skill index. No facts, no procedures, no task usage.

### Prose parsimony

Applies to comments and documentation alike:

- No "episodic" content — references to past states of the code, working history ("this used to…", "we switched from X
  to Y"), or anything of little future relevance. Git history is the record of what was; prose describes what is.
- A comment is an exception, not the default: write one only if the code cannot say it itself (naming, structure).
- If the information matters beyond a single file, put it in its canonical home (placement rule above) and leave only a
  pointer in the comment. Inline comments (invariants whose loss would cause misbehavior) must not restate anything
  recorded elsewhere: every significant piece of information has exactly one home.

## Skills index

Load a skill's full text before doing the kind of work it covers:

  | Skill                   | Consult it before/when                                                                       |
  | ----------------------- | -------------------------------------------------------------------------------------------- |
  | `ha-app-workflow`       | making any change, commit, or release (branching, commit format, version bumps, CI)          |
  | `ha-app-tooling`        | touching `hk.pkl`, mise tasks, or lint config; interpreting lint failures                    |
  | `ha-app-markdown`       | writing or editing any Markdown file                                                         |
  | `ha-app-apparmor`       | creating or changing an `apparmor.txt`; diagnosing on-device permission denials              |
  | `ha-app-base-image`     | writing or debugging app shell scripts (procfs writes, s6 wiring, bashio)                    |
  | `ha-app-lab-testing`    | deploying any runtime-affecting change; adding or changing lab hooks                         |
  | `ha-app-device-testing` | verifying on a real HAOS device (deploy:local / deploy:registry / apply-options / test:live) |
  | `ha-app-scaffolding`    | adding or bootstrapping a new app subdirectory                                               |
  | `nfs-server-runtime`    | touching nfs-server runtime code or s6 services; debugging it on a device                    |
  | `hd-idle-runtime`       | touching hd-idle runtime code or s6 services; debugging it on a device                       |
  | `hickory-dns-runtime`   | touching hickory-dns runtime code or s6 services; debugging it on a device                   |

## Environment setup

```sh
mise trust               # first use: mise config files are untrusted until then
mise install --locked    # pinned tools from mise.toml/mise.lock
```

`docker` is required for the `build`, `test:lab`, `deploy:local`/`deploy:registry` and `test:live` tasks. For
interactive supervisor-integrated testing use the devcontainer (`.devcontainer.json`), not the lab.

## Commands

Task usage is not documented here: `mise run <task> --help` is the authoritative usage for every task;
`mise tasks ls --local` lists the tasks (the `--local` flag excludes your global mise tasks). The discipline — always
`mise run check` before finishing a change, lab-boot every runtime-affecting change — lives in skill `ha-app-workflow`.

## Workflow rules

Skill `ha-app-workflow` — load it before making any change. It owns the non-negotiables: `agent-<topic>` branches,
Conventional Commits with the `Assisted-by` trailer, final newlines, version bump + changelog for device-visible app
changes, CI-as-source-of-truth, device-SSH access policy, and citations for version-sensitive facts.
