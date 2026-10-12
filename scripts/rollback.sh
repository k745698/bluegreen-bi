#!/usr/bin/env bash
# Flip the Service back to the previous colour and restore its replica count.
# Usage: ./scripts/rollback.sh
set -euo pipefail

REPLICAS="${REPLICAS:-2}"
TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"
log() { echo "[$(date -u +%FT%TZ)] $*"; }

LIVE="$(kubectl get svc bi-portal -o jsonpath='{.spec.selector.color}')"
if [ "${LIVE}" = "blue" ]; then PREV="green"; else PREV="blue"; fi

kubectl get "deployment/bi-portal-${PREV}" >/dev/null 2>&1 || {
  echo "No ${PREV} deployment to roll back to." >&2; exit 1; }

log "rollback: ${LIVE} -> ${PREV}"
kubectl scale "deployment/bi-portal-${PREV}" --replicas="${REPLICAS}"
kubectl rollout status "deployment/bi-portal-${PREV}" --timeout="${TIMEOUT}"
kubectl patch svc bi-portal --type merge \
  -p "{\"spec\":{\"selector\":{\"app\":\"bi-portal\",\"color\":\"${PREV}\"}}}"
log "ROLLBACK DONE: live colour is ${PREV}"
