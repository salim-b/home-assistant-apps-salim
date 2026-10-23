# KNOWLEDGE

App-specific facts for the hickory-dns app, gathered from upstream source and Alpine packaging work. Facts that span
apps live in the repository-root `KNOWLEDGE.md`; procedures live in `.agents/skills/`. Bashio option parsing idioms
(list-of-object options, `// empty` string-only rule): hd-idle/KNOWLEDGE.md §"bashio option parsing (list-of-object
options)" - this app uses the same mechanics (including the one-JSON-object-per-line handling and the defense-in-depth
re-validation of every option value).

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
  the apk installs them to `/usr/share/doc/hickory-dns/examples/default/`, a doc-dir layout we do not couple to).
- Forward store (`crates/server/src/store/forwarder.rs` `ForwardConfig`, deny_unknown_fields): `name_servers` (required
  Vec) + `options` (optional table). One `[[zones.stores.name_servers]]` block per configured upstream
  (`crates/resolver/src/config.rs`):
  - `ip` (required, v4 or v6 literal) is the CONNECT TARGET - never DNS-resolved. This is why pure-IP defaults need no
    boot-time resolution (no chicken-and-egg); `server_name` is used only for TLS SNI + certificate validation.
  - `trust_negative_responses` (optional bool, default **true**) - the generator emits **false**: with two potentially
    different upstream providers, an NXDOMAIN from the first is retried against the second instead of being trusted
    (resilience over latency).
  - `connections`: list of `{ port = <u16>, protocol = { ... } }` tables. `port` is a SIBLING key with the
    protocol-default applied when absent (53 udp/tcp, 853 tls/quic, 443 https/h3). `ProtocolConfig` is internally tagged
    (`tag = "type"`, snake_case, deny_unknown_fields): `{ type = "udp" }`, `{ type = "tcp" }`,
    `{ type = "tls", server_name = "..." }`, `{ type = "https", server_name = "...", path = "..." }`,
    `{ type = "quic", server_name = "..." }`.
  - **`server_name` is MANDATORY** for tls/https/quic (no serde default) - an IP-address upstream must get it from the
    URL fragment (`tls://9.9.9.9#dns.quad9.net`); the generator hard-rejects the missing fragment for IP literals and
    derives it from the hostname otherwise.
  - **`path` has NO serde default** on `Https`/`H3` (only the programmatic constructor fills `/dns-query`) - generated
    TOML always emits `path` explicitly (default `/dns-query`).
- Resolver options (`[zones.stores.options]`, `ResolverOpts`, serde default + deny_unknown_fields): the generator pins
  `timeout = 5`, `attempts = 2`, `num_concurrent_reqs = 1`, `server_ordering_strategy = "user_provided_order"` (makes
  the upstreams option order the failover priority; the default `query_statistics` adaptive ordering would silently
  reorder), `positive_max_ttl = 3600`, `negative_max_ttl = 3600`, `edns_payload_len = 1232` (avoids UDP fragmentation on
  tunneled paths), `cache_size = 8192`, and `validate = <dnssec option>` (DNSSEC validation; the root KSKs - KSK-2017
  tag 20326, KSK-2024 tag 38696 - are embedded via `TrustAnchors::default()`, no anchor file needed).
- ACL semantics (`crates/server/src/access.rs`, verified): allow-only configuration denies every other client; **empty
  allow AND deny lists = allow all** - the generator emits `allow_networks = []` when the option is cleared (with a
  warning). The ACL is server-wide (no per-zone recursion control).

## Upstream URL grammar

`<scheme>://<ip-or-host>[:<port>][/<path>][#<sni>]` - schemes `tls`, `https` (with optional `/path`), `quic`, `udp`,
`tcp`. Parsing rules implemented in the generator: bracketed IPv6 (`tls://[2001:db8::1]:853#n`), bare IPv6 (multiple
colons, no port expressible), `host:port` (single colon), else IP/hostname. `#sni` is required for tls/https/quic (see
above) and REJECTED on udp/tcp (with a `/path` likewise https-only) - silent ignoring would misconfigure. `h3://` is
rejected with a pointed error until the packaged binary grows the h3 feature (hickory-dns/TODO.md).

Hostname upstreams are resolved once at generation time via the shipped `resolve` CLI from hickory-dns-utils
(`resolve --system -t A|AAAA <name>` against `/etc/resolv.conf` = the supervisor's DNS forwarder; answer lines are
`\t<name> <ttl> <class> <type> <rdata>`, CNAME chains skipped by matching the type field). Fresh-first, then the
last-known-good cache `/data/hickory-dns.upstreams.cache` (`name ip` lines) - so upstream address changes are picked up
automatically and a resolution outage at boot degrades to the cached address instead of failing.

## Option consumption (bashio)

`bashio::config '<array option>'` (bashio `lib/config.sh`: the array branch iterates `.key[]` through `jq -r -c -M`)
emits string-array options as one RAW (unquoted) element per line, object-array options as one compact JSON object per
line. The output has NO trailing newline (`printf '%s'` of the `$()`-stripped jq stream), so a `while read` fed directly
from `bashio::config` silently drops the last element - capture the value into a variable and feed the loop via
`< <(echo "${RAW}")` (`echo` re-terminates the final line; the hd-idle-genargs idiom). A raw string line must NOT go
through `bashio::jq` (jq parses it as JSON: `127.0.0.0/8` fails with `Invalid numeric literal` and exit 5) - only object
lines do. Read from `/usr/lib/bashio/{config,jq}.sh` inside the built image (ghcr.io/home-assistant/base:3.24, 2026-10);
the lab surfaced the failure as `jq: parse error: Invalid numeric literal at line 2, column 0` with the generator
exiting 5.

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

## Port 53 binding and privileges

- **CAP_NET_BIND_SERVICE is needed in the AppArmor profile even though the container runs as root**: the :53 bind
  triggers `ns_capable(CAP_NET_BIND_SERVICE)`, and AppArmor mediates the kernel's capable() LSM hook itself (the hd-idle
  `sys_rawio` precedent). No `privileged:` entry is needed - HA app containers run as root with the default capability
  set.
- **Privilege drop**: `bin/src/lib.rs` `check_drop_privs` - post-bind (doc: "must be called after binding to low
  numbered sockets is complete"), syscalls getuid/getgid/geteuid/getegid + getpwnam/getgrnam (reads /etc/passwd,
  /etc/group) + setgid + setuid. NO setgroups, NO prctl/capset - so no `setpcap`-style AppArmor rule can ever be needed.
  The profile grants `capability setgid,` + `capability setuid,` for the drop.
- v0.26.1 calls `check_drop_privs` UNCONDITIONALLY (no config key); v0.26.2 added the `drop_privileges` option (default
  true, "Set to false in container/namespace environments where /etc/passwd is not available"). This app does NOT emit
  the key: the drop to `nobody:nobody` (Alpine baselayout has the user/group) is harmless here - every zone file is
  parsed BEFORE the drop, the daemon writes nothing to disk (cache in memory, logs to stdout), and SETUID/SETGID are not
  on the supervisor's high-risk capability list (repository-root KNOWLEDGE.md §"Supervisor: app security rating"). Not
  emitting the key also keeps the generated config parseable by the 0.26.1 dev pin (deny_unknown_fields).
- The `dns` healthcheck binary runs as root (docker HEALTHCHECK exec) - a plain UDP query, no capabilities.

## Healthcheck

`/usr/bin/hickory-dns-healthcheck` probes with a REAL query (`dns -n 127.0.0.1:53 query localhost A`, hickory-dns-utils'
client CLI) - socket + catalog + response, authoritative (no upstream dependency: a dead upstream must not mark a
healthy local DNS server unhealthy). HEALTHCHECK timeout 10s (client query timeout is smaller). The daemon has no HTTP
endpoint (the apk compiles without metrics features), so there is no watchdog URL - HEALTHCHECK is the only
container-level wedge signal (repository-root KNOWLEDGE.md §"Supervisor: health events / watchdog"). If the ACL is
configured without a loopback network, the probe is REFUSED and the app shows unhealthy while serving LAN clients - the
generator warns at boot when the option lacks a loopback entry.

## apk package pins and CA trust

`hickory-dns` + `hickory-dns-utils` are pinned with full `pkgver-pkgrel` (the generated config encodes the binary's
interface - named.toml schema + CLI; repository-root KNOWLEDGE.md §"apk package version policy"). Development pin
0.26.1-r0; first release gated on a 3.24-stable APKINDEX serving >= 0.26.3 (v0.26.2 fixed ~38 GHSA advisories - shipping
0.26.1 would undercut the app's security promise). The aports APKBUILD compiles with
`tls-aws-lc-rs,https-aws-lc-rs,quic-aws-lc-rs,dnssec-aws-lc-rs,rustls-platform-verifier` (+ blocklist, recursor,
resolver for the bin) - DoH3 is absent (feature unreleased). `rustls-platform-verifier` reads the system trust store:
`ca-certificates-bundle` is installed explicitly (floating; certificate data package). `hickory-dns-utils` ships
`/usr/bin/dns`, `/usr/bin/recurse`, `/usr/bin/resolve` (used by the healthcheck and the hostname resolution); the main
package ships `/usr/bin/hickory-dns` (renamed from `named` at 0.24.0, no alias).

## Config-file and data layout

`/data/named.toml` (persistent, user-inspectable; written atomically - `.new` is validated, then moved),
`/etc/hickory-dns/zones/default/*.zone` (shipped default zones, image-owned), `/etc/hickory-dns/zones/static/`
(generated leaf zones, regenerated at every boot - stale files removed), `/etc/hickory-dns.args` (the s6 service command
line, `--config /data/named.toml` + optional `--debug`), `/data/hickory-dns.upstreams.cache` (last-known-good
resolutions). The debug option maps to the daemon CLI's `--debug` flag; `-q`/`-d`/`-p` and RUST_LOG are available for
manual debugging (`docker exec`).

## AppArmor profile surface

Custom profile (repository-root KNOWLEDGE.md §"AppArmor: mediation and profile mechanics"): `file,` + `signal,`
blankets, `capability net_bind_service` + `setgid` + `setuid`, network inet/inet6 stream/dgram (listeners, upstream
connections, bashio supervisor API, healthcheck probe), the s6/bashio/`/data` boilerplate from the hd-idle profile, and
documented (blanket-covered) rules for the app's config surface (`/etc/hickory-dns/{,**}`), the privilege-drop lookups
(`/etc/passwd`, `/etc/group`), `/etc/resolv.conf` (hostname upstreams), and `/etc/ssl/certs/{,**}`
(rustls-platform-verifier trust store). No sub-profile: the daemon needs network in the same profile. The lab has no
AppArmor enforcement - the capability rules (`net_bind_service` for the bind, `setgid`/`setuid` for the drop) are
device-verified findings (see hickory-dns/TODO.md).
