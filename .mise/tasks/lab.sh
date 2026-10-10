#!/usr/bin/env bash
#MISE description="Full-fidelity boot lab: fake supervisor API, boot, app-provided runtime check, graceful stop"
#USAGE arg "[app]" help="App to lab-test (default: all apps)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE flag "--keep" help="Keep lab containers/dirs for debugging"
#
# Per-app specifics (docker args, a runtime roundtrip) live in the
# .mise/tasks/lab/<app>.sh hook, fixture adaptation (optional) in
# .mise/tasks/lab/<app>.py - see AGENTS.md. Apps without a hook get a
# boot-only lab (config fetch via fake API, full s6-rc boot, graceful stop).
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

# shellcheck disable=SC2124
apps=("${usage_app:-$(git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1 | sort -u)}")

net="nfslab-$$"
ts() { echo "[t+${1}s] $2"; }
tmpdir=$(mktemp -d /tmp/nfslab-XXXXXX)
fails=0

## Lab convenience images (built once, reused across runs): python3+yaml for
## the fake API, plus a client image with common runtime-check tools
api_image="local/nfslab-api:alpine3.24"
client_image="local/nfslab-client:alpine3.24"
if ! docker image inspect "$api_image" >/dev/null 2>&1; then
  echo "-- building lab images (first run only)"
  docker build -q -t "$api_image" -f - . <<'EOF'
FROM alpine:3.24
RUN apk add --no-cache python3 py3-yaml
EOF
fi
if ! docker image inspect "$client_image" >/dev/null 2>&1; then
  docker build -q -t "$client_image" -f - . <<'EOF'
FROM alpine:3.24
RUN apk add --no-cache nfs-utils curl jq iputils
EOF
fi

cleanup() {
  if [ "${usage_keep:-false}" != "true" ]; then
    docker rm -f "$net-fakesup" "$net-app" "$net-client" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    # root-owned leftovers in the temp dirs (created by the container) need
    # container-root privileges to remove
    docker run --rm -v "$tmpdir":/lab "$client_image" sh -c 'rm -rf /lab/*' >/dev/null 2>&1 || true
    rmdir "$tmpdir" 2>/dev/null || true
  else
    echo "KEEP: lab containers prefixed '$net-', dir $tmpdir"
  fi
}
trap cleanup EXIT

docker network create "$net" >/dev/null
# fixture adaptation target: the actual subnet of the created network (no
# hardcoded subnet: docker's pool may be occupied, docker picks freely)
subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')

for app in "${apps[@]}"; do
  version=$(yq -r '.version' "$app/config.yaml")
  hook=".mise/tasks/lab/$app.sh"
  echo "== lab for $app $version $([ -f "$hook" ] && echo "(hook: $hook)" || echo "(boot-only, no hook)") =="

  ts "$SECONDS" "-- fake supervisor API (serving $app/config.yaml options)"
  docker rm -f "$net-fakesup" >/dev/null 2>&1 || true
  docker run -d --name "$net-fakesup" --network "$net" \
    -v "$PWD/$app/config.yaml:/src/config.yaml:ro" \
    -e LAB_NETWORK="$subnet" "$api_image" sh -c '
      python3 - <<PYEOF
import http.server, json, os, yaml
config = yaml.safe_load(open("/src/config.yaml"))
NET = os.environ["LAB_NETWORK"]

def build_options():
    """Per-request options: base options + per-app fixture adaptation (the
    fixture adapter served as /lab-hook.py defines lab_adapt_fixture)."""
    options = config.get("options", {})
    try:
        ns = {}
        exec(open("/lab-hook.py").read(), ns)
        if callable(ns.get("lab_adapt_fixture")):
            options = ns["lab_adapt_fixture"](options)
            options = json.loads(json.dumps(options).replace("LABNETWORK", NET))
    except FileNotFoundError:
        pass
    return options

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = json.dumps({"result": "ok", "data": build_options()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 8000), H).serve_forever()
PYEOF' >/dev/null

  ts "$SECONDS" "-- waiting for the fake API to be ready"
  api_ok=0
  for _ in $(seq 1 120); do
    if docker exec "$net-fakesup" sh -c 'wget -q -O- http://127.0.0.1:8000 >/dev/null 2>&1'; then api_ok=1; break; fi
    sleep 0.5
  done
  [ "$api_ok" = 1 ] || { echo "LAB FAILED ($app): fake API never became ready"; fails=$((fails + 1)); continue; }

  ts "$SECONDS" "-- booting the app container (full s6-rc tree, config via API)"
  ## App-provided docker args (volumes, capabilities, devices...); the
  ## defaults work for any app, hooks extend rather than replace them
  lab_docker_args=("-v" "$tmpdir/data:/data")
  LAB_NET_NAME="$net"; LAB_APP_DIR="$PWD/$app"; LAB_TMPDIR="$tmpdir"; LAB_SUBNET="$subnet"
  export LAB_NET_NAME LAB_APP_DIR LAB_TMPDIR LAB_SUBNET
  # Drop a previous app's hook function first: on a default all-apps run,
  # an app without a runtime check must not inherit the last app's
  unset -f lab_runtime_check 2>/dev/null || true
  if [ -f "$hook" ]; then
    # shellcheck source=/dev/null
    source "$hook"          # sets lab_docker_args (opt.)
  fi
  docker rm -f "$net-app" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$net-app" --network "$net" \
    "${lab_docker_args[@]}" \
    -e SUPERVISOR_TOKEN=fake -e SUPERVISOR_API="http://$net-fakesup:8000" \
    "local/$app:$version" >/dev/null
  # serve the app's fixture adapter to the fake API, if one exists
  # (convention over configuration: .mise/tasks/lab/<app>.py)
  fixture_py=".mise/tasks/lab/$app.py"
  if [ -f "$fixture_py" ]; then
    docker cp "$PWD/$fixture_py" "$net-fakesup:/lab-hook.py" >/dev/null
  fi

  ts "$SECONDS" "-- waiting for boot"
  boot_ok=0
  for _ in $(seq 1 240); do
    if docker logs "$net-app" 2>&1 | grep -q "legacy-services successfully started"; then boot_ok=1; break; fi
    if docker inspect "$net-app" --format '{{.State.Status}}' | grep -q exited; then break; fi
    sleep 0.5
  done
  if [ "$boot_ok" != 1 ]; then
    echo "LAB FAILED ($app): boot did not complete"; docker logs "$net-app" 2>&1 | tail -15; fails=$((fails + 1)); continue
  fi
  if docker logs "$net-app" 2>&1 | grep -qi "deprecated\|error\|fatal"; then
    echo "LAB FAILED ($app): deprecation/error/fatal in boot log:"; docker logs "$net-app" 2>&1 | grep -iE "deprecated|error|fatal"; fails=$((fails + 1)); continue
  fi

  ts "$SECONDS" "-- app runtime check"
  if [ -f "$hook" ] && declare -F lab_runtime_check >/dev/null; then
    LAB_APP_IP=$(docker inspect "$net-app" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    export LAB_APP_IP
    if ! lab_runtime_check; then
      echo "LAB FAILED ($app): runtime check failed"; fails=$((fails + 1)); continue
    fi
  else
    echo "(no hook: boot-only lab)"
  fi

  ts "$SECONDS" "-- graceful stop"
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
