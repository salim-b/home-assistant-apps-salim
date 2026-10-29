# TODOs

Open work items only (resolved items live in git history). Underlying technical facts live in `KNOWLEDGE.md`, runtime
procedures in the skill `hickory-dns-runtime`.

## Tasks

- **Alpine aports bump MRs**: `community/hickory-dns` is currently still at 0.26.1-r0 on 3.24-stable and master
  (identical) - facts: `KNOWLEDGE.md` §"apk package pins and CA trust".

  Submitted two MRs upstream to bump to v0.26.3:
  - <https://gitlab.alpinelinux.org/alpine/aports/-/merge_requests/110680> (`master`)
  - <https://gitlab.alpinelinux.org/alpine/aports/-/merge_requests/110681> (`3.24-stable` backport)

  Once merged and the bumped apk reaches the index, our CI should pick up the update automatically.

- Once hickory-dns 0.26.4+ is released shipping <https://github.com/hickory-dns/hickory-dns/pull/4128>, query an `A`
  instead of `SOA` record in `hickory-dns-healthcheck`.

- **Blocklist support (deferred)**: upstream ground truth and the design sketch: `KNOWLEDGE.md` §"Deferred feature
  ground truth (upstream gaps)". Pursue after the first release.

- **DoH3 upstreams (deferred)**: blocked on a tagged upstream release plus the apk carrying the bin h3 features
  (`KNOWLEDGE.md` §"Deferred feature ground truth (upstream gaps)"). The generator already rejects `protocol = h3` with
  a pointed error - revisit when that unblocks.

- **SPKI pinning for configured upstreams (deferred)**: no upstream config surface exists (`KNOWLEDGE.md` §"Deferred
  feature ground truth (upstream gaps)"). File the upstream feature request; revisit when a tagged release grows a
  pinning knob, then expose an app option.
