#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App-specific live-test hook for hickory-dns, sourced by .mise/tasks/test/live.sh; hook contract:
# .agents/skills/ha-app-device-testing. Focus: the device-only verification of the never-root
# launcher under AppArmor enforcement (hickory-dns/TODO.md) - the lab asserts the daemon's
# credentials but enforces no AppArmor (skill ha-app-lab-testing). Evidence model (root
# KNOWLEDGE.md §"Device SSH: sessions run in the Terminal & SSH app"): the ssh session runs
# inside the SSH app's container, so the daemon's process tree, /proc and the host's sockets are
# unreachable - the assertions use the app's OWN log (the s6 run script logs the full setpriv
# launch line, the daemon logs its dropped uid/gid, and every served query incl. the healthcheck's
# loopback probes) plus real queries from the dev host. A denied launcher capability step
# (setpriv's setgid/setuid/setpcap, the bind's net_bind_service) prevents exactly the logged
# state: the daemon would never come up and s6 would restart-loop. HAOS emits no AppArmor audit
# lines to grep (skill ha-app-apparmor) - functional proof is the available and strictly
# end-to-end one.
#
# Hook-local contract:
# - live_prepare(): only under --test-options; rewrites the options file on the fly (hd-idle
#   precedent): the repo test options with the querying machine's /32 appended to
#   allow_networks, so the dev-host dig checks pass the client ACL from whatever network the
#   dev host sits on. Points LIVE_TEST_OPTIONS_FILE at the generated file (must outlive the
#   run: restore_options() re-reads it from the EXIT trap for its backup sanity check; the temp
#   file itself is not cleaned up - the harness owns the exit trap).
# - live_runtime_check(): launcher path + daemon credentials + loopback serving (log-asserted),
#   the :53 binds and the DNS surface (dig from the dev host: positive forwarding query, DNSSEC
#   AD flag, bogus-data SERVFAIL, TCP, localhost default zone, the static leaf zone), app-log
#   hygiene for the current boot (anchored on the cont-init banner, hd-idle precedent; NoError
#   query lines excluded), host-journal AppArmor silence, and a single-launch assertion per boot
#   (restart-loop guard).
# - Requires dig on the dev host (AD-flag visibility; no client image is built here - the
#   harness's generic nfs client image carries no DNS client).
# - WARNING: the run turns the device into a live resolver for the networks it serves (Quad9
#   upstream). It never repoints any client's resolver config; point clients at it deliberately
#   only.
#
# DNSSEC smoke scope: the checks assert the served chain (a signed answer carries AD, bogus
# data SERVFAILs) - they do not distinguish local validation from upstream-validated
# forwarding; the generator's validation knobs are sandbox/lab territory (skill
# hickory-dns-runtime).

# shellcheck disable=SC2034  # LIVE_* are the harness contract variables

hickory_digq() { # dig with bounded latency; comments (status + flags) plus answer records
  dig +time=5 +tries=1 +noall +comments +answer "$@" 2>&1
}

live_prepare() {
  local tmpfile
  [ "${LIVE_HOST_IP:-}" != "" ] || {
    echo "ERROR: the harness did not determine the dev host's IP (LIVE_HOST_IP)" >&2
    return 1
  }
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/hickory-dns-live-options.XXXXXX")
  ## A /32 duplicate of an already-covered default network is harmless (the wider entry wins);
  ## the unconditional append keeps this deterministic without CIDR math.
  yq -o json '.' "$LIVE_TEST_OPTIONS_FILE" \
    | jq -c --arg ip "$LIVE_HOST_IP/32" '.allow_networks += [$ip]' >"$tmpfile"
  echo "-- generated test options: repo defaults + $LIVE_HOST_IP/32 for the dev-host queries"
  LIVE_TEST_OPTIONS_FILE="$tmpfile"
  export LIVE_TEST_OPTIONS_FILE
}

live_runtime_check() {
  local fails=0 logs seg bad out count deadline
  local -r launch_line='Starting hickory-dns as nobody (65534) with ambient CAP_NET_BIND_SERVICE'
  local -r uid_line='now running as uid: 65534, gid: 65534 (euid: 65534, egid: 65534)'

  # --- current-boot log segment (all process-level evidence lives here) --------------------------
  logs=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" "ha apps logs $LIVE_LOCAL_SLUG" 2>/dev/null) || logs=""
  [ "$logs" != "" ] || {
    echo "FAIL: could not read the app log on $LIVE_HOST (has the app ever started?)" >&2
    return 1
  }
  ## `ha apps logs` accumulates across container boots - anchor on the cont-init banner (hd-idle
  ## precedent): the last boot's segment only. cont-init runs once per container boot; s6
  ## restarting the longrun service appends to the SAME segment (launch-line counting catches it).
  seg=$(awk '/Configuring hickory-dns/{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$logs")
  [ "$seg" != "" ] || {
    echo "FAIL: the app log has no 'Configuring hickory-dns...' boot banner (unexpected log shape)" >&2
    ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" "ha apps logs $LIVE_LOCAL_SLUG" 2>/dev/null \
      | tail -15 | awk '{print "         " $0}' >&2
    return 1
  }

  # --- launcher path + daemon credentials (log-asserted; the AppArmor device-only item) ----------
  echo "-- launcher and daemon credentials (current boot, log-asserted)"
  count=$(grep -cF "$launch_line" <<<"$seg") || count=0
  if [ "$count" -eq 1 ]; then
    echo "   PASS: the launcher ran setpriv exactly once: nobody (65534) with ambient CAP_NET_BIND_SERVICE"
  elif [ "$count" -gt 1 ]; then
    echo "   FAIL: $count launch lines in the current boot - s6 restart-looping (a launcher step is" >&2
    echo "         failing under AppArmor enforcement, or the daemon keeps dying); log tail:" >&2
    tail -15 <<<"$seg" | awk '{print "         " $0}' >&2
    return 1
  else
    echo "   FAIL: no launcher line in the current boot (the hickory-dns service never started)" >&2
    tail -15 <<<"$seg" | awk '{print "         " $0}' >&2
    return 1
  fi
  count=$(grep -cF "$uid_line" <<<"$seg") || count=0
  if [ "$count" -eq 1 ]; then
    echo "   PASS: the daemon itself logged its dropped credentials: uid/gid 65534 (nobody)"
  else
    echo "   FAIL: the daemon's uid/gid assertion appeared $count times (expected exactly 1)" >&2
    fails=$((fails + 1))
  fi
  if grep -qF 'server starting up, awaiting connections...' <<<"$seg"; then
    echo "   PASS: the daemon reached its serving state"
  else
    echo "   FAIL: no daemon startup banner in the current boot (it died before serving)" >&2
    fails=$((fails + 1))
  fi

  # --- readiness gate (static leaf zone: no upstream dependency) ---------------------------------
  echo "-- readiness: $LIVE_DEVICE_IP serves live-check.test (60s window)"
  deadline=$((SECONDS + 60))
  while :; do
    out=$(hickory_digq "@$LIVE_DEVICE_IP" live-check.test A) || true
    grep -q '192\.0\.2\.1' <<<"$out" && break
    [ "$SECONDS" -lt "$deadline" ] || {
      echo "   FAIL: the daemon never served the static leaf zone; app log tail:" >&2
      tail -15 <<<"$seg" | awk '{print "         " $0}' >&2
      return 1
    }
    sleep 3
  done
  echo "   PASS: static leaf zone served (authoritative; $LIVE_HOST_IP passed the client ACL)"

  # --- dig checks from the dev host (the LAN-client path; also the :53 bind proofs) ---------------
  echo "-- dig checks from the dev host ($LIVE_HOST_IP -> $LIVE_DEVICE_IP:53)"

  ## The +dnssec checks come first so the signed answers are freshly fetched (with DO) from the
  ## still-empty cache of the just-booted daemon. The AD-check name must be a SIGNED zone - an
  ## unsigned domain (e.g. wikipedia.org, verified via Quad9: no DNSKEY) correctly carries no AD.
  out=$(hickory_digq +dnssec "@$LIVE_DEVICE_IP" www.ietf.org A)
  if grep -E 'flags:.*[[:space:]]ad[; ]' <<<"$out" >/dev/null; then
    echo "   PASS: the validated signed answer carries the AD flag (local validation via the embedded root KSKs)"
  else
    echo "   FAIL: no AD flag on the signed answer (www.ietf.org) - flags line:" >&2
    grep 'flags:' <<<"$out" | awk '{print "         " $0}' >&2
    fails=$((fails + 1))
  fi

  out=$(hickory_digq "@$LIVE_DEVICE_IP" dnssec-failed.org A)
  if grep -q 'status: SERVFAIL' <<<"$out"; then
    echo "   PASS: dnssec-failed.org SERVFAILs (bogus data is not served)"
  else
    echo "   FAIL: dnssec-failed.org did not SERVFAIL (bogus data served? validation broken?) - status:" >&2
    grep 'status:' <<<"$out" | awk '{print "         " $0}' >&2
    fails=$((fails + 1))
  fi

  out=$(hickory_digq "@$LIVE_DEVICE_IP" wikipedia.org A)
  if grep -q 'status: NOERROR' <<<"$out" && grep -qE 'IN[[:space:]]+A[[:space:]]' <<<"$out"; then
    echo "   PASS: UDP :53 answered, wikipedia.org A resolved (bind + upstream forwarding work)"
  else
    echo "   FAIL: wikipedia.org A not resolved - upstream (Quad9) reachable from the device? output:" >&2
    awk '{print "         " $0}' <<<"$out" >&2
    fails=$((fails + 1))
  fi

  out=$(hickory_digq +tcp "@$LIVE_DEVICE_IP" example.com A)
  if grep -q 'status: NOERROR' <<<"$out" && grep -qE 'IN[[:space:]]+A[[:space:]]' <<<"$out"; then
    echo "   PASS: the TCP :53 listener answered"
  else
    echo "   FAIL: the TCP query failed - output:" >&2
    awk '{print "         " $0}' <<<"$out" >&2
    fails=$((fails + 1))
  fi

  out=$(hickory_digq "@$LIVE_DEVICE_IP" localhost A)
  if grep -qE 'IN[[:space:]]+A[[:space:]]+127\.0\.0\.1' <<<"$out"; then
    echo "   PASS: localhost A = 127.0.0.1 (shipped default zone)"
  else
    echo "   FAIL: localhost A not answered with 127.0.0.1 - output:" >&2
    awk '{print "         " $0}' <<<"$out" >&2
    fails=$((fails + 1))
  fi

  # --- loopback path (the healthcheck's exact query shape, log-asserted) --------------------------
  echo "-- loopback serving (healthcheck probes: localhost A via 127.0.0.1)"
  if grep -Eq 'src:udp://127\.0\.0\.1.*response:NoError' <<<"$seg"; then
    echo "   PASS: the healthcheck's loopback queries are served (NoError; ACL + catalog + UDP path)"
  else
    echo "   FAIL: no served loopback query in the current boot's log (healthcheck probes failing?)" >&2
    fails=$((fails + 1))
  fi

  # --- app-log hygiene for the CURRENT boot ------------------------------------------------------
  echo "-- app-log hygiene (current boot only)"
  ## hickory logs a response:NoError INFO line per served query - exclude those from the
  ## error/denial match (NoError contains "error").
  bad=$(grep -Ei 'error|denied|failed|permission' <<<"$seg" | grep -Evi 'noerror') || bad=""
  if [ "$bad" = "" ]; then
    echo "   PASS: no error/denial lines in the current boot's app log"
  else
    echo "   FAIL: error/denial lines in the current boot's app log:" >&2
    awk '{print "         " $0}' <<<"$bad" >&2
    fails=$((fails + 1))
  fi

  # --- host journal: AppArmor must stay silent ---------------------------------------------------
  echo "-- host journal AppArmor lines"
  bad=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
    "ha host logs 2>/dev/null | grep -i apparmor | tail -5") || bad=""
  if [ "$bad" = "" ]; then
    echo "   PASS: no AppArmor lines in the host journal (HAOS emits none when all is well)"
  else
    echo "   FAIL: AppArmor lines in the host journal - profile gap or unrelated anomaly:" >&2
    awk '{print "         " $0}' <<<"$bad" >&2
    fails=$((fails + 1))
  fi

  [ "$fails" -eq 0 ] || {
    echo "ERROR: $fails hickory-dns live check(s) failed" >&2
    return 1
  }
  return 0
}
