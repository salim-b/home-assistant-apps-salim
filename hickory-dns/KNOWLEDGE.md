# KNOWLEDGE

App-specific facts for the hickory-dns app, gathered from upstream source and Alpine packaging work. Facts that span
apps live in the repository-root `KNOWLEDGE.md`; procedures live in `.agents/skills/` (this app's runtime procedures:
skill `hickory-dns-runtime`).

## Generated named.toml

The cont-init generator (`rootfs/usr/bin/hickory-dns-genconfig`) emits `/data/named.toml` from the app options. Ground
truth (verified against v0.26.3 AND v0.26.1 source - the dev pin must parse the same config):

- Top-level keys (`bin/src/config/mod.rs`): `listen_addrs_ipv4`/`listen_addrs_ipv6` (lists of IPs), `listen_port` (u16),
  `directory` (zone-file root, default `/var/named`), `allow_networks`/`deny_networks` (lists of CIDR strings), `zones`
  (array of tables), `drop_privileges` (**added in 0.26.2** - NOT emitted by this app, see §"Port 53 binding and
  privileges"). `deny_unknown_fields` everywhere: a typo is a hard startup error - which the generator turns into a boot
  failure with a logged message (`--validate` gate).
- **TOML ordering rule**: every top-level key must precede the first `[[zones]]` header (bare keys after one would land
  inside it), and every `[[zones]]` header must precede the forward zone's stores sub-tables - dotted sub-table headers
  (`[[zones.stores.name_servers]]`) implicitly define their parent tables, so emitting one before `[[zones]]` makes
  `zones` a plain table that cannot be redefined as an array afterwards (TOML "table cannot be redefined" error). The
  generator therefore assembles in this order: top-level keys, default zones, static zones, forward-zone header,
  name_servers blocks, options table.
- Zone structure: Primary zones use a flat `file = "<relative path>"` key, which the deserializer turns into a file
  store (`bin/src/config/mod.rs` `ZoneConfigWithFile`; paths are relative to `directory`). Default zones: `localhost`,
  `0.0.127.in-addr.arpa`, the 31-label `0.0.0...ip6.arpa` reverse zone, `255.in-addr.arpa`, `0.in-addr.arpa` (shipped
  under `rootfs/etc/hickory-dns/zones/default/`, copied verbatim from the upstream test-data `default/*.zone` files -
  the apk installs them to `/usr/share/doc/hickory-dns/examples/default/`, a doc-dir layout the image does not couple
  to).
- Forward store (`crates/server/src/store/forwarder.rs` `ForwardConfig`, deny_unknown_fields): `name_servers` (required
  Vec) + `options` (optional table). One `[[zones.stores.name_servers]]` block per configured upstream
  (`crates/resolver/src/config.rs`); per-connection field semantics (which field means what, defaults, the h3 gap) live
  in §"Upstream option model". TOML-shape facts:
  - `trust_negative_responses` (optional bool, default **true**) - the generator emits **false**: with two potentially
    different upstream providers, an NXDOMAIN from the first is retried against the second instead of being trusted
    (resilience over latency).
  - `connections`: list of `{ port = <u16>, protocol = { ... } }` tables. `port` is a SIBLING key emitted only when
    configured (the protocol-default applies when absent: 53 udp/tcp, 853 tls/quic, 443 https/h3). `ProtocolConfig` is
    internally tagged (`tag = "type"`, snake_case, deny_unknown_fields): `{ type = "udp" }`, `{ type = "tcp" }`,
    `{ type = "tls", server_name = "..." }`, `{ type = "https", server_name = "...", path = "..." }`,
    `{ type = "quic", server_name = "..." }`. Generated TOML always emits `path` explicitly on https (no serde default
    - §"Upstream option model").
- Resolver options (`[zones.stores.options]`, `ResolverOpts`, serde default + deny_unknown_fields): the generator pins
  `timeout = 5`, `attempts = 2`, `num_concurrent_reqs = 1`, `server_ordering_strategy = "UserProvidedOrder"` (makes the
  upstreams option order the failover priority; the default `QueryStatistics` adaptive ordering would silently reorder),
  `positive_max_ttl = 3600`, `negative_max_ttl = 3600`, `edns_payload_len = 1232` (avoids UDP fragmentation on tunneled
  paths), `cache_size = 8192`, and `validate = <dnssec option>` (DNSSEC validation; the root KSKs - KSK-2017 tag 20326,
  KSK-2024 tag 38696 - are embedded via `TrustAnchors::default()`, no anchor file needed). Enum VALUES in the generated
  TOML are the Rust variant names verbatim (`ServerOrderingStrategy` has no `rename_all`; the lab's real `--validate`
  rejected a snake_case value that hand-written prose had slipped in).
- ACL semantics (`crates/server/src/access.rs`, verified): allow-only configuration denies every other client; **empty
  allow AND deny lists = allow all** - the generator emits `allow_networks = []` when the option is cleared (with a
  warning). The ACL is server-wide (no per-zone recursion control). Loopback (127.0.0.0/8, ::1/128) is always served:
  the generator appends missing entries to a configured ACL (the healthcheck probes from 127.0.0.1).

## Upstream option model

Each `upstreams` entry is a structured object: `protocol` (`tls`/`quic`/`https` - the serde ProtocolConfig type values
verbatim; a single-value `list(...)` select in the option schema, repository-root KNOWLEDGE.md §"Supervisor: option
schema quirks"; plaintext upstreams are NOT offered), `host`, `ip`, `port`, `path`. Generator-enforced field rules:
`host` is the TLS server name (mandatory for every protocol - nothing to derive it from a bare IP) and doubles as the
resolution source when `ip` is empty; `ip` is the connect target (validated literal, never resolved by the daemon);
`port` defaults 853 (tls/quic) / 443 (https) and is emitted only when set (the serde protocol-default applies
otherwise); `path` is https-only (default `/dns-query`, no serde default, leading slash normalized) and rejected on the
other protocols - silent ignoring would misconfigure. `protocol = h3` (the serde H3 type) is rejected with a pointed
error until the packaged binary grows the h3 feature (§"Deferred feature ground truth (upstream gaps)"). The shipped
defaults are Quad9's anycast IPs with the pinned TLS name `dns.quad9.net` - pure-IP connect targets need no boot-time
name resolution (no chicken-and-egg).

Hostname upstreams are resolved once at generation time via the shipped `resolve` CLI from hickory-dns-utils
(`resolve --system -t A|AAAA <name>` against `/etc/resolv.conf` = the supervisor's DNS forwarder). The CLI has no
timeout of its own - each lookup is bounded by `timeout 10` so a wedged system resolver cannot stall the boot (and with
it cont-init). Answer lines are `\t<name> <ttl> <class> <type> <rdata>`; the generator picks the first record of the
wanted type (CNAME chains skipped) and accepts only a structurally valid address - fresh or from the last-known-good
cache `/data/hickory-dns.upstreams.cache` (`name ip` lines, corrupt address fields skipped). Fresh-first, then the
cache: upstream address changes are picked up automatically and a resolution outage at boot degrades to the cached
address instead of failing.

## Option consumption (bashio)

The mechanics (array-option line shapes, the no-trailing-newline last-element hazard, the `// empty` string-only rule,
the `bashio::jq` ban on raw string lines) are repository-wide facts: repository-root `KNOWLEDGE.md` §"bashio option
consumption". This app's application: the generator consumes both shapes (`allow_networks` as raw string lines,
`static_entries`/`upstreams` as JSON-object lines) and re-validates every value regardless of the option schema (defense
in depth).

## Generator regression sandbox

The generator is regression-tested offline in a disposable sandbox (`/tmp/hickory-test/`, recreated per session - the
lab covers the real-image path instead). The procedure (copy adaptation, bashio/resolve stubs, scenario matrix) is a
skill: `hickory-dns-runtime` §"Offline regression sandbox"; the stubs replicate the option-consumption mechanics
(repository-root `KNOWLEDGE.md` §"bashio option consumption").

## Static entries (no hosts-file store upstream)

The server binary has NO hosts-file store (store types: file/in_memory/sqlite/forwarder/recursor/blocklist -
`crates/server/src/store/mod.rs`; the resolver-library hosts support is not exposed by the binary, and the blocklist's
hosts-format support is 0.0.0.0-sinkhole-only). Each static entry therefore becomes its own authoritative **Primary leaf
zone** (SOA + NS + A/AAAA at the apex, `$ORIGIN <name>.`, TTL 300) written to
`/etc/hickory-dns/zones/static/NN_<slug>.zone` at every boot and referenced from named.toml. The catalog answers the
most specific zone first, so leaf zones win over the `.` forward zone - including public names. Generator-side
validation: lowercase + trailing-dot normalization, LDH hostname check, IP check, duplicate (case-insensitive) and
default-zone-shadow rejection, single-label warning. Caveats: unconfigured query types get authoritative
NODATA/NXDOMAIN, and local answers carry no AD bit (they are authoritative, not validated). The zone-file content itself
is validated by the `--validate` boot gate (zone loading happens in `DnsServer::run` BEFORE the validate return,
`bin/src/lib.rs`).

## Deferred feature ground truth (upstream gaps)

Verified against v0.26.3 source; revisit when a tagged release + the apk carry the features (hickory-dns/TODO.md).

- **Blocklist store**: upstream has a `blocklist` store (compiled into the apk: the `_cargo_opts_bin` feature list
  includes `blocklist`; plain domain lists and `0.0.0.0 <domain>` hosts lines only - no other hosts-file flavors). Local
  files are read once at startup with NO hot reload (upstream issue #3460 - restart the app to refresh); non-address
  query types sink to a forged sinkhole A/AAAA (sinkhole_ipv4 defaults 0.0.0.0); absolute file paths are allowed since
  0.26.2 (PR #3864). Design sketch when pursued: download list URLs in cont-init into `/data` (curl), chain a
  `[[zones.stores]] type = "blocklist"` ahead of the forward store.
- **DoH3 upstreams**: the bin `h3-aws-lc-rs`/`h3-ring` features are merged upstream (PRs #3993/#3994, 2026-09-25) but
  NOT in any tagged release, so no apk can ship them (the aports feature list - §"apk package pins and CA trust" - has
  no h3 either). The generator already rejects `protocol = h3` with a pointed error; the H3 protocol table also needs
  `path`, like https (`crates/resolver/src/config.rs` `ProtocolConfig::H3`).
- **SPKI pinning for configured upstreams**: there is NO config surface for it. Upstream connection config is `ip` +
  protocol tables (`server_name`/`path` only, deny_unknown_fields, `crates/resolver/src/config.rs` `ProtocolConfig`),
  TLS verification is fixed to rustls-platform-verifier / webpki-roots (`crates/net/src/tls.rs` `client_config()`), and
  the only SPKI-adjacent code is TLSA record parsing (`crates/proto/src/rr/rdata/tlsa.rs`), not wired into upstream
  validation. A genuine gap for the app's threat model (a mis-issued CA could impersonate `dns.quad9.net`) and not
  patchable into the apk binary - needs an upstream feature request, then an app option.

## Port 53 binding and privileges

- **Host network + port 53**: the daemon binds DNS port 53 in the HOST network namespace (`host_network: true` - the
  AdGuard Home/Pi-hole precedent). The HAOS host itself binds nothing on 53 (systemd-resolved runs with
  DNSStubListener=no). No `privileged:` entry is needed: the launcher's capabilities come from the Docker default set,
  none is on the supervisor's high-risk rating list, and none is in `REDUCED_CAPABILITIES_DROP` (repository-root
  KNOWLEDGE.md §"Supervisor: app security rating").
- **Source IPs stay intact** under `host_network`: LAN clients connect to the host's :53 directly, so the ACL sees the
  real client addresses - port *publishing* would DNAT/conntrack them into host-local ones and defeat per-network
  allow/deny.
- **Never-root launcher**: the s6 run script execs the daemon as `nobody:nobody` (65534/65534, Alpine baselayout) via
  util-linux `setpriv` (`/bin/setpriv`, apk `setpriv` - floats per the apk policy; the busybox applet has no `--reuid`
  and is replaced by the package):
  `--no-new-privs --reuid 65534 --regid 65534 --clear-groups --inh-caps=+net_bind_service --ambient-caps=+net_bind_service`.
  The daemon's credential set is exactly ONE capability - ambient `CAP_NET_BIND_SERVICE` for the :53 bind -
  lab-verified: `Uid`/`Gid` all 65534, `CapEff`/`CapPrm`/`CapAmb` = `0000000000000400`, and the bind works even with
  `NoNewPrivs: 1`. Ambient capabilities are runtime prctl state (kernel >= 4.3), not exec-acquired, so they survive
  `no_new_privs`, which the launcher also sets. The daemon never runs as root and never holds a privilege-change
  capability - unlike a post-bind self-drop, which requires the daemon to run as root and to possess setuid/setgid
  during its lifetime.
- **The binary's own privilege drop is a no-op here**: `bin/src/lib.rs` `check_drop_privs` (v0.26.1, verified source)
  looks up `user`/`group` from the config (defaults `nobody`/`nobody`) via getpwnam/getgrnam and drops via bare setgid +
  setuid - but ONLY `if uid == 0 || euid == 0`. Running as 65534 it just logs the ids. NO setgroups, NO prctl/capset in
  the binary.
- **AppArmor grants** (`apparmor.txt`): `net_bind_service` (the :53 bind's ns_capable), `setgid`/`setuid` (setpriv's
  setgroups/setresgid/setresuid), `setpcap` (capset raising the inheritable set, prctl ambient-raise/no_new_privs).
  AppArmor mediates the kernel's capable() LSM hook (repository-root KNOWLEDGE.md §"AppArmor: mediation and profile
  mechanics"). The grants serve the launcher; the daemon exec's holding exactly one capability.
- The `dns` healthcheck binary runs as root (docker HEALTHCHECK exec) - a plain UDP query, no capabilities.
- **Device verification** remains the only check for the launcher's capability path under AppArmor enforcement (the lab
  has none - skill ha-app-lab-testing): hickory-dns/TODO.md.

## Healthcheck

`/usr/bin/hickory-dns-healthcheck` probes with a REAL query (`dns -n 127.0.0.1:53 query localhost A`, hickory-dns-utils'
client CLI) - socket + catalog + response, authoritative (no upstream dependency: a dead upstream must not mark a
healthy local DNS server unhealthy). HEALTHCHECK timeout 10s (client query timeout is smaller). The daemon has no HTTP
endpoint (the apk compiles without metrics features), so there is no watchdog URL - HEALTHCHECK is the only
container-level wedge signal (repository-root KNOWLEDGE.md §"Supervisor: health events / watchdog"). A configured ACL
without loopback entries gets them appended by the generator (with a warning) - loopback clients are always served.

## apk package pins and CA trust

`hickory-dns` + `hickory-dns-utils` are pinned with full `pkgver-pkgrel` (the generated config encodes the binary's
interface - named.toml schema + CLI; repository-root KNOWLEDGE.md §"apk package version policy"). Development pin
0.26.1-r0; first release gated on a 3.24-stable APKINDEX serving >= 0.26.3 (v0.26.2 fixed ~38 GHSA advisories - shipping
0.26.1 would undercut the app's security promise). The aports APKBUILD compiles with
`tls-aws-lc-rs,https-aws-lc-rs,quic-aws-lc-rs,dnssec-aws-lc-rs,rustls-platform-verifier` (+ blocklist, recursor,
resolver for the bin) - DoH3 is absent (§"Deferred feature ground truth (upstream gaps)"). `rustls-platform-verifier`
reads the system trust store: `ca-certificates-bundle` is installed explicitly (floating; certificate data package).
`hickory-dns-utils` ships `/usr/bin/dns`, `/usr/bin/recurse`, `/usr/bin/resolve` (used by the healthcheck and the
hostname resolution); the main package ships `/usr/bin/hickory-dns` (renamed from `named` at 0.24.0, no alias).

## Config-file and data layout

`/data/named.toml` (persistent, user-inspectable; written atomically - `.new` is validated, then moved),
`/etc/hickory-dns/zones/default/*.zone` (shipped default zones, image-owned), `/etc/hickory-dns/zones/static/`
(generated leaf zones, regenerated at every boot - stale files removed), `/etc/hickory-dns.args` (the s6 service command
line, `--config /data/named.toml` + optional `--debug`), `/data/hickory-dns.upstreams.cache` (last-known-good
resolutions). The debug option maps to the daemon CLI's `--debug` flag; `-q`/`-d`/`-p` and RUST_LOG are available for
manual debugging (`docker exec`).

## AppArmor profile surface

Custom profile (repository-root KNOWLEDGE.md §"AppArmor: mediation and profile mechanics"): `file,` + `signal,`
blankets, `capability net_bind_service` + `setgid` + `setuid` + `setpcap`, network inet/inet6 stream/dgram (listeners,
upstream connections, bashio supervisor API, healthcheck probe), the s6/bashio/`/data` boilerplate from the hd-idle
profile, and documented (blanket-covered) rules for the app's config surface (`/etc/hickory-dns/{,**}`), the
privilege-drop lookups (`/etc/passwd`, `/etc/group`), `/etc/resolv.conf` (hostname upstreams), and
`/etc/ssl/certs/{,**}` (rustls-platform-verifier trust store). No sub-profile: the daemon needs network in the same
profile. The lab has no AppArmor enforcement - the capability rules (`net_bind_service` for the bind,
`setgid`/`setuid`/`setpcap` for the drop) are device-verified findings (see hickory-dns/TODO.md).
