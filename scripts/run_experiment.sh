#!/usr/bin/env bash
# Repeat one deployment scenario under load and collect the numbers.
#
# Usage: POWERBI_EMBED_URL=<link> ./scripts/run_experiment.sh <scenario> <runs>
#   scenario: blue-green | naive-recreate | naive-rolling | failed-release | rollback
#
# Each run: start loadtest/gap_logger.py, wait WARMUP seconds, trigger the deploy,
# wait for it to finish, wait SETTLE seconds, stop the logger. Output goes to
# results/<scenario>-<timestamp>/:
#   run-<n>.csv, run-<n>.csv.summary.json   gap logger request log and summary
#   run-<n>.deploy.txt                       deploy/rollback script output
#   runs.csv                                 one row per run
#   summary.csv                              mean and standard deviation per metric
#
# Optional environment:
#   IMAGE=bi-portal:v1   image to release; each run re-tags it with a fresh version
#                        tag (a new tag is what makes Kubernetes roll the pods)
#   BASE_URL             defaults to http://localhost:8080 (8081 for naive-*)
#   WARMUP=15  SETTLE=5  seconds of load before the deploy and after it finishes
#   WITH_K6=true         also run loadtest/k6.js (unchanged) per run as a second source;
#                        K6_DURATION (default 60s) must cover WARMUP + deploy + SETTLE
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

SCENARIO="${1:?usage: run_experiment.sh <blue-green|naive-recreate|naive-rolling|failed-release|rollback> <runs>}"
RUNS="${2:?usage: run_experiment.sh <scenario> <runs>}"
: "${POWERBI_EMBED_URL:?set POWERBI_EMBED_URL}"
IMAGE="${IMAGE:-bi-portal:v1}"
WARMUP="${WARMUP:-15}"
SETTLE="${SETTLE:-5}"
WITH_K6="${WITH_K6:-false}"

case "${SCENARIO}" in
  blue-green|failed-release|rollback) BASE_URL="${BASE_URL:-http://localhost:8080}" ;;
  naive-recreate) BASE_URL="${BASE_URL:-http://localhost:8081}"; export STRATEGY=Recreate ;;
  naive-rolling)  BASE_URL="${BASE_URL:-http://localhost:8081}"; export STRATEGY=RollingUpdate ;;
  *) echo "unknown scenario: ${SCENARIO}" >&2; exit 2 ;;
esac

OUT_DIR="results/${SCENARIO}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT_DIR}"
echo "run,exit_code,requests,failures,longest_gap_ms,switch_time,rollback_seconds" > "${OUT_DIR}/runs.csv"

# A fresh tag per release; Docker Desktop's cluster shares the local image store.
new_release() {
  RELEASE_VERSION="exp-$(date +%H%M%S)-$1"
  RELEASE_IMAGE="bi-portal:${RELEASE_VERSION}"
  docker tag "${IMAGE}" "${RELEASE_IMAGE}"
}

# Setup (not measured): make sure there is something live to update.
case "${SCENARIO}" in
  blue-green|failed-release|rollback)
    if ! kubectl get svc bi-portal >/dev/null 2>&1; then
      log "setup: no live blue-green Service, deploying an initial release"
      new_release setup; ./scripts/deploy.sh "${RELEASE_IMAGE}" "${RELEASE_VERSION}"
    fi
    if [ "${SCENARIO}" = "rollback" ]; then
      LIVE="$(kubectl get svc bi-portal -o jsonpath='{.spec.selector.color}')"
      if [ "${LIVE}" = "blue" ]; then IDLE=green; else IDLE=blue; fi
      if ! kubectl get "deployment/bi-portal-${IDLE}" >/dev/null 2>&1; then
        log "setup: no ${IDLE} deployment to roll back to, deploying a second release"
        new_release setup2; ./scripts/deploy.sh "${RELEASE_IMAGE}" "${RELEASE_VERSION}"
      fi
    fi
    ;;
  naive-*)
    current="$(kubectl get deployment bi-portal-naive -o jsonpath='{.spec.strategy.type}' 2>/dev/null || true)"
    if [ -n "${current}" ] && [ "${current}" != "${STRATEGY}" ]; then
      log "setup: bi-portal-naive uses ${current}; recreating it with ${STRATEGY}"
      kubectl delete deployment bi-portal-naive
      current=""
    fi
    if [ -z "${current}" ]; then
      log "setup: deploying an initial naive release"
      new_release setup; ./scripts/deploy_naive.sh "${RELEASE_IMAGE}" "${RELEASE_VERSION}"
    fi
    ;;
esac

LOGGER_PID=""
K6_PID=""
stop_load() {
  if [ -n "${LOGGER_PID}" ]; then kill -TERM "${LOGGER_PID}" 2>/dev/null || true; wait "${LOGGER_PID}" || true; fi
  if [ -n "${K6_PID}" ]; then wait "${K6_PID}" || true; fi
  LOGGER_PID=""; K6_PID=""
}
trap 'stop_load; on_exit' EXIT

i=1
while [ "${i}" -le "${RUNS}" ]; do
  log "=== ${SCENARIO} run ${i}/${RUNS}"
  csv="${OUT_DIR}/run-${i}.csv"
  BASE_URL="${BASE_URL}" DURATION=3600 OUT="${csv}" python3 loadtest/gap_logger.py > "${OUT_DIR}/run-${i}.logger.txt" &
  LOGGER_PID=$!
  if [ "${WITH_K6}" = "true" ]; then
    BASE_URL="${BASE_URL}" DURATION="${K6_DURATION:-60s}" \
      k6 run --summary-export "${OUT_DIR}/run-${i}.k6.json" loadtest/k6.js > "${OUT_DIR}/run-${i}.k6.txt" 2>&1 &
    K6_PID=$!
  fi
  sleep "${WARMUP}"

  rc=0
  case "${SCENARIO}" in
    blue-green)
      new_release "${i}"; ./scripts/deploy.sh "${RELEASE_IMAGE}" "${RELEASE_VERSION}" > "${OUT_DIR}/run-${i}.deploy.txt" 2>&1 || rc=$? ;;
    failed-release)
      new_release "${i}"; ./scripts/deploy.sh "${RELEASE_IMAGE}" "${RELEASE_VERSION}" true > "${OUT_DIR}/run-${i}.deploy.txt" 2>&1 || rc=$? ;;
    naive-*)
      new_release "${i}"; ./scripts/deploy_naive.sh "${RELEASE_IMAGE}" "${RELEASE_VERSION}" > "${OUT_DIR}/run-${i}.deploy.txt" 2>&1 || rc=$? ;;
    rollback)
      ./scripts/rollback.sh > "${OUT_DIR}/run-${i}.deploy.txt" 2>&1 || rc=$? ;;
  esac
  log "deploy step exited ${rc} (see ${OUT_DIR}/run-${i}.deploy.txt)"

  sleep "${SETTLE}"
  stop_load
  cat "${OUT_DIR}/run-${i}.logger.txt"

  rollback_s="$(sed -n 's/^ROLLBACK_SECONDS=//p' "${OUT_DIR}/run-${i}.deploy.txt")"
  python3 - "${csv}.summary.json" "${i}" "${rc}" "${rollback_s}" >> "${OUT_DIR}/runs.csv" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
gap = "" if s["longest_gap_ms"] is None else s["longest_gap_ms"]
switch = "" if s["switch_time"] is None else f'{s["switch_time"]:.3f}'
print(f'{sys.argv[2]},{sys.argv[3]},{s["total"]},{s["failures"]},{gap},{switch},{sys.argv[4]}')
EOF
  i=$((i + 1))
done

python3 - "${OUT_DIR}/runs.csv" > "${OUT_DIR}/summary.csv" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
metrics = [("downtime_s (longest gap)", "longest_gap_ms", 0.001),
           ("failures", "failures", 1),
           ("rollback_s", "rollback_seconds", 1)]
print("metric,n,mean,stdev")
for label, column, scale in metrics:
    values = [float(r[column]) * scale for r in rows if r[column] != ""]
    if not values:
        print(f"{label},0,,")
        continue
    stdev = statistics.stdev(values) if len(values) > 1 else 0.0
    print(f"{label},{len(values)},{statistics.mean(values):.3f},{stdev:.3f}")
EOF

if [ "${SCENARIO}" = "failed-release" ]; then
  log "note: the idle colour now runs the broken release; deploy a good release to replace it"
fi
log "results in ${OUT_DIR}"
cat "${OUT_DIR}/summary.csv"
