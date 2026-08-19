# Migrating a project from `shopsys/deployment`

Checklist for switching a Shopsys project from the legacy composer package to this
Helm/Helmfile package.

## Project checklist

1. **Remove the legacy pieces**: `composer remove shopsys/deployment`, delete
   `app/deploy/deploy-project.sh` and (after moving its content, see below)
   `app/orchestration/kubernetes/`.
2. **Copy the example setup** from `examples/` into your project: `helmfile.yaml.gotmpl`
   reference, `environments/` directory, CI job.
3. **Move configuration into values** (see [values.md](values.md) for the full mapping):
   - `DOMAIN_HOSTNAME_*` GitLab variables → `domains:` in `environments/base.yaml`
     (or per environment) — committed, with git history,
   - `ENVIRONMENT_VARIABLES` / `STOREFRONT_ENVIRONMENT_VARIABLES` arrays → `app.env` /
     `storefront.env` for non-sensitive values and `app.secretEnv` / `storefront.secretEnv`
     for passwords and tokens (rendered as Secrets; the actual secret values stay in CI
     variables, injected via `environments/runtime.yaml.gotmpl` or `HELMFILE_EXTRA_ARGS`),
   - `CRON_INSTANCES` → `cron.instances`, `DEFAULT_CONSUMERS` → `consumers.instances`,
   - your `orchestration/kubernetes/configmap/nginx.yaml` → either delete it (the chart now
     ships a default equal to project-base's) or move customizations into
     `webserver.nginx.config` / `webserver.nginx.projectConfig`,
   - other manifest overrides → component values (`resources`, `extraVolumes`,
     `podAnnotations`, probes, ...) or `extraManifests`.
4. **Create your environments**: one directory per environment under `environments/` —
   any names, any count. The old `RUNNING_PRODUCTION=0` behavior is an overlay
   (see `environments/devel/values.yaml` in this repo).
5. **Update CI**: replace the legacy deploy script invocation with
   `./deploy/deploy.sh <environment>`. Required env vars: `TAG`, `STOREFRONT_TAG`,
   registry credentials (not needed with `registry.existingSecret`) and
   `RABBITMQ_DEFAULT_USER/PASS` (+ optional Slack vars). `FIRST_DEPLOY=1` for the first deploy of an instance.
6. **One-time cleanup in the cluster** (first migration deploy only):
   - the kustomize-generated ConfigMaps (`domains-urls-<hash>`) become orphaned — delete them,
   - resources previously applied by `kubectl apply` are adopted by Helm on the first
     `helmfile apply` thanks to unchanged names; run with `DISPLAY_FINAL_CONFIGURATION=1`
     first and review the diff.
   - if Helm refuses to adopt an existing resource, annotate it with
     `meta.helm.sh/release-name` / `release-namespace` and label
     `app.kubernetes.io/managed-by: Helm` (see Helm docs on adoption).

## Helm hook leftovers

Hook resources are not part of the managed release: after a deploy (and after
`helm uninstall`) the `migrate-application`/`post-deploy` Jobs, the `domains-urls-hook`
ConfigMap and the `app-secret-env-hook` Secret remain in the namespace until the next
deploy replaces them (`before-hook-creation`). This is intentional — the Jobs keep their
logs readable. When decommissioning an environment, delete the namespace rather than just
uninstalling the releases.

## Application requirements

- The cron pod now drains itself: `phing -S cron-lock` and `phing -S cron-watch` are invoked
  by its `preStop` hook. Ensure `cron.terminationGracePeriodSeconds` (default 3600 s) exceeds
  your longest cron run.
- `phing maintenance-off`, `clean-redis-old`, `clean-redis-storefront` and
  `build-deploy-part-3-non-blocking` now run in a fresh Job pod (same image + env), not via
  `kubectl exec` into the webserver pod. They must not depend on webserver pod-local state.

<a name="deviations"></a>
## Deviations from the legacy behavior

Intentional differences of the phase-1 rewrite; everything else is a 1:1 port.

1. **Consumers, redis and rabbitmq spec changes** apply during the main release apply, not in
   the migrate batch. On the first deploy the infra release still guarantees redis/rabbitmq
   exist before the migration.
2. **HPA delete → apply dance is gone**: HPAs are permanent and the Deployments omit
   `replicas` while autoscaling is on — no transient scale-down during deploys. The global
   `ENABLE_AUTOSCALING` split into independent `webserver.autoscaling.enabled` and
   `storefront.autoscaling.enabled`.
3. **Bounded waits**: the legacy migration polling loop and cron-watch wait were unbounded;
   now `DEPLOY_TIMEOUT` (default 45 min) bounds the apply and
   `cron.terminationGracePeriodSeconds` (default 3600 s) bounds the cron drain.
4. **Cron locking** happens inside the terminating pod (preStop) instead of `kubectl exec`
   into a pod that stayed alive through the migration. Net effect is identical: no crons run
   during the migration; the failure path restores crons on the old code.
5. **fe-api-keys** stays imperative in the wrapper (Sprig cannot derive a public key and
   `lookup` is empty under `helm template`); a declarative override exists
   (`security.feApiKeys`).
6. **Post-deploy phing steps** run in a Job pod, not the live webserver pod.
7. **`domains-urls` ConfigMap** has a static name + checksum pod annotations instead of the
   kustomize name-hash (same restart-on-change effect). Hooks mount a separate
   `domains-urls-hook` copy because pre-install hooks run before regular resources exist.
8. **Namespace** is created by the wrapper/helmfile, not applied as a manifest. It is named
   `<project.name>-<environment>` (replaces the "PROJECT_NAME must contain a dash" rule).
9. **`sleep 30`** in the first-deploy migration command is kept verbatim for parity even
   though the infra release already guarantees readiness.
10. **DISPLAY_FINAL_CONFIGURATION** prints one `helmfile template` output instead of two
    kustomize sections.
11. **`orchestration/kubernetes/` file overrides and the composer `merge` step are gone** —
    use values, `extraManifests`, per-component `enabled` flags, or add your own helmfile
    release.
12. **Env var ordering** inside containers is alphabetical (legacy bash hash order was
    arbitrary) — semantically irrelevant.
13. **`CLOUDFLARE_IPS`** was dead code in the legacy package and is not ported. Cloudflare
    handling = `real_ip_header CF-Connecting-IP;` + per-domain exclusions, as before.
14. **The GitLab env-var contract shrank**: non-sensitive configuration lives in committed
    values; only sensitive/CI-dynamic values stay in env vars (see the mapping in
    [values.md](values.md)).
15. **Pinned image tags** (Helm best practice — never use floating tags): the redis exporter
    is pinned (`oliver006/redis_exporter:v1.89.0`, legacy pulled an untagged image with
    `pullPolicy: Always`) and the hook kubectl image is `rancher/kubectl:v1.33.13`.
    Both are plain values overridable per project/environment.
16. **Standard Helm labels** (`app.kubernetes.io/name|instance|managed-by`, `helm.sh/chart`)
    are added to every resource. Purely additive — the legacy `app:` selector labels are kept
    untouched (selectors are immutable on existing Deployments).
17. **Redis is the first container** of its pod (exporter second) so `kubectl logs` and
    `kubectl exec` target the `redis` container by default (adopted from shopsys/deployment#74).
18. **HTTP auth credentials moved into values**: the `basicHttpAuth` htpasswd file,
    `BASIC_AUTH_PATH` and `HTTP_AUTH_CREDENTIALS` are gone. Set
    `security.httpAuth.username/password` (the chart generates the htpasswd entry, bcrypt)
    or `security.httpAuth.existingSecret`; enabling auth without either fails the render.
    The website check reads the credentials from the deployed release values.
19. **Sensitive values are delivered as Secrets**: `app.secretEnv` / `storefront.secretEnv`
    render the `app-secret-env` / `storefront-secret-env` Secrets consumed via `envFrom`,
    RabbitMQ credentials moved to the `rabbitmq-credentials` Secret (secretKeyRef), and cron
    jobs source `/root/.project_secret_env.sh` from a Secret. Legacy rendered everything as
    plain env values and appended passwords to the world-readable `cron-env` ConfigMap.
    Single quotes in exported values are now escaped correctly (legacy bug).
20. **GCloud-specific registry branch removed** (`GCLOUD_DEPLOY` +
    `GCLOUD_CONTAINER_REGISTRY_*`) — dropped upstream too (shopsys/deployment#77). The pull
    secret is registry-agnostic: set the generic `REGISTRY_SERVER/USERNAME/PASSWORD/EMAIL`
    env vars (works with any registry — GCR/GAR via username `_json_key` and the service
    account JSON as the password); the GitLab-flavored `CI_REGISTRY`/`DEPLOY_REGISTER_*`
    variables keep working as a fallback.
21. **Default resources for cron and consumers**: the legacy package shipped cron and
    consumer pods with no requests/limits (`BestEffort` QoS). The chart now defaults to
    conservative values (cron: requests `100m`/`300Mi`, consumers: requests `50m`/`300Mi`;
    both limited to `1Gi` memory) — tune them per project/environment via
    `cron.resources` and `consumers.defaults.resources` (or per instance).
22. **PodDisruptionBudgets for webserver and storefront**: the legacy package had none — a
    node drain could evict all replicas at once. The chart now renders a
    `minAvailable: 1` PDB per component whenever it runs 2+ replicas (autoscaling enabled
    or `replicas > 1`); single-replica setups get no PDB (it would block drains). Opt out
    via `webserver.pdb.enabled` / `storefront.pdb.enabled`. `topologySpreadConstraints`
    is also available as a standard component key (empty by default — the legacy
    anti-affinity defaults are kept untouched).
