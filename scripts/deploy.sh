#!/usr/bin/env bash
# Blue-green deploy. Deploys <image> to whichever colour is idle, waits for its
# readiness probes, then flips the Service selector. Traffic only moves if the
# new colour is healthy; otherwise the live colour is left untouched.
#
# Usage: POWERBI_EMBED_URL=<secure embed link> ./scripts/deploy.sh <image> <version> [break=false]
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:?usage: deploy.sh <image> <version> [break]}"
VERSION="${2:?usage: deploy.sh <image> <version> [break]}"
BREAK="${3:-false}"
: "${POWERBI_EMBED_URL:?set POWERBI_EMBED_URL to the Power BI secure embed link}"
REPLICAS="${REPLICAS:-2}"
TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

render_deployment() {
  sed -e "s|__COLOR__|$1|g" -e "s|__IMAGE__|${IMAGE}|g" -e "s|__VERSION__|${VERSION}|g" \
      -e "s|__BREAK__|${BREAK}|g" -e "s|__REPLICAS__|${REPLICAS}|g" k8s/deployment.tpl.yaml
}

# Embed link lives in a ConfigMap so it never gets spliced into YAML text.
kubectl create configmap bi-config \
  --from-literal=POWERBI_EMBED_URL="${POWERBI_EMBED_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

LIVE="$(kubectl get svc bi-portal -o jsonpath='{.spec.selector.color}' 2>/dev/null || true)"
if [ -z "${LIVE}" ]; then
  NEW="blue"; FIRST=1
elif [ "${LIVE}" = "blue" ]; then
  NEW="green"; FIRST=0
else
  NEW="blue"; FIRST=0
fi
log "live=${LIVE:-none} -> deploying ${VERSION} to ${NEW}"

render_deployment "${NEW}" | kubectl apply -f -

if ! kubectl rollout status "deployment/bi-portal-${NEW}" --timeout="${TIMEOUT}"; then
  log "FAILED: ${NEW} did not become ready. Traffic stays on ${LIVE:-nothing}."
  log "Inspect with: kubectl describe pods -l color=${NEW}  |  kubectl logs -l color=${NEW}"
  exit 1
fi
log "${NEW} is ready"

if [ "${FIRST}" = "1" ]; then
  sed -e "s|__COLOR__|${NEW}|g" k8s/service.tpl.yaml | kubectl apply -f -
  log "first deploy: Service created pointing at ${NEW}"
else
  log "CUTOVER: ${LIVE} -> ${NEW}"
  kubectl patch svc bi-portal --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"bi-portal\",\"color\":\"${NEW}\"}}}"
  log "CUTOVER DONE"
  # Keep the previous colour running (reduced) as the rollback target.
  kubectl scale "deployment/bi-portal-${LIVE}" --replicas=1
fi
log "live colour is now ${NEW} (release ${VERSION})"
