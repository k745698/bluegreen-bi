#!/usr/bin/env bash
# Flip the Service back to the previous colour, restoring its replica count first
# if it was kept smaller (KEEP_REPLICAS). Prints the seconds from start to the
# selector patch as ROLLBACK_SECONDS=<n> (read by scripts/run_experiment.sh).
# Usage: ./scripts/rollback.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

START="$(now)"
REPLICAS="${REPLICAS:-2}"
TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

LIVE="$(kubectl get svc bi-portal -o jsonpath='{.spec.selector.color}' 2>/dev/null || true)"
if [ -z "${LIVE}" ]; then echo "No bi-portal Service found; nothing to roll back." >&2; exit 1; fi
if [ "${LIVE}" = "blue" ]; then PREV="green"; else PREV="blue"; fi

kubectl get "deployment/bi-portal-${PREV}" >/dev/null 2>&1 || {
  echo "No ${PREV} deployment to roll back to (was it removed with CLEANUP=true?)." >&2; exit 1; }

log "rollback: ${LIVE} -> ${PREV}"
kubectl scale "deployment/bi-portal-${PREV}" --replicas="${REPLICAS}"
kubectl rollout status "deployment/bi-portal-${PREV}" --timeout="${TIMEOUT}"
kubectl patch svc bi-portal --type merge \
  -p "{\"spec\":{\"selector\":{\"app\":\"bi-portal\",\"color\":\"${PREV}\"}}}"
END="$(now)"
log "ROLLBACK DONE: live colour is ${PREV}"
echo "ROLLBACK_SECONDS=$(python3 -c "print(f'{${END} - ${START}:.3f}')")"
