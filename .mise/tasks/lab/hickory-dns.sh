#!/usr/bin/env bash
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App hook for .mise/tasks/lab.sh (hickory-dns specifics); general contract (lab_docker_args append
# semantics, lab_runtime_check, fixture adapters in .mise/tasks/lab/<app>.py):
# see .agents/skills/ha-app-lab-testing.

## Fixture adaptation: .mise/tasks/lab/hickory-dns.py adds one static entry so the runtime check can
## probe an authoritative leaf-zone answer (the default options serve none). LAB_FIXTURE_ENV (forwarded by
## the harness to the fake API) selects the upstream-pool variant: `upstreams=https` / `upstreams=quic`
## replace the default pool with a single hostname-only upstream, so the forwarded probe proves exactly
## that transport end-to-end through the real daemon (DoT is covered by the default pool; the resolve CLI
## cannot dial DoH/DoQ directly). Run all three after transport-affecting changes:
##   LAB_FIXTURE_ENV=upstreams=https mise run lab hickory-dns   # Cloudflare DoH
##   LAB_FIXTURE_ENV=upstreams=quic mise run lab hickory-dns    # AdGuard DoQ
## Hostname-only upstreams additionally exercise the boot-time name resolution path (fresh lookup +
## last-known-good cache) that the default IP-based pool skips.

lab_runtime_check() {
  ## The fixture variant must have taken effect: a lost docker-cp race would otherwise serve the default
  ## options and silently test the default pool instead of the selected transport.
  case "${LAB_FIXTURE_ENV:-}" in
    *upstreams=https*)
      grep -q 'type = "https"' "$LAB_TMPDIR/data/named.toml" \
        || {
          echo "https variant not in effect (no https upstream in the generated pool)"
          return 1
        }
      ;;
    *upstreams=quic*)
      grep -q 'type = "quic"' "$LAB_TMPDIR/data/named.toml" \
        || {
          echo "quic variant not in effect (no quic upstream in the generated pool)"
          return 1
        }
      ;;
  esac
  ## Wait for the daemon to accept queries: the boot-complete oracle fires when s6 marks the longrun
  ## started, a beat before the socket is live.
  local tries=0
  until docker exec "$LAB_NET_NAME-app" /usr/bin/dns -n 127.0.0.1:53 query localhost A >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || {
      echo "hickory-dns did not answer the localhost query within ~10s"
      return 1
    }
    sleep 1
  done

  ## Never-root credentials: the daemon must run as nobody (65534) holding exactly one capability - the ambient
  ## CAP_NET_BIND_SERVICE (bit 10 = 0x400). Regresses if the launcher ever runs the daemon as root again or the
  ## ambient hand-off breaks (a root daemon would show Uid 0 and the full default capability set).
  local pid creds
  pid=$(docker exec "$LAB_NET_NAME-app" pidof hickory-dns) || {
    echo "hickory-dns pid not found in the app container"
    return 1
  }
  creds=$(docker exec "$LAB_NET_NAME-app" grep -E '^(Uid|CapEff|CapAmb):' "/proc/$pid/status")
  grep -q '^Uid:[[:space:]]*65534[[:space:]]*65534[[:space:]]*65534[[:space:]]*65534$' <<<"$creds" \
    || {
      echo "daemon does not run as nobody (65534): $creds"
      return 1
    }
  grep -q '^CapEff:[[:space:]]*0000000000000400$' <<<"$creds" \
    || {
      echo "CapEff is not exactly the ambient CAP_NET_BIND_SERVICE: $creds"
      return 1
    }
  grep -q '^CapAmb:[[:space:]]*0000000000000400$' <<<"$creds" \
    || {
      echo "CAP_NET_BIND_SERVICE is not in the ambient set: $creds"
      return 1
    }

  ## Shipped authoritative zone: end-to-end socket + catalog + response, no upstream dependency.
  local out
  out=$(docker exec "$LAB_NET_NAME-app" /usr/bin/dns -n 127.0.0.1:53 query localhost A) \
    || {
      echo "localhost query failed: $out"
      return 1
    }
  grep -q '127.0.0.1' <<<"$out" || {
    echo "localhost answer carries no A record: $out"
    return 1
  }

  ## Static-entry leaf zone (added by the fixture adapter): the catalog must answer it authoritatively
  ## ahead of the '.' forward zone.
  out=$(docker exec "$LAB_NET_NAME-app" /usr/bin/dns -n 127.0.0.1:53 query lab-probe.home.arpa A) \
    || {
      echo "static-entry query failed: $out"
      return 1
    }
  grep -q '192.0.2.1' <<<"$out" || {
    echo "static-entry answer does not carry 192.0.2.1: $out"
    return 1
  }

  ## Forwarded query: the real path - resolver pool, encrypted upstream (DoT to Quad9), DNSSEC
  ## validation of the signed example.com. Needs outbound internet from the lab network.
  out=$(docker exec "$LAB_NET_NAME-app" /usr/bin/dns -n 127.0.0.1:53 query example.com A) \
    || {
      echo "forwarded query failed (no upstream path from the lab network?): $out"
      return 1
    }
  grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$out" || {
    echo "forwarded answer carries no IPv4 record: $out"
    return 1
  }
}
