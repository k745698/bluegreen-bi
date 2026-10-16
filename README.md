# Zero-Downtime Analytics: blue-green delivery of a Power BI portal

A small Flask portal embeds a Power BI report through the **secure embed** link
(Power BI Service > File > Embed report > Website or portal). The portal is what
gets containerized and deployed as Blue and Green on Kubernetes. The report
itself stays in Power BI Service.

```
app/        Flask portal + Dockerfile (/, /healthz, /readyz, /powerbi-check, /version)
k8s/        Kustomize base, overlays (blue, green, naive) and the live Service
scripts/    deploy.sh, rollback.sh, deploy_naive.sh, run_experiment.sh, lib.sh (shared helpers)
loadtest/   gap_logger.py (main measurement) and k6.js (optional second source)
tests/      test_app.py (pytest) and scripts_test.sh (scripts against a stub kubectl)
.github/    CI workflow (test on GitHub, deploy on a self-hosted runner)
results/    experiment output (created by run_experiment.sh, gitignored)
```

## Prerequisites

- Docker Desktop with Kubernetes enabled (Settings > Kubernetes), context `docker-desktop`
- `kubectl get nodes` shows one Ready node (kubectl 1.27+ for `apply -k` with Kustomize v5)
- `python3` and `curl` (both ship with macOS)
- Your Power BI secure embed link, exported as `POWERBI_EMBED_URL`
- Optional: k6 (`brew install k6`) as a second load source

```bash
export POWERBI_EMBED_URL='https://app.powerbi.com/reportEmbed?reportId=...'
kubectl config use-context docker-desktop
```

## How a blue-green deploy works

`./scripts/deploy.sh <image> <version> [break]`

1. Writes the embed link to the `bi-config` ConfigMap.
2. Finds the live colour from the `bi-portal` Service selector and picks the idle one.
3. Applies `k8s/overlays/<idle>` with `kubectl apply -k`. The image, version,
   replicas, `BREAK_RELEASE`, `REPORT_ID` and `REPORT_PAGE` for this release are
   layered on top in a throwaway `k8s/.release-*` folder (see `scripts/lib.sh`).
   The per-release settings become a `bi-release-<colour>-<hash>` ConfigMap.
4. Waits for `kubectl rollout status`, which means the readiness probes pass.
5. **Smoke test before cutover.** It port-forwards straight to the new colour's
   pods (the Service still points at the live colour) and checks that
   `/version` reports the expected colour and version, and that
   `/powerbi-check` returns 200.
6. Only then does it patch the Service selector to the new colour.
7. The previous colour stays at `KEEP_REPLICAS` pods (default: full `REPLICAS`),
   so a rollback is only a selector flip. Set `CLEANUP=true` to delete it instead.

If step 4 or 5 fails, the script prints why and exits non-zero. Traffic stays on
the live colour.

| Variable | Default | Effect |
|---|---|---|
| `REPLICAS` | 2 | pods for the new colour |
| `KEEP_REPLICAS` | `REPLICAS` | pods left on the previous colour after cutover |
| `CLEANUP` | false | `true` deletes the previous colour after a successful cutover (no rollback target) |
| `REPORT_ID`, `REPORT_PAGE` | empty | which report / page this release embeds |
| `ROLLOUT_TIMEOUT` | 120s | how long to wait for readiness |

### Health endpoints

| Endpoint | Used by | Checks |
|---|---|---|
| `/healthz` | liveness probe | the process is up |
| `/readyz` | readiness probe | `POWERBI_EMBED_URL` is set and is a well-formed `https://*.powerbi.com` URL, and `BREAK_RELEASE` is not set. **No network call.** |
| `/powerbi-check` | `deploy.sh` before cutover | as above, plus Power BI answers the embed URL (any status below 500, so a sign-in redirect counts). Cached for 10 s. |
| `/version` | load tests, smoke test | colour, version, report id, report page |

Readiness is deliberately process-level only. If it called Power BI, a Power BI
outage would mark every live pod unready, and the Service would have no
endpoints. The portal would then go down because of a dependency it cannot fix.
The Power BI check is a one-off gate on the *new* colour instead. Both probes
have `timeoutSeconds: 3`.

### Graceful draining

Pods have `terminationGracePeriodSeconds: 30` and a `preStop` hook that runs
`sleep 5`. The sleep keeps the pod serving while the Service removes it from its
endpoints. gunicorn then gets SIGTERM and has `--graceful-timeout 20` to finish
in-flight requests. This matters for the naive RollingUpdate baseline and for
`CLEANUP=true`. After a blue-green cutover the old pods keep running, so nothing
is killed mid-request.

## 1. First deploy (v1 goes to blue)

```bash
docker build -t bi-portal:v1 app
./scripts/deploy.sh bi-portal:v1 v1
```

Open http://localhost:8080. The header bar shows the colour, release and (if
set) report. Sign in to Power BI in the same browser first, or the iframe will
show a sign-in page.

## 2. Blue-green update under load (the main experiment)

Single run by hand. Terminal A:

```bash
BASE_URL=http://localhost:8080 DURATION=90 OUT=results/manual.csv python3 loadtest/gap_logger.py
```

Terminal B, about 15 seconds later:

```bash
docker build -t bi-portal:v2 app
./scripts/deploy.sh bi-portal:v2 v2
```

The logger prints the total requests, failures, the longest gap between two
successful responses (the downtime figure), the time of the colour switch and
the count served per colour.

Release a different report page (item shown in the header and in `/version`):

```bash
REPORT_PAGE=ReportSection2 ./scripts/deploy.sh bi-portal:v2 v2-page2
```

## 3. Failed release (traffic must not move)

```bash
docker build -t bi-portal:v3 app
./scripts/deploy.sh bi-portal:v3 v3 true   # BREAK_RELEASE=true, readiness fails
```

The script times out waiting for the new colour and exits non-zero. The live
colour keeps serving. The idle colour now runs the broken release. Deploying a
good release replaces it.

## 4. Rollback

```bash
./scripts/rollback.sh
```

The script prints `ROLLBACK_SECONDS=<n>`: the time from start to the selector
patch. With the default `KEEP_REPLICAS` the previous colour is already at full
size, so this is about one selector patch. With `KEEP_REPLICAS=1` it also
includes scaling back up.

## 5. Naive baseline (for comparison)

```bash
./scripts/deploy_naive.sh bi-portal:v1 v1                       # initial, port 8081
STRATEGY=RollingUpdate ./scripts/deploy_naive.sh bi-portal:v2 v2  # in-place update
```

`STRATEGY=Recreate` (default) models taking the server offline.
`STRATEGY=RollingUpdate` is what Kubernetes does natively. It is the baseline a
reviewer is most likely to ask about. The API server can reject a switch between
strategies on an existing Deployment. Run `kubectl delete deployment
bi-portal-naive` first; `run_experiment.sh` does this for you.

## 6. Repeated experiments

```bash
docker build -t bi-portal:v1 app      # the image every run re-tags and releases

./scripts/run_experiment.sh blue-green      10
./scripts/run_experiment.sh naive-recreate  10
./scripts/run_experiment.sh naive-rolling   10
./scripts/run_experiment.sh failed-release  10
./scripts/run_experiment.sh rollback        10
```

For each run, the script starts `gap_logger.py` and waits `WARMUP` (15) seconds.
It then triggers the deploy or rollback and waits for it to finish. Finally it
waits `SETTLE` (5) seconds and stops the logger. Each run re-tags `IMAGE`
(default `bi-portal:v1`) with a fresh version tag, so Kubernetes really rolls the
pods. If nothing is live yet, an initial release is deployed first (not measured).

Results go to `results/<scenario>-<YYYYmmdd-HHMMSS>/`:

| File | Contents |
|---|---|
| `run-<n>.csv` | every request: timestamp, status (0 = no answer), colour, version, latency |
| `run-<n>.csv.summary.json` | that run's summary |
| `run-<n>.deploy.txt` | deploy / rollback script output |
| `runs.csv` | one row per run: exit code, requests, failures, longest gap, switch time, rollback seconds |
| `summary.csv` | mean and standard deviation of downtime (longest gap, s), failures and rollback time |

Add `WITH_K6=true` (and `K6_DURATION=60s`, long enough to cover a run) to also
run the unchanged `loadtest/k6.js` per run. Its summary goes to
`run-<n>.k6.json`. With k6, approximate downtime in seconds is failed requests
divided by its `RATE` (default 20/s).

For `failed-release`, set `ROLLOUT_TIMEOUT=60s` to shorten each run. The useful
numbers are failures = 0 and deploy exit code ≠ 0.

## Canary (not implemented)

A canary would run a third, small Deployment carrying the new release. A single
Service would select a label that all three share, so traffic splits by replica
ratio (e.g. 1 canary pod next to 4 stable pods ≈ 20 %). It was left out because
it needs a different Service selector from the blue/green colour flip, and that
would complicate the scripts. As a comparison point, canary lowers the *blast
radius* of a bad release (only a share of users see it). Blue-green lowers the
*time to recover* (one selector flip) and never mixes versions.

## Tests

```bash
pip install -r app/requirements.txt pytest
pytest -q tests                  # app endpoints, Power BI call mocked
./tests/scripts_test.sh          # deploy/rollback/naive/run_experiment against a stub kubectl
kubectl kustomize k8s/overlays/blue   # render an overlay to inspect it
```

`scripts_test.sh` needs no cluster. It renders every `apply -k` layer with the
real `kubectl kustomize`, and replaces port-forward with a local fake server. It
checks the first deploy, cutover, a broken colour leaving traffic unchanged, a
failed smoke test blocking cutover, rollback, `KEEP_REPLICAS`, `CLEANUP`, the
report settings and the naive strategies.

## CI/CD

Push to `main` runs `test` on GitHub, then `deploy` on a **self-hosted runner**
on your Mac. GitHub-hosted runners cannot reach the Docker Desktop cluster.
`test` runs the unit and script tests, then builds and smoke-tests the image.
Setup:

1. Repo > Settings > Actions > Runners > New self-hosted runner (macOS, ARM64), and follow the steps.
2. Repo > Settings > Secrets and variables > Actions: add `POWERBI_EMBED_URL`.
3. Keep Docker Desktop running while the runner is active.

Run the workflow manually with `break_release` ticked to demonstrate the
failed-release path. Use `report_page` to release a different report page.

## Limitations (state these in the paper)

- **The Power BI check is URL-level, not token-based.** `/powerbi-check` proves
  the embed link is well-formed and that Power BI answers it (a sign-in redirect
  counts). It cannot prove the report renders for a signed-in user, because that
  needs a browser session.
- **Downtime is measured on the portal tier, not Power BI itself.** The load
  tests call `/version` on the portal and never load the embedded report.
- **Docker Desktop's LoadBalancer adds a local proxy hop.** `localhost:8080` and
  `:8081` go through Docker Desktop's port proxy before kube-proxy. Absolute
  latencies and some connection-level effects are specific to that setup and
  will differ on a real cloud load balancer.
- Old `bi-release-<colour>-<hash>` ConfigMaps from earlier releases are not
  pruned. They are tiny and harmless.

## Known gotchas

- Browsers that block third-party cookies may stop the Power BI sign-in inside the iframe. Chrome signed in to Power BI is the most reliable.
- Use a new image tag for every release (the workflow uses the short commit hash). Reusing a tag with `imagePullPolicy: IfNotPresent` deploys the old image.
- Docker Desktop publishes LoadBalancer Services on localhost. Ports 8080 and 8081 must be free.
- The smoke test's `/powerbi-check` runs inside the pod, so the cluster needs outbound internet to `*.powerbi.com`.
