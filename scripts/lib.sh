# Shared helpers for deploy.sh, deploy_naive.sh and rollback.sh. Source it; do not run it.
# Works with the macOS system bash (3.2).

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# Wall-clock seconds with sub-second precision (macOS `date` has no %N).
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

RELEASE_DIR=""
PF_PID=""
on_exit() {
  if [ -n "${PF_PID}" ]; then kill "${PF_PID}" 2>/dev/null || true; fi
  if [ -n "${RELEASE_DIR}" ]; then rm -rf "${RELEASE_DIR}"; fi
}
trap on_exit EXIT

# Embed link lives in a ConfigMap shared by every colour, so it never gets
# spliced into YAML text.
ensure_config() {
  : "${POWERBI_EMBED_URL:?set POWERBI_EMBED_URL to the Power BI secure embed link}"
  kubectl create configmap bi-config \
    --from-literal=POWERBI_EMBED_URL="${POWERBI_EMBED_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# apply_release <overlay> <deployment-name>
# Layers this release on top of k8s/overlays/<overlay> and runs kubectl apply -k.
# Reads IMAGE, VERSION, BREAK, REPLICAS, REPORT_ID, REPORT_PAGE and (naive only)
# STRATEGY. The layer is written to a throwaway, gitignored k8s/.release-* folder
# because kustomize only accepts bases by relative path.
apply_release() {
  local overlay="$1" name="$2" image_name image_tag
  image_name="${IMAGE}"; image_tag=""
  case "${IMAGE##*/}" in
    *:*) image_name="${IMAGE%:*}"; image_tag="${IMAGE##*:}" ;;
  esac

  RELEASE_DIR="$(mktemp -d k8s/.release-XXXXXX)"
  # Becomes the bi-release-<colour>-<hash> ConfigMap read through envFrom. The
  # hash changes whenever a value changes, so any setting change rolls the pods.
  {
    echo "APP_VERSION=${VERSION}"
    echo "BREAK_RELEASE=${BREAK}"
    echo "REPORT_ID=${REPORT_ID:-}"
    echo "REPORT_PAGE=${REPORT_PAGE:-}"
  } > "${RELEASE_DIR}/release.env"
  {
    echo "resources:"
    echo "  - ../overlays/${overlay}"
    echo "images:"
    echo "  - name: bi-portal"
    echo "    newName: \"${image_name}\""
    if [ -n "${image_tag}" ]; then echo "    newTag: \"${image_tag}\""; fi
    echo "replicas:"
    echo "  - name: ${name}"
    echo "    count: ${REPLICAS}"
    echo "configMapGenerator:"
    echo "  - name: bi-release"
    echo "    behavior: replace"
    echo "    envs:"
    echo "      - release.env"
    if [ -n "${STRATEGY:-}" ]; then
      echo "patches:"
      echo "  - target:"
      echo "      kind: Deployment"
      echo "    patch: |-"
      echo "      - op: replace"
      echo "        path: /spec/strategy/type"
      echo "        value: ${STRATEGY}"
    fi
  } > "${RELEASE_DIR}/kustomization.yaml"

  kubectl apply -k "${RELEASE_DIR}"
  rm -rf "${RELEASE_DIR}"; RELEASE_DIR=""
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# smoke_test <colour> <version>
# Port-forwards to the new colour's pods (not through the Service, which still
# points at the live colour) and checks /version and /powerbi-check.
smoke_test() {
  local color="$1" version="$2" port url got i
  port="$(free_port)"
  url="http://127.0.0.1:${port}"
  kubectl port-forward "deployment/bi-portal-${color}" "${port}:8000" >/dev/null 2>&1 &
  PF_PID=$!

  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl -fsS --max-time 2 -o /dev/null "${url}/healthz" 2>/dev/null; then break; fi
    if ! kill -0 "${PF_PID}" 2>/dev/null || [ "${i}" = 20 ]; then
      log "smoke test: port-forward to bi-portal-${color} did not come up"
      return 1
    fi
    sleep 0.5
  done

  got="$(curl -fsS --max-time 5 "${url}/version" \
    | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["color"], d["version"])')" || got="no answer"
  if [ "${got}" != "${color} ${version}" ]; then
    log "smoke test: /version returned '${got}', expected '${color} ${version}'"
    return 1
  fi
  log "smoke test: /version ok (${got})"

  if ! curl -fsS --max-time 10 "${url}/powerbi-check"; then
    echo
    log "smoke test: /powerbi-check failed (Power BI not reachable from the new pods)"
    return 1
  fi
  echo
  log "smoke test: /powerbi-check ok"

  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  PF_PID=""
}
