# Deploy flow

How a deploy runs with this package, and how every legacy step and end state maps to it.
For the legacy behavior itself see [original-deployment.md](original-deployment.md).

## Big picture

```
./deploy/deploy.sh <environment>
│
├─ 1. slack "start"
├─ 2. kubectl create namespace                       [SKIP]
├─ 3. fe-api-keys secret (openssl, create-once)      [ERROR]
├─ 4. DISPLAY_FINAL_CONFIGURATION=1 → helmfile template
│
├─ 5. helmfile -e <env> apply
│     │
│     ├─ release shopsys-infra  (wait: true)
│     │     redis, rabbitmq, services, configmaps,
│     │     rabbitmq management ingress, hook RBAC
│     │
│     └─ release shopsys-app    (needs: infra, wait + waitForJobs)
│           ├─ hook pre-upgrade  (w0):  cron-suspend Job
│           │     scale deploy/cron → 0  ⇒ the cron pod drains ITSELF
│           │     (preStop: phing cron-lock &; phing cron-watch)
│           ├─ hook pre-install,pre-upgrade (w5):  domains-urls-hook ConfigMap
│           ├─ hook pre-install,pre-upgrade (w10): migrate-application Job
│           │     continuous:  phing db-migrations-count-with-maintenance
│           │                  build-deploy-part-2-db-dependent
│           │     first:       phing cluster-first-deploy [+ demo targets]
│           │     └─ FAILS → whole apply aborts, old release stays
│           ├─ manifests apply + rollout wait (webserver, storefront, cron on the
│           │     new image – the `date` label forces a new pod, consumers, ingresses,
│           │     HPAs, secrets, configmaps)
│           └─ hook post-install,post-upgrade (w0): post-deploy Job
│                 phing maintenance-off        (blocking – fails the deploy)
│                 phing clean-redis-old        (|| [FAILED] – non-blocking)
│                 phing clean-redis-storefront (|| [FAILED])
│                 phing build-deploy-part-3-non-blocking (if it exists, || [FAILED])
│
├─ 6a. FAILURE + migrate job failed:
│        kubectl scale deploy/cron --replicas=1     (crons resume on OLD code)
│        phing maintenance-off on the old webserver pod
│        print job/migrate-application logs, slack "error", exit 1
├─ 6b. FAILURE elsewhere (rollout, post-deploy):
│        print logs, slack "error", exit 1
│
├─ 7. print migration + post-deploy logs
├─ 8. website check per domain (curl; 200 OK / 401 skip / else slack "error" + exit 1)
└─ 9. slack "end"
```

## First deploy vs continuous deploy

Both are the **same** `helmfile apply`. On the very first deploy:

- helmfile installs `shopsys-infra` first and waits until redis/rabbitmq are ready,
- `cron-suspend` is a `pre-upgrade` hook only, so it does not run on install,
- `migrate-application` runs as a `pre-install` hook with the first-deploy command
  (`FIRST_DEPLOY=1` env, optionally `FIRST_DEPLOY_LOAD_DEMO_DATA=1`),
- the application manifests are applied only after the migration succeeds — the same
  ordering guarantee the legacy script provided.

## Legacy step → new mechanism

| Legacy step (see original-deployment.md) | New mechanism |
|---|---|
| 1 slack start | wrapper |
| 2 create namespace | wrapper (`[SKIP]`) + helmfile `createNamespace` |
| 3 dockerregistry secret (delete+create) | `secret-dockerregistry.yaml` template (declarative upgrade) |
| 4 http-auth secret | `secret-http-auth.yaml` template (rendered when auth is active) |
| 5 fe-api-keys (openssl) | wrapper, create-once (helm cannot derive a public key; `lookup` is empty in `helm template`) — optional declarative override via `security.feApiKeys` |
| 6 CPU downscale (yq) | environment values overlay (e.g. `environments/devel/values.yaml`) |
| 7 cron-lock + cron-watch via kubectl exec | **self-managing cron pod**: `cron-suspend` hook scales the deployment to 0, the pod's `preStop` runs cron-lock + cron-watch itself (bounded by `cron.terminationGracePeriodSeconds`, default 3600 s) |
| 8 delete previous migrate job | `hook-delete-policy: before-hook-creation` on the migrate Job |
| 9 kustomize variant selection | `deploy.firstDeploy.enabled/loadDemoData` values (set from `FIRST_DEPLOY` env by `runtime.yaml.gotmpl`) |
| 10 DISPLAY_FINAL_CONFIGURATION | wrapper: `helmfile template` in a collapsible section |
| 11 apply migrate batch | infra release (redis/rabbitmq) + migrate hook Job |
| 12 wait for the job | `helm --wait-for-jobs` (bounded by `DEPLOY_TIMEOUT`, default 90 min — the legacy loop was unbounded) |
| 13 migration failure recovery | wrapper failure branch (scale cron back to 1, maintenance-off, logs, slack, exit 1) |
| 14 apply cron | regular resource in the main apply; the `date` pod label (from `deploy.timestamp`) forces a new pod |
| 15+18 HPA delete/re-apply dance | HPAs are permanent; the Deployments omit `replicas` when autoscaling is enabled, so there is nothing to fight (and no transient scale-down) |
| 16 apply webserver batch | regular resources in the main apply |
| 17 rollout status | `helm --wait` |
| 19 maintenance-off | post-deploy hook Job, blocking (`set -e`) |
| 20–22 cache cleanups + part-3 | post-deploy hook Job, non-blocking (`|| echo [FAILED]`) |
| 23 website check | wrapper; domain URLs and their auth state are read from the rendered manifests |
| 24 slack end | wrapper |

## End-state mapping

| Legacy end state | New trigger | Wrapper behavior | Exit |
|---|---|---|---|
| Success | `helmfile apply` + website check pass | print job logs, slack "end" | 0 |
| Preparation failure | namespace/fe-api-keys step fails, or infra release fails | print output, slack "error" | 1 |
| Migration failure | `job/migrate-application` has `condition=Failed` | scale cron back to 1, maintenance-off on old webserver, print job logs, slack "error" | 1 |
| Rollout / post-deploy failure | apply succeeds hooks-wise but `--wait`/post-deploy fails | print logs, slack "error" (crons already on new code, maintenance may stay on — same as legacy) | 1 |
| Website check failure | curl ≠ 200/401 | slack "error" | 1 |
| Website check behind custom auth | curl = 401 | `[SKIP]` + manual-check message, deploy still succeeds | 0 |

## Known deviations from the legacy behavior

Documented in detail in
[migrating-from-shopsys-deployment.md](migrating-from-shopsys-deployment.md#deviations).
