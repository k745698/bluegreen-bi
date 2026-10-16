#!/usr/bin/env bash
# Blue-green deploy. Deploys <image> to whichever colour is idle, waits for its
# readiness probes, smoke-tests it directly, then flips the Service selector.
# Traffic only moves if the new colour is healthy and passes the smoke test;
# otherwise the live colour is left untouched.
#
# Usage: POWERBI_EMBED_URL=<secure embed link> ./scripts/deploy.sh <image> <version> [break=false]
#
# Optional environment:
#   REPLICAS=2          pods for the new colour
#   KEEP_REPLICAS=$REPLICAS
#                       pods left on the previous colour after cutover (the rollback
#                       target). Full size by default so rollback is a selector flip.
#   CLEANUP=true        delete the previous colour after a successful cutover
#                       (saves resources, but rollback.sh then has nothing to flip to)
#   REPORT_ID, REPORT_PAGE
#                       which Power BI report / page this release embeds
#   ROLLOUT_TIMEOUT=120s
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE="${1:?usage: deploy.sh <image> <version> [break]}"
VERSION="${2:?usage: deploy.sh <image> <version> [break]}"
BREAK="${3:-false}"
REPLICAS="${REPLICAS:-2}"
KEEP_REPLICAS="${KEEP_REPLICAS:-${REPLICAS}}"
CLEANUP="${CLEANUP:-false}"
TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

ensure_config

LIVE="$(kubectl get svc bi-portal -o jsonpath='{.spec.selector.color}' 2>/dev/null || true)"
if [ -z "${LIVE}" ]; then
  NEW="blue"; FIRST=1
elif [ "${LIVE}" = "blue" ]; then
  NEW="green"; FIRST=0
else
  NEW="blue"; FIRST=0
fi
log "live=${LIVE:-none} -> deploying ${VERSION} to ${NEW}"

apply_release "${NEW}" "bi-portal-${NEW}"

if ! kubectl rollout status "deployment/bi-portal-${NEW}" --timeout="${TIMEOUT}"; then
  log "FAILED: ${NEW} did not become ready. Traffic stays on ${LIVE:-nothing}."
  log "Inspect with: kubectl describe pods -l color=${NEW}  |  kubectl logs -l color=${NEW}"
  exit 1
fi
log "${NEW} is ready"

if ! smoke_test "${NEW}" "${VERSION}"; then
  log "FAILED: smoke test on ${NEW} failed. Traffic stays on ${LIVE:-nothing}."
  exit 1
fi

if [ "${FIRST}" = "1" ]; then
  kubectl apply -f k8s/service.yaml
  log "first deploy: Service created pointing at ${NEW}"
else
  log "CUTOVER: ${LIVE} -> ${NEW}"
  kubectl patch svc bi-portal --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"bi-portal\",\"color\":\"${NEW}\"}}}"
  log "CUTOVER DONE"
  if [ "${CLEANUP}" = "true" ]; then
    kubectl delete deployment "bi-portal-${LIVE}" --ignore-not-found
    log "CLEANUP: deleted ${LIVE} (no rollback target left)"
  else
    # Keep the previous colour as the rollback target.
    kubectl scale "deployment/bi-portal-${LIVE}" --replicas="${KEEP_REPLICAS}"
    log "${LIVE} kept at ${KEEP_REPLICAS} replica(s) as the rollback target"
  fi
fi
log "live colour is now ${NEW} (release ${VERSION})"
