# How the original `shopsys/deployment` package works

This document describes the legacy deployment package ([shopsys/deployment](https://github.com/shopsys/deployment))
that this repository replaces. It is the reference for the 1:1 rewrite — the deploy **order**
and every possible **end state** documented here must be preserved by the new implementation
(see [deploy-flow.md](deploy-flow.md) for the mapping).

## Overview

The legacy package is a composer library (`composer require shopsys/deployment`) containing:

- **Kubernetes manifests** (`kubernetes/`) with `{{PLACEHOLDER}}` tokens
- **Bash deploy scripts** (`deploy/functions.sh`, `deploy/parts/*.sh`) that mutate the manifests
  with `sed`/`yq` and apply them with `kustomize build | kubectl apply`
- **A Slack notifier** (`deploy/slack-notification.py`)

Projects copy `deploy-project.sh` from `shopsys/project-base` into `app/deploy/` and define
their configuration there (domains, environment variables, crons, consumers).

## Lifecycle

### 1. `deploy-project.sh merge` (at image build time)

- `merge_configuration`: copies `vendor/shopsys/deployment/kubernetes/` into
  `var/deployment/kubernetes/`, then overlays it with project-level overrides from
  `orchestration/kubernetes/` (same file path = full file replacement). The project **must**
  supply `orchestration/kubernetes/configmap/nginx.yaml` (not shipped by the package).
- `create_consumer_manifests`: for every `name:transports:replicas` entry it copies
  `manifest-templates/consumer.template.yaml` to `deployments/consumer-<name>.yaml`
  (replacing `{{NAME}}`, `{{TRANSPORT_NAMES}}`, `{{REPLICAS_COUNT}}`) and registers the file
  in all three `migrate-application` kustomizations.

The result is baked into the application image; the CI job later extracts `/var/www/html/var/`
from the built image.

### 2. `deploy-project.sh deploy` (in GitLab CI, image `shopsys/kubernetes-buildpack:2.0`)

Defines the configuration arrays and sources the parts **in this order**:

| # | Part | Purpose |
|---|------|---------|
| 1 | `functions.sh` | helpers (`runCommand`, `assertVariable`, `slack_notification`); `pip install requests` when `SLACK_CHANNEL` is set |
| 2 | `parts/domains.sh` | renders one ingress per domain + the MCP ingress (see below) |
| 3 | `parts/domain-rabbitmq-management.sh` | sets host/whitelist of the RabbitMQ management ingress |
| 4 | `parts/environment-variables.sh` | injects env vars into manifests via `yq` |
| 5 | `parts/kubernetes-variables.sh` | `sed`-replaces `{{VAR}}` tokens in every file |
| 6 | `parts/cron.sh` | writes crontab lines into the `cron-list` ConfigMap + stamps a `date` label |
| 7 | `parts/autoscaling.sh` | writes min/max replicas into the HPA manifests |
| 8 | `parts/deploy.sh` | **the deploy itself** |

### `runCommand` semantics (end-state building block)

- `ERROR` — on failure: print output, Slack "error", **exit 1**
- `SKIP` — on failure: yellow note, continue (e.g. "already exists")
- `FAILED` — on failure: yellow note, continue (non-blocking steps)

## Configuration generation details

### Domains (`parts/domains.sh`)

For each domain listed in `DOMAINS` (names of `DOMAIN_HOSTNAME_N` env vars):

- **BASE_DOMAIN / URL_PATH** — `example.com/en` is a path-based domain (path = part after the
  last slash, host = part before the first slash)
- **REDIRECT_DOMAIN** — the www/non-www counterpart; the ingress carries an nginx
  `configuration-snippet` issuing 308 redirects (http→https + between www/non-www variants,
  direction depends on whether the domain starts with `www.`)
- **TLS_SECRET_NAME** — `tls-<sanitized hostname>` (lowercase, non-alphanumerics to `-`,
  trimmed) shared by all ingresses of the same hostname
- **HTTP_AUTH_ENABLED** — when `RUNNING_PRODUCTION=0`, or the domain is listed in
  `FORCE_HTTP_AUTH_IN_PRODUCTION`; adds `auth-type/auth-secret/auth-realm` annotations,
  plus `whitelist-source-range` + `satisfy: any` when whitelist IPs exist
  (merge of `DEFAULT_WHITELIST_IPS` and `WHITELIST_IPS`)
- **CLOUDFLARE_ENABLED** — `USING_CLOUDFLARE=1` and not in `CLOUDFLARE_EXCLUDED_DOMAINS`;
  adds `server-snippet: real_ip_header CF-Connecting-IP;`
  (note: `CLOUDFLARE_IPS` is declared with a default list but **never used** — dead code)
- Writes the final URL into `config/domains_urls.yaml` (from the project's `.dist` file);
  the file is mounted into application pods via the kustomize-generated `domains-urls` ConfigMap

**MCP ingress** (`MCP_INGRESS_ENABLED`, default on): a separate `eshop-mcp` ingress for the
**first domain only**, publishing `/_mcp`, `/mcp/oauth` and the `/.well-known/oauth-*` paths
**without** HTTP basic auth (basic auth and the MCP Bearer token share the Authorization
header). No cert-manager annotation — it reuses the main ingress's TLS secret. Optional
`MCP_IP_WHITELIST` restricts source IPs.

### Environment variables (`parts/environment-variables.sh`)

- `MAILER_FORCE_WHITELIST` is forced to `false`/`true` by `RUNNING_PRODUCTION`
- `ENVIRONMENT_VARIABLES` (bash associative array) is injected as the container `env` of:
  every consumer, webserver-php-fpm, cron, and all three migrate-application Jobs; the same
  variables are appended as `export KEY='VALUE'` lines to the `cron-env` ConfigMap
  (sourced by cron shell). Empty values are skipped with a warning.
- `STOREFRONT_ENVIRONMENT_VARIABLES` goes into the storefront Deployment, followed by
  `DOMAIN_HOSTNAME_N=https://<domain>/` + `PUBLIC_GRAPHQL_ENDPOINT_HOSTNAME_N=https://<domain>/graphql/`
  per domain, and `INTERNAL_ENDPOINT=http://webserver-php-fpm:8080/`
- A global `sed s/nullPlaceholder//` pass removes placeholder markers

### Kubernetes variables (`parts/kubernetes-variables.sh`)

Defaults `REDIS_VERSION=redis:7.4-alpine`, `ADMIN_URL=admin`. `PROJECT_NAME` **must contain a
dash**; it is split into `NAME_OF_PROJECT` + `PROJECT_ENVIRONMENT` (used in pod annotations).
Every `{{VAR}}` token listed in `VARS` (TAG, STOREFRONT_TAG, PROJECT_NAME, BASE_PATH,
RABBITMQ_DEFAULT_USER/PASS, RABBITMQ_IP_WHITELIST, + custom) is `sed`-replaced in every file.

### Cron and autoscaling

- Each `CRON_INSTANCES[phing-target]='crontab expression'` becomes a line
  `<expr> . /root/.project_env.sh && cd /var/www/html/ && ./phing <target> > /dev/null 2>&1`
  in the `cron-list` ConfigMap; a `date=<timestamp>` pod label forces a fresh cron pod each deploy
- `ENABLE_AUTOSCALING=true` writes `MIN/MAX_PHP_FPM_REPLICAS` (default 2/3) and
  `MIN/MAX_STOREFRONT_REPLICAS` (default 2/3) into the two HPA manifests

## The deploy itself (`parts/deploy.sh`) — exact order

1. Slack **"start"** (only with `SLACK_CHANNEL`; posts a thread with changes from
   `git log` between the last successful GitLab deployment and current commit, Jira links via
   `JIRA_URL`, commits containing `!ignore` excluded)
2. `kubectl create namespace $PROJECT_NAME` **[SKIP]**
3. Delete + create secret `dockerregistry` (`GCLOUD_DEPLOY=true` → eu.gcr.io with
   `_json_key`; otherwise `CI_REGISTRY` + `DEPLOY_REGISTER_USER/PASSWORD`) **[ERROR]**
4. Create/update secret `http-auth` from the htpasswd file at `BASIC_AUTH_PATH` — only when
   `RUNNING_PRODUCTION=0` or `FORCE_HTTP_AUTH_IN_PRODUCTION` is non-empty **[ERROR]**
5. Secret `fe-api-keys` — only when missing: `openssl genrsa` + `openssl rsa -pubout`,
   then `kubectl create secret` **[ERROR ×3]**
6. Resource downscale via `yq` (when `RUNNING_PRODUCTION=0` or `DOWNSCALE_RESOURCE=1`):
   CPU requests `0.01` for storefront, both webserver containers, redis, rabbitmq;
   memory `100Mi` for php-fpm and redis. Otherwise optional `PHP_FPM_CPU_REQUEST` /
   `STOREFRONT_CPU_REQUEST` overrides.
7. If a cron pod is running: `kubectl exec ./phing -S cron-lock` (background, prevents the
   next cron iteration) + `kubectl exec ./phing -S cron-watch` (waits until all running
   cron instances finish) **[ERROR]**
8. Delete previous `job/migrate-application` **[SKIP]**
9. Select the migrate kustomization: `FIRST_DEPLOY=0` → `continuous-deploy`;
   `FIRST_DEPLOY=1` → `first-deploy`; + `FIRST_DEPLOY_LOAD_DEMO_DATA=1` → `first-deploy-with-demo-data`
10. `DISPLAY_FINAL_CONFIGURATION=1` → print `kustomize build` output in GitLab collapsible sections
11. `kustomize build migrate-application/<variant> | kubectl apply` — this batch contains:
    namespace, redis (Deployment + Service + 2 ConfigMaps), rabbitmq (StatefulSet + Service),
    the migrate-application **Job**, all consumer Deployments, and the generated
    `domains-urls` ConfigMap **[ERROR]**
12. **Polling loop**: every 5 s check
    `kubectl wait --for=condition=failed|complete job/migrate-application --timeout=0`
    until one of them succeeds — **no overall timeout** (runs forever if the Job never finishes)
13. **Migration FAILED path**: red ERROR; delete the old cron pod (restores crons on the old
    code — the replacement pod has no lock) **[SKIP]**; `phing maintenance-off` on a running
    webserver pod (the continuous migration enabled the maintenance page) **[SKIP]**;
    print `kubectl logs job/migrate-application`; Slack "error"; **exit 1**
14. **Migration OK path**: print the Job logs; `kustomize build cron | kubectl apply`
    (cron Deployment + cron-env/cron-list ConfigMaps; the `date` label forces a new pod
    running the NEW image) **[ERROR]**
15. `ENABLE_AUTOSCALING=true` → delete both HPAs **[SKIP]** (so the following apply of
    `replicas: 1` isn't fought by the autoscaler)
16. `kustomize build webserver | kubectl apply` — webserver-php-fpm + storefront Deployments
    and Services, nginx/php-fpm/opcache ConfigMaps, all generated ingresses, rabbitmq
    management ingress, domains-urls ConfigMap **[ERROR]**
17. `kubectl rollout status deployment/webserver-php-fpm deployment/storefront --watch` **[ERROR]**
    (bounded by `progressDeadlineSeconds: 1500` of the Deployments)
18. `ENABLE_AUTOSCALING=true` → re-apply both HPAs; when `RUNNING_PRODUCTION=0`, min and max
    are forced to 2 **[ERROR]**
19. `phing maintenance-off` on the new webserver pod **[ERROR]**
20. `phing clean-redis-old` **[FAILED]**
21. `phing clean-redis-storefront` **[FAILED]**
22. If the phing target `build-deploy-part-3-non-blocking` exists → run it **[FAILED]**
23. **Website check** per domain (skipped with `DISABLE_WEBSITE_RUNNING_CHECK=true`):
    `curl -L` the domain; in production without forced auth → no credentials; otherwise
    `HTTP_AUTH_CREDENTIALS` (default `username:password`).
    `200` → OK; `401` → SKIP with a "check manually" message; anything else → ERROR +
    Slack "error" + **exit 1**
24. Slack **"end"** (success)

### All possible end states

| End state | Trigger | Actions taken | Exit code |
|---|---|---|---|
| **Success** | all steps pass | Slack "end" | 0 |
| **Preparation failure** | any `[ERROR]` step 2–11 fails | print output, Slack "error" | 1 |
| **Migration failure** | migrate Job reaches `condition=failed` | restore old cron pod, maintenance-off on old webserver, print Job logs, Slack "error" | 1 |
| **Rollout/post-deploy failure** | steps 14–19 fail | print output, Slack "error" (maintenance page may stay on, crons already run on new code) | 1 |
| **Website check failure** | curl returns anything but 200/401 | Slack "error" | 1 |

## Manifest inventory

| Resource | Notes |
|---|---|
| `Deployment webserver-php-fpm` | php-fpm + nginx containers, init container copies source code to an emptyDir, hostAliases 127.0.0.1, pod anti-affinity (self) + affinity (redis), `postStart: phing -S warmup`, preStop sleeps, `terminationGracePeriodSeconds: 120`, `progressDeadlineSeconds: 1500`, RollingUpdate 1/0 |
| `Deployment storefront` | Next.js, port 3000, `/api/health` probes, anti-affinity, preStop sleep 10, grace 60 |
| `Deployment cron` | app image, `crond` + log pipe, `runAsUser: 0`, tolerations + node affinity `workload=background`, mounts cron-list (crontab), cron-env (env exports), domains-urls, fe-api-keys |
| `Deployment consumer-*` | generated per consumer; loop `messenger:consume <transports> --time-limit=300`, preStop `touch /tmp/stop_consumer && messenger:stop-workers`, grace 300, background tolerations |
| `Deployment redis` | redis + `oliver006/redis_exporter`, config + health scripts from ConfigMaps |
| `StatefulSet rabbitmq` | `rabbitmq:4.1-management-alpine`, PVC `nfs-client` 1Gi, anti-affinity |
| Services | webserver 8080, storefront 3000, redis 6379 + 9121 exporter, rabbitmq headless 5672/15672/15692 (`prometheus-exporter: 'true'` labels) |
| ConfigMaps | cron-env, cron-list, production-php-fpm (www.conf), production-php-opcache (incl. `opcache.preload`), redis (redis.conf), redis-health (liveness/readiness scripts), nginx (project-supplied) |
| Ingresses | class nginx, `cert-manager.io/cluster-issuer: letsencrypt-prod`, `proxy-body-size: 32m` |
| HPA | autoscaling/v2; webserver: `ContainerResource` cpu of `php-fpm` @120 %; storefront: `Resource` cpu @120 % |
| migrate Jobs | continuous: `phing -verbose db-migrations-count-with-maintenance build-deploy-part-2-db-dependent`; first: `sleep 30 && phing cluster-first-deploy`; +demo: `... db-fixtures-demo plugin-demo-data-load friendly-urls-generate domains-urls-replace elasticsearch-export`; `backoffLimit: 0`, `restartPolicy: Never` |

## Environment variable contract (GitLab CI)

`PROJECT_NAME` (must contain a dash), `TAG`, `STOREFRONT_TAG`, `FIRST_DEPLOY`,
`FIRST_DEPLOY_LOAD_DEMO_DATA`, `RUNNING_PRODUCTION`, `DISPLAY_FINAL_CONFIGURATION`,
`DOMAIN_HOSTNAME_N`, `DEPLOY_REGISTER_USER/PASSWORD`, `CI_REGISTRY`, `GCLOUD_DEPLOY` (+
`GCLOUD_CONTAINER_REGISTRY_EMAIL/ACCOUNT`), `ENABLE_AUTOSCALING`, `MIN/MAX_PHP_FPM_REPLICAS`,
`MIN/MAX_STOREFRONT_REPLICAS`, `PHP_FPM_CPU_REQUEST`, `STOREFRONT_CPU_REQUEST`,
`DOWNSCALE_RESOURCE`, `USING_CLOUDFLARE`, `CLOUDFLARE_EXCLUDED_DOMAINS`, `WHITELIST_IPS`,
`DEFAULT_WHITELIST_IPS`, `FORCE_HTTP_AUTH_IN_PRODUCTION`, `HTTP_AUTH_CREDENTIALS`,
`DISABLE_WEBSITE_RUNNING_CHECK`, `MCP_INGRESS_ENABLED`, `MCP_IP_WHITELIST`,
`RABBITMQ_DEFAULT_USER/PASS`, `RABBITMQ_IP_WHITELIST`, `RABBITMQ_DOMAIN_HOSTNAME`,
`REDIS_VERSION`, `ADMIN_URL`, `S3_ENDPOINT`, `BASIC_AUTH_PATH`, plus Slack variables
(`SLACK_TOKEN`, `SLACK_CHANNEL`, `SLACK_DISABLE_CHANGES`, `JIRA_URL`, `API_TOKEN`,
GitLab-provided `CI_*`).

See [migrating-from-shopsys-deployment.md](migrating-from-shopsys-deployment.md) for the
mapping of every variable to the new values schema.

## Legacy test suite

`tests/run-tests.sh` builds a mock project in `tests/tmp/`, sources default + scenario env
vars, runs the scenario's `deploy-project.sh generate` (the generation parts only — no
`deploy.sh`), builds all kustomizations and diffs them against committed `expected/`
snapshots (`--update` regenerates). `FREEZE_TIMESTAMP=1234567890` makes the cron `date`
label deterministic. Five scenarios: basic-production, development-single-domain,
development-with-cloudflare, escaping-env (a value like `479411e7` must stay a string),
production-with-cloudflare. GitHub Actions runs the suite in `shopsys/kubernetes-buildpack:2.0`.
