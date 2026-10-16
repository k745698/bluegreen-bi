#!/usr/bin/env bash
# Runs deploy.sh, rollback.sh, deploy_naive.sh and run_experiment.sh against a
# stub kubectl (and stub docker) in a temp directory, so the script logic can be
# checked without a cluster. kubectl apply -k layers are still rendered with the
# real `kubectl kustomize`, and port-forward is replaced by a tiny local server
# that answers like the new colour's pods would.
#
# Usage: ./tests/scripts_test.sh        (needs kubectl, python3, curl on PATH)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
REAL_KUBECTL="$(command -v kubectl)" || { echo "kubectl is needed for kustomize rendering" >&2; exit 1; }
WORK="$(mktemp -d)"
STATE="${WORK}/state"; BIN="${WORK}/bin"
mkdir -p "${STATE}" "${BIN}"
SVC_PID=""
trap 'if [ -n "${SVC_PID}" ]; then kill "${SVC_PID}" 2>/dev/null; wait "${SVC_PID}" 2>/dev/null; fi; [ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK}"' EXIT
export STATE REAL_KUBECTL

# --- fake pods/Service: answers /version from the stub's state --------------
cat > "${BIN}/fake_portal.py" <<'EOF'
"""fake_portal.py <port> <colour|service>: serves like the portal would."""
import json, os, re, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = os.environ["STATE"]
PORT, TARGET = int(sys.argv[1]), sys.argv[2]


def read(name, default=""):
    try:
        return open(os.path.join(STATE, name)).read().strip()
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        color = TARGET if TARGET != "service" else read("svc_color")
        if TARGET == "service" and time.time() < float(read("down_until", "0")):
            return self.send(503, {"error": "no endpoints"})
        rendered = read(f"rendered-bi-portal-{color}.yaml")
        m = re.search(r"APP_VERSION: (\S+)", rendered)
        version = m.group(1).strip('"') if m else "?"
        if os.environ.get("STUB_WRONG_VERSION") == "1":
            version = "something-else"
        if self.path == "/healthz":
            return self.send(200, {"status": "ok"})
        if self.path == "/version":
            return self.send(200, {"color": color, "version": version})
        if self.path == "/powerbi-check":
            if os.environ.get("STUB_POWERBI_DOWN") == "1":
                return self.send(503, {"reachable": False})
            return self.send(200, {"reachable": True})
        self.send(404, {})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
EOF

# --- stub kubectl ------------------------------------------------------------
cat > "${BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -u
echo "kubectl $*" >> "${STATE}/calls.log"
case "$1 ${2:-}" in
  "create configmap") echo "apiVersion: v1"; echo "kind: ConfigMap" ;;
  "apply -f")
    if [ "$3" = "-" ]; then cat > /dev/null; exit 0; fi
    grep -q "kind: Service" "$3" && sed -n 's/^ *color: *//p' "$3" > "${STATE}/svc_color" ;;
  "apply -k")
    out="$("${REAL_KUBECTL}" kustomize "$3")" || { echo "stub: kustomize failed" >&2; exit 1; }
    name="$(printf '%s\n' "${out}" | awk '/^kind: Deployment/{d=1} d && /^  name:/{print $2; exit}')"
    printf '%s\n' "${out}" > "${STATE}/rendered-${name}.yaml"
    printf '%s\n' "${out}" | sed -n 's/^  replicas: //p' > "${STATE}/replicas-${name}"
    echo "deployment.apps/${name} configured" ;;
  "get svc")
    [ -s "${STATE}/svc_color" ] || { echo 'Error from server (NotFound): services "bi-portal" not found' >&2; exit 1; }
    case "$*" in *jsonpath*) cat "${STATE}/svc_color" ;; *) echo "bi-portal" ;; esac ;;
  "get deployment")
    name="${3#deployment/}"; name="${name#deployment }"
    [ -f "${STATE}/rendered-${name}.yaml" ] || { echo "Error from server (NotFound)" >&2; exit 1; }
    case "$*" in *strategy*) sed -n 's/^    type: //p' "${STATE}/rendered-${name}.yaml" ;; esac ;;
  "get deployment/"*)
    name="${2#deployment/}"
    [ -f "${STATE}/rendered-${name}.yaml" ] || { echo "Error from server (NotFound)" >&2; exit 1; } ;;
  "rollout status")
    name="${3#deployment/}"
    if grep -q 'BREAK_RELEASE: "true"' "${STATE}/rendered-${name}.yaml"; then
      echo "error: timed out waiting for the condition" >&2; exit 1
    fi
    # Recreate: no pods at all for a moment, as on a real cluster.
    if grep -q "type: Recreate" "${STATE}/rendered-${name}.yaml" && [ -f "${STATE}/naive_up" ]; then
      python3 -c 'import time; print(time.time() + 1.0)' > "${STATE}/down_until"; sleep 1.5
    fi
    [ "${name}" = bi-portal-naive ] && touch "${STATE}/naive_up"
    echo "deployment \"${name}\" successfully rolled out" ;;
  "patch svc")
    printf '%s' "$*" | sed -n 's/.*"color":"\([a-z]*\)".*/\1/p' > "${STATE}/svc_color" ;;
  "scale deployment/"*)
    name="${2#deployment/}"; echo "${3#--replicas=}" > "${STATE}/replicas-${name}" ;;
  "delete deployment")
    rm -f "${STATE}/rendered-$3.yaml" "${STATE}/replicas-$3" "${STATE}/naive_up" ;;
  "port-forward deployment/"*)
    color="${2#deployment/bi-portal-}"; port="${3%%:*}"
    echo $$ > "${STATE}/pf.pid"
    exec python3 "$(dirname "$0")/fake_portal.py" "${port}" "${color}" ;;
  *) echo "stub kubectl: unhandled: $*" >&2; exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "docker $*" >> "${STATE}/calls.log"\n' > "${BIN}/docker"
chmod +x "${BIN}/kubectl" "${BIN}/docker"
export PATH="${BIN}:${PATH}"
export POWERBI_EMBED_URL="https://app.powerbi.com/reportEmbed?reportId=test"

# --- assertions ----------------------------------------------------------------
PASS=0; FAIL=0
check() {  # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok   ${desc}"; else FAIL=$((FAIL + 1)); echo "  FAIL ${desc}"; fi
}
svc() { cat "${STATE}/svc_color" 2>/dev/null; }
replicas() { cat "${STATE}/replicas-$1" 2>/dev/null; }
pf_gone() { local pid; pid="$(cat "${STATE}/pf.pid" 2>/dev/null)"; [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; }
no_leftovers() { ! ls -d k8s/.release-* >/dev/null 2>&1; }
run() {  # run <log name> <command...>: runs and records exit code in RC
  local name="$1"; shift
  "$@" > "${WORK}/${name}.out" 2>&1; RC=$?
}
patches() { grep -c "patch svc" "${STATE}/calls.log" || true; }

echo "1. first deploy"
: > "${STATE}/calls.log"
run first ./scripts/deploy.sh bi-portal:v1 v1
check "exits 0" [ "${RC}" = 0 ]
check "Service created on blue" [ "$(svc)" = blue ]
check "blue has 2 replicas" [ "$(replicas bi-portal-blue)" = 2 ]
check "rendered image bi-portal:v1" grep -q "image: bi-portal:v1" "${STATE}/rendered-bi-portal-blue.yaml"
check "used kubectl apply -k" grep -q "apply -k k8s/.release-" "${STATE}/calls.log"
check "smoke test ran" grep -q "smoke test: /version ok (blue v1)" "${WORK}/first.out"
check "port-forward cleaned up" pf_gone
check "no k8s/.release-* left behind" no_leftovers

echo "2. cutover to green"
run cutover ./scripts/deploy.sh bi-portal:v2 v2
check "exits 0" [ "${RC}" = 0 ]
check "Service now on green" [ "$(svc)" = green ]
check "green rendered as v2 with color label" grep -q "color: green" "${STATE}/rendered-bi-portal-green.yaml"
check "blue kept at full REPLICAS (2)" [ "$(replicas bi-portal-blue)" = 2 ]
check "port-forward cleaned up" pf_gone

echo "3. failed new colour (BREAK_RELEASE) leaves traffic unchanged"
before="$(patches)"
run broken ./scripts/deploy.sh bi-portal:v3 v3 true
check "exits non-zero" [ "${RC}" != 0 ]
check "Service still on green" [ "$(svc)" = green ]
check "no selector patch" [ "$(patches)" = "${before}" ]
check "clear message" grep -q "Traffic stays on green" "${WORK}/broken.out"
check "no k8s/.release-* left behind" no_leftovers

echo "4a. failed smoke test (/powerbi-check) blocks cutover"
before="$(patches)"
STUB_POWERBI_DOWN=1 run smoke_pbi ./scripts/deploy.sh bi-portal:v4 v4
check "exits non-zero" [ "${RC}" != 0 ]
check "Service still on green" [ "$(svc)" = green ]
check "no selector patch" [ "$(patches)" = "${before}" ]
check "clear message" grep -q "smoke test on blue failed. Traffic stays on green" "${WORK}/smoke_pbi.out"
check "port-forward cleaned up by trap" pf_gone

echo "4b. failed smoke test (wrong /version) blocks cutover"
STUB_WRONG_VERSION=1 run smoke_ver ./scripts/deploy.sh bi-portal:v5 v5
check "exits non-zero" [ "${RC}" != 0 ]
check "Service still on green" [ "$(svc)" = green ]
check "names the mismatch" grep -q "expected 'blue v5'" "${WORK}/smoke_ver.out"
check "port-forward cleaned up by trap" pf_gone

echo "5. rollback"
run rollback ./scripts/rollback.sh
check "exits 0" [ "${RC}" = 0 ]
check "Service back on blue" [ "$(svc)" = blue ]
check "prints ROLLBACK_SECONDS" grep -qE "^ROLLBACK_SECONDS=[0-9]+\.[0-9]+$" "${WORK}/rollback.out"

echo "6. KEEP_REPLICAS=1 and CLEANUP=true"
KEEP_REPLICAS=1 run keep ./scripts/deploy.sh bi-portal:v6 v6
check "cutover to green" [ "$(svc)" = green ]
check "blue scaled to 1" [ "$(replicas bi-portal-blue)" = 1 ]
CLEANUP=true run cleanup ./scripts/deploy.sh bi-portal:v7 v7
check "cutover to blue" [ "$(svc)" = blue ]
check "green deleted" [ ! -f "${STATE}/rendered-bi-portal-green.yaml" ]
run rollback2 ./scripts/rollback.sh
check "rollback refuses with nothing to flip to" [ "${RC}" != 0 ]
check "Service still on blue" [ "$(svc)" = blue ]

echo "7. REPORT_PAGE / REPORT_ID reach the release ConfigMap"
REPORT_ID=r2 REPORT_PAGE=ReportSection2 run report ./scripts/deploy.sh bi-portal:v8 v8
check "REPORT_PAGE rendered" grep -q "REPORT_PAGE: ReportSection2" "${STATE}/rendered-bi-portal-green.yaml"
check "REPORT_ID rendered" grep -q "REPORT_ID: r2" "${STATE}/rendered-bi-portal-green.yaml"

echo "8. naive baseline"
run naive ./scripts/deploy_naive.sh registry.local:5000/bi-portal:v1 v1
check "exits 0" [ "${RC}" = 0 ]
check "Recreate strategy" grep -q "type: Recreate" "${STATE}/rendered-bi-portal-naive.yaml"
check "registry port kept in image name" grep -q "image: registry.local:5000/bi-portal:v1" "${STATE}/rendered-bi-portal-naive.yaml"
check "naive Service on 8081" grep -q "port: 8081" "${STATE}/rendered-bi-portal-naive.yaml"
STRATEGY=RollingUpdate run naive_rolling ./scripts/deploy_naive.sh bi-portal:v2 v2
check "RollingUpdate strategy" grep -q "type: RollingUpdate" "${STATE}/rendered-bi-portal-naive.yaml"

echo "9. run_experiment.sh (fast settings, fake Service on a local port)"
SVC_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "${BIN}/fake_portal.py" "${SVC_PORT}" service & SVC_PID=$!
export BASE_URL="http://127.0.0.1:${SVC_PORT}" WARMUP=1 SETTLE=1
rm -rf results.test; mkdir results.test
for scenario in blue-green rollback naive-recreate failed-release; do
  run "exp-${scenario}" ./scripts/run_experiment.sh "${scenario}" 2
  dir="$(ls -d results/${scenario}-* 2>/dev/null | tail -1)"
  check "${scenario}: exits 0" [ "${RC}" = 0 ]
  check "${scenario}: 2 run CSVs" [ "$(ls "${dir}"/run-*.csv 2>/dev/null | wc -l | tr -d ' ')" = 2 ]
  check "${scenario}: summary.csv has 3 metrics" [ "$(wc -l < "${dir}/summary.csv" | tr -d ' ')" = 4 ]
  echo "       summary: $(tr '\n' ' ' < "${dir}/summary.csv")"
  mv "${dir}" results.test/
done
d="$(ls -d results.test/rollback-*)"
check "rollback: rollback_s measured for both runs" grep -q "^rollback_s,2," "${d}/summary.csv"
d="$(ls -d results.test/naive-recreate-*)"
check "naive-recreate: outage visible as failures" awk -F, 'NR>1 && $4 > 0 {f=1} END {exit !f}' "${d}/runs.csv"
d="$(ls -d results.test/blue-green-*)"
check "blue-green: no failed requests" awk -F, 'NR>1 && $4 != 0 {f=1} END {exit f}' "${d}/runs.csv"
d="$(ls -d results.test/failed-release-*)"
check "failed-release: deploy exit codes non-zero" awk -F, 'NR>1 && $2 == 0 {f=1} END {exit f}' "${d}/runs.csv"
rm -rf results.test
rmdir results 2>/dev/null || true

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = 0 ]
