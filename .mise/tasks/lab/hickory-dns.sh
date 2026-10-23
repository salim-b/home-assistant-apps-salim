#!/usr/bin/env bash
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App hook for .mise/tasks/lab.sh (hickory-dns specifics); general contract (lab_docker_args append
# semantics, lab_runtime_check, fixture adapters in .mise/tasks/lab/<app>.py):
# see .agents/skills/ha-app-lab-testing.

## Fixture adaptation: .mise/tasks/lab/hickory-dns.py adds one static entry so the runtime check can
## probe an authoritative leaf-zone answer (the default options serve none).

lab_runtime_check() {
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
