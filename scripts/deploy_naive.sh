#!/usr/bin/env bash
# Baseline: update a single Deployment in place (no blue/green).
# STRATEGY=Recreate (default) stops the old pods before starting new ones, which
# models the "take the server offline, swap, bring it back" practice.
# STRATEGY=RollingUpdate is a stronger baseline that Kubernetes does natively.
#
# Usage: POWERBI_EMBED_URL=<link> [STRATEGY=Recreate|RollingUpdate] ./scripts/deploy_naive.sh <image> <version> [break=false]
#
# Switching an existing Deployment between strategies can be rejected by the API
# server; delete it first: kubectl delete deployment bi-portal-naive
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE="${1:?usage: deploy_naive.sh <image> <version> [break]}"
VERSION="${2:?usage: deploy_naive.sh <image> <version> [break]}"
BREAK="${3:-false}"
STRATEGY="${STRATEGY:-Recreate}"
REPLICAS="${REPLICAS:-2}"
TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

ensure_config

log "naive update (${STRATEGY}) to ${VERSION}"
apply_release naive bi-portal-naive

kubectl rollout status deployment/bi-portal-naive --timeout="${TIMEOUT}"
log "naive update finished"
