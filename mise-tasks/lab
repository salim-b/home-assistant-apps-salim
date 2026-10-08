#!/usr/bin/env bash
#MISE description="Full-fidelity boot lab: fake supervisor API, boot, client mount roundtrip, graceful stop"
#USAGE arg "[app]" help="App to lab-test (default: apps providing a lab fixture)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE flag "--keep" help="Keep lab containers/dirs for debugging"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

# shellcheck disable=SC2124
apps=("${usage_app:-$(git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1 | sort -u)}")

net="nfslab-$$"
tmpdir=$(mktemp -d /tmp/nfslab-XXXXXX)
fails=0

cleanup() {
  if [ "${usage_keep:-false}" != "true" ]; then
    docker rm -f "$net-fakesup" "$net-app" "$net-client" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    # root-owned leftovers in the temp dirs (created by the container) need
    # container-root privileges to remove
    docker run --rm -v "$tmpdir":/lab alpine:3.24 sh -c 'rm -rf /lab/*' >/dev/null 2>&1 || true
    rmdir "$tmpdir" 2>/dev/null || true
  else
    echo "KEEP: lab containers prefixed '$net-', dir $tmpdir"
  fi
}
trap cleanup EXIT

subnet="172.31.0.0/16"
docker network create --subnet "$subnet" "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null

for app in "${apps[@]}"; do
  version=$(yq -r '.version' "$app/config.yaml")
  echo "== lab for $app $version =="

  echo "-- fake supervisor API (serving $app/config.yaml options)"
  docker rm -f "$net-fakesup" >/dev/null 2>&1 || true
  docker run -d --name "$net-fakesup" --network "$net" \
    -v "$PWD/$app/config.yaml:/src/config.yaml:ro" \
    -e LAB_NETWORK="$subnet" alpine:3.24 sh -c '
      apk add -q python3 py3-yaml >/dev/null 2>&1
      python3 - <<PYEOF
import http.server, json, os, yaml
config = yaml.safe_load(open("/src/config.yaml"))
NET = os.environ["LAB_NETWORK"]
def adapt(value):
    # fixture adaptation: client networks point at the lab subnet
    if isinstance(value, dict):
        return {k: NET if k == "network" else adapt(value[k]) for k in value}
    if isinstance(value, list):
        return [adapt(v) for v in value]
    return value
options = adapt(config.get("options", {}))
data = json.dumps({"result": "ok", "data": options}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 8000), H).serve_forever()
PYEOF' >/dev/null

  echo "-- waiting for the fake API to be ready"
  api_ok=0
  for _ in $(seq 1 60); do
    if docker exec "$net-fakesup" sh -c 'wget -q -O- http://127.0.0.1:8000 >/dev/null 2>&1'; then api_ok=1; break; fi
    sleep 2
  done
  [ "$api_ok" = 1 ] || { echo "LAB FAILED ($app): fake API never became ready"; fails=$((fails + 1)); continue; }

  echo "-- booting the app container (full s6-rc tree, config via API)"
  docker rm -f "$net-app" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$net-app" --network "$net" \
    -v /lib/modules:/lib/modules:ro \
    -v "$tmpdir/share:/share" -v "$tmpdir/media:/media" -v "$tmpdir/data:/data" \
    -e SUPERVISOR_TOKEN=fake -e SUPERVISOR_API="http://$net-fakesup:8000" \
    "local/$app:$version" >/dev/null

  echo "-- waiting for boot"
  boot_ok=0
  for _ in $(seq 1 60); do
    if docker logs "$net-app" 2>&1 | grep -q "legacy-services successfully started"; then boot_ok=1; break; fi
    if docker inspect "$net-app" --format '{{.State.Status}}' | grep -q exited; then break; fi
    sleep 2
  done
  if [ "$boot_ok" != 1 ]; then
    echo "LAB FAILED ($app): boot did not complete"; docker logs "$net-app" 2>&1 | tail -15; fails=$((fails + 1)); continue
  fi
  if docker logs "$net-app" 2>&1 | grep -qi "deprecated\|error\|fatal"; then
    echo "LAB FAILED ($app): deprecation/error/fatal in boot log:"; docker logs "$net-app" 2>&1 | grep -iE "deprecated|error|fatal"; fails=$((fails + 1)); continue
  fi

  echo "-- client mount roundtrip"
  echo "host-file-$$" > "$tmpdir/share/nfs/hostfile.txt" 2>/dev/null \
    || { mkdir -p "$tmpdir/share/nfs" && echo "host-file-$$" > "$tmpdir/share/nfs/hostfile.txt"; }
  sip=$(docker inspect "$net-app" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  docker rm -f "$net-client" >/dev/null 2>&1 || true
  if ! docker run --rm --privileged --name "$net-client" --network "$net" alpine:3.24 sh -c "
    apk add -q nfs-utils >/dev/null 2>&1
    mkdir -p /mnt/test
    mount -t nfs4 '$sip:/share/nfs' /mnt/test || exit 10
    grep -q 'host-file-$$' /mnt/test/hostfile.txt || exit 11
    echo client-write > /mnt/test/client.txt || exit 12
    sync" ; then
    echo "LAB FAILED ($app): client roundtrip failed (rc=$?)"; fails=$((fails + 1)); continue
  fi
  grep -q "client-write" "$tmpdir/share/nfs/client.txt" \
    || { echo "LAB FAILED ($app): client write did not reach the host filesystem"; fails=$((fails + 1)); continue; }

  echo "-- graceful stop"
  docker stop -t 60 "$net-app" >/dev/null \
    || { echo "LAB FAILED ($app): graceful stop failed"; fails=$((fails + 1)); continue; }
  exit_code=$(docker inspect "$net-app" --format '{{.State.ExitCode}}')
  [ "$exit_code" = "0" ] || { echo "LAB FAILED ($app): exit code $exit_code"; fails=$((fails + 1)); continue; }

  echo "$app lab OK"
done

if [ "$fails" -gt 0 ]; then
  echo "LAB FAILED: $fails problem(s)" >&2
  exit 1
fi
echo "lab OK"
