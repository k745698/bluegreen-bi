# Zero-Downtime Analytics: blue-green delivery of a Power BI portal

A small Flask portal embeds a Power BI report through the **secure embed** link
(Power BI Service > File > Embed report > Website or portal). The portal is what
gets containerized and deployed as Blue and Green on Kubernetes. The report
itself stays in Power BI Service.

```
app/        Flask portal + Dockerfile (/, /healthz, /readyz, /version)
k8s/        Deployment and Service templates (blue/green) and the naive baseline
scripts/    deploy.sh, rollback.sh, deploy_naive.sh
loadtest/   k6 script
.github/    CI workflow (test on GitHub, deploy on a self-hosted runner)
```

## Prerequisites

- Docker Desktop with Kubernetes enabled (Settings > Kubernetes), context `docker-desktop`
- `kubectl get nodes` shows one Ready node
- k6 (`brew install k6`)
- Your Power BI secure embed link, exported as `POWERBI_EMBED_URL`

```bash
export POWERBI_EMBED_URL='https://app.powerbi.com/reportEmbed?reportId=...'
kubectl config use-context docker-desktop
```

## 1. First deploy (v1 goes to blue)

```bash
docker build -t bi-portal:v1 app
./scripts/deploy.sh bi-portal:v1 v1
```

Open http://localhost:8080. The header bar shows the colour and release. Sign in
to Power BI in the same browser first, or the iframe will show a sign-in page.

## 2. Blue-green update under load (the main experiment)

Terminal A:

```bash
k6 run loadtest/k6.js
```

Terminal B, about 20 seconds after k6 starts:

```bash
docker build -t bi-portal:v2 app
./scripts/deploy.sh bi-portal:v2 v2
```

v2 starts on green, passes readiness, and the Service selector flips. In the k6
summary, `served{color:blue}` and `served{color:green}` show the switch, and
`http_req_failed` should be 0.

## 3. Failed release (traffic must not move)

```bash
docker build -t bi-portal:v3 app
./scripts/deploy.sh bi-portal:v3 v3 true   # BREAK_RELEASE=true, readiness fails
```

The script times out waiting for the new colour and exits non-zero. The live
colour keeps serving. Clean up the failed deployment with
`kubectl delete deployment bi-portal-<colour>` or redeploy a good release.

## 4. Rollback

```bash
./scripts/rollback.sh
```

## 5. Naive baseline (for comparison)

```bash
./scripts/deploy_naive.sh bi-portal:v1 v1          # initial
BASE_URL=http://localhost:8081 k6 run loadtest/k6.js
# during the run:
./scripts/deploy_naive.sh bi-portal:v2 v2          # in-place update
```

`STRATEGY=Recreate` (default) models taking the server offline. Also run it with
`STRATEGY=RollingUpdate`: Kubernetes handles that natively with little downtime,
and it is the baseline a reviewer is most likely to ask about.

Repeat each experiment several times and report the mean and spread. Approximate
downtime in seconds is failed requests divided by the k6 `RATE` (default 20/s).

## CI/CD

Push to `main` runs `test` on GitHub (build and smoke-test the image), then
`deploy` on a **self-hosted runner** on your Mac, because GitHub-hosted runners
cannot reach the Docker Desktop cluster. Setup:

1. Repo > Settings > Actions > Runners > New self-hosted runner (macOS, ARM64), and follow the steps.
2. Repo > Settings > Secrets and variables > Actions: add `POWERBI_EMBED_URL`.
3. Keep Docker Desktop running while the runner is active.

Run the workflow manually with `break_release` ticked to demonstrate the
failed-release path.

## What the readiness probe does and does not prove

`/readyz` checks that the embed link is a well-formed https Power BI URL and that
Power BI answers (a sign-in redirect counts). It cannot prove the report renders
for a signed-in user, because that needs a browser session. State this in the
paper: the probe is URL-level, not token-based.

Downtime is measured on the portal tier, not on Power BI Service.

## Known gotchas

- Browsers that block third-party cookies may stop the Power BI sign-in inside the iframe. Chrome signed in to Power BI is the most reliable.
- Use a new image tag for every release (the workflow uses the short commit hash). Reusing a tag with `imagePullPolicy: IfNotPresent` deploys the old image.
- Docker Desktop publishes LoadBalancer Services on localhost. Ports 8080 and 8081 must be free.
