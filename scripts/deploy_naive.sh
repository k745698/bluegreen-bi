#!/usr/bin/env bash
# Baseline: update a single Deployment in place (no blue/green).
# STRATEGY=Recreate (default) stops the old pods before starting new ones, which
# models the "take the server offline, swap, bring it back" practice.
# STRATEGY=RollingUpdate is a stronger baseline that Kubernetes does natively.
#
# Usage: POWERBI_EMBED_URL=<link> [STRATEGY=Recreate|RollingUpdate] ./scripts/deploy_naive.sh <image> <version> [break=false]
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:?usage: deploy_naive.sh <image> <version> [break]}"
VERSION="${2:?usage: deploy_naive.sh <image> <version> [break]}"
BREAK="${3:-false}"
: "${POWERBI_EMBED_URL:?set POWERBI_EMBED_URL}"
STRATEGY="${STRATEGY:-Recreate}"
REPLICAS="${REPLICAS:-2}"
TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

kubectl create configmap bi-config \
  --from-literal=POWERBI_EMBED_URL="${POWERBI_EMBED_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "naive update (${STRATEGY}) to ${VERSION}"
sed -e "s|__IMAGE__|${IMAGE}|g" -e "s|__VERSION__|${VERSION}|g" -e "s|__BREAK__|${BREAK}|g" \
    -e "s|__REPLICAS__|${REPLICAS}|g" -e "s|__STRATEGY__|${STRATEGY}|g" k8s/naive.tpl.yaml \
  | kubectl apply -f -

kubectl rollout status deployment/bi-portal-naive --timeout="${TIMEOUT}"
log "naive update finished"
