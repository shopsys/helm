# Values reference

Configuration lives in **committed values files** layered per environment:

```
chart defaults (charts/*/values.yaml)
  → environments/base.yaml                 shared by all environments
    → environments/<name>/values.yaml     one file per environment (any number of them)
      → environments/runtime.yaml.gotmpl  CI-dynamic + sensitive values from env vars
```

Run with `helmfile -e <name> apply` (or `./deploy/deploy.sh <name>`). Environment names are
not enumerated anywhere — creating `environments/staging/values.yaml` is all it takes to add
a `staging` environment.

## Standard component keys

Every workload component (`webserver`, `storefront`, `cron`, `consumers.defaults` /
`consumers.instances[]`, `redis`, `rabbitmq`) accepts the same standard keys:

| Key | Purpose |
|---|---|
| `image: {repository, tag, pullPolicy}` | container image; when `tag` is empty, `repository` is used as a complete reference (this is how CI passes `TAG`) |
| `replicas` | desired replicas (omitted from the manifest when `autoscaling.enabled`) |
| `autoscaling: {enabled, minReplicas, maxReplicas, targetCPUUtilization}` | per-component HPA (webserver + storefront) |
| `resources` | container resources |
| `podAnnotations` / `podLabels` | extra pod metadata |
| `nodeSelector` / `tolerations` / `affinity` / `topologySpreadConstraints` / `priorityClassName` | scheduling |
| `extraEnv` | extra env entries (raw list, supports `valueFrom`) |
| `extraVolumes` / `extraVolumeMounts` | additional volumes |
| `livenessProbe` / `readinessProbe` | probe overrides |
| `securityContext` / `podSecurityContext` | security contexts (hardening defaults ship per component: seccomp `RuntimeDefault` + `allowPrivilegeEscalation: false` everywhere except cron; nginx and redis additionally run non-root with a read-only root filesystem — see the deviations list) |
| `terminationGracePeriodSeconds`, `lifecycle` | shutdown behavior |

## Top-level structure

```yaml
project:
  name: myproject            # namespace = <name>-<environment>

domains:                     # ordered; index 0 was DOMAIN_HOSTNAME_1
  - hostname: www.example.com   # "example.com/en" = path-based domain
    forceHttpAuth: false        # basic auth for this domain even in production
    cloudflareExcluded: false
    extraAnnotations: {}

ingress:
  className: nginx
  clusterIssuer: letsencrypt-prod
  proxyBodySize: 32m
  extraAnnotations: {}

security:
  httpAuth:
    enabled: false           # chart default; the example base.yaml enables it for every
                             # environment (secure by default) and production opts out
    username: ""             # the chart generates the htpasswd entry (bcrypt) from these;
    password: ""             #   required when auth is active (unless existingSecret is set)
    existingSecret: ""       # OR reference an externally managed secret (key `auth`)
  whitelistIps: []           # IPs bypassing basic auth
  cloudflare: { enabled: false }
  mcp: { enabled: true, ipWhitelist: [] }
  feApiKeys: {}              # optional declarative keypair

registry:                    # image pull secret; credentials sensitive → env vars
  existingSecret: ""         # OR reference an externally managed pull secret

serviceAccount:              # per-chart SA the workload pods run under (no API token mounted)
  create: true
  name: ""                   # empty = chart name per chart; leave empty (shared values -
                             #   an explicit name would collide between the two releases)
  automountToken: false

networkPolicy:               # opt-in; default-deny ingress + per-workload allows (incl.
  enabled: false             #   cert-manager's HTTP01 solver pods on port 8089 - they run
                             #   in this namespace and issuance/renewal would break without
                             #   the allow). Roll out on a dev environment first (CNI must
                             #   enforce policies; verify kubelet probes still pass)
  ingressControllerNamespace:
    matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
  monitoringNamespace:
    matchLabels: { kubernetes.io/metadata.name: monitoring }
  extraIngress: []           # raw ingress rules applied to all pods (escape hatch)
  egress:                    # optional egress lockdown: DNS + in-namespace allowed,
    enabled: false           #   everything else must be listed in `rules` (incl. the
    rules: []                #   K8s API for the cron-suspend hook, DB, ES, S3, SMTP).
                             #   DNS is allowed to ANY destination (cluster DNS location
                             #   differs per cluster) - DNS tunneling stays possible

app:                         # shared backend configuration
  env: {}                    # non-sensitive backend env vars (webserver, cron, consumers, migration)
  secretEnv: {}              # sensitive backend env vars → app-secret-env Secret + envFrom;
                             #   cron jobs source them from the mounted .project_secret_env.sh
  envDefaults: { MAILER_FORCE_WHITELIST: "false" }
  domainsUrls: { filename, mountPath }
  adminUrl: admin
  s3Endpoint: ""

webserver:                   # component (see standard keys) + phpFpm/nginx sub-containers;
                             #   `pdb: {enabled: true, minAvailable: 1}` - rendered only with
                             #   2+ replicas (autoscaling on or replicas > 1)
storefront:                  # component + its own `env` / `secretEnv` (storefront-secret-env Secret);
                             #   `pdb` - same as webserver
cron:                        # component + `instances: [{name, schedule}]`;
                             #   default resources: requests 100m/300Mi, limits 1Gi memory
consumers:                   # `defaults` + `instances: [{name, transports, replicas, ...}]`;
                             #   default resources: requests 50m/300Mi, limits 1Gi memory
redis:                       # infra component + `config` (redis.conf)
rabbitmq:                    # infra component + auth/persistence/management

deploy:
  timestamp: ""              # injected by the wrapper (forces a new cron pod)
  firstDeploy: { enabled: false, loadDemoData: false }
  migration: { enabled, targets: {continuous, firstDeploy, firstDeployWithDemoData}, resources }
  postDeploy: { enabled, resources }
  hooks: { kubectlImage, serviceAccountName }

extraManifests: []           # raw manifests (rendered through tpl) — escape hatch
```

**Important:** `app.env`, `app.secretEnv`, `app.envDefaults`, `storefront.env` and
`storefront.secretEnv` values must be **strings** (quote everything:
`SENTRY_RELEASE: "479411e7"`). This is enforced by `values.schema.json`. Explicit `env`
entries take precedence over `envFrom` in Kubernetes — never define the same key in both
`env` and `secretEnv`.

Lists (e.g. `security.whitelistIps`, `domains`) **replace** the base value when overridden by
an environment file — they are not merged. Maps merge deeply.

## Legacy env var → values mapping

| Legacy env var | New location |
|---|---|
| `PROJECT_NAME` | `project.name` + environment name (namespace = `<name>-<env>`) |
| `TAG` / `STOREFRONT_TAG` | env var → `webserver.image.repository` / `storefront.image.repository` (runtime.yaml.gotmpl) |
| `DOMAIN_HOSTNAME_N` | `domains[]` (committed) |
| `RUNNING_PRODUCTION=0` | environment overlay: `security.httpAuth.enabled: true`, `app.envDefaults.MAILER_FORCE_WHITELIST: "true"`, downscaled resources, HPA min=max |
| `FIRST_DEPLOY` / `FIRST_DEPLOY_LOAD_DEMO_DATA` | env vars → `deploy.firstDeploy.*` (runtime.yaml.gotmpl) |
| `ENABLE_AUTOSCALING`, `MIN/MAX_*_REPLICAS` | `webserver.autoscaling` + `storefront.autoscaling` (independent) |
| `PHP_FPM_CPU_REQUEST` / `STOREFRONT_CPU_REQUEST` / `DOWNSCALE_RESOURCE` | `*.resources.requests` in environment values |
| `DEPLOY_REGISTER_USER/PASSWORD`, `CI_REGISTRY` | env vars → `registry.*` (runtime.yaml.gotmpl); generic `REGISTRY_SERVER/USERNAME/PASSWORD/EMAIL` take precedence and work with any registry (GCR/GAR: username `_json_key`, password = service account JSON) |
| `BASIC_AUTH_PATH`, `HTTP_AUTH_CREDENTIALS` | gone — HTTP auth credentials live in values (`security.httpAuth.username/password`, or `existingSecret`); the website check reads them from the deployed release |
| `WHITELIST_IPS` + `DEFAULT_WHITELIST_IPS` | `security.whitelistIps` (single committed list) |
| `FORCE_HTTP_AUTH_IN_PRODUCTION` | `domains[].forceHttpAuth` |
| `USING_CLOUDFLARE` / `CLOUDFLARE_EXCLUDED_DOMAINS` | `security.cloudflare.enabled` / `domains[].cloudflareExcluded` |
| `MCP_INGRESS_ENABLED` / `MCP_IP_WHITELIST` | `security.mcp.enabled` / `security.mcp.ipWhitelist` |
| `RABBITMQ_DEFAULT_USER/PASS` | env vars → `rabbitmq.auth.*` (runtime.yaml.gotmpl) |
| `RABBITMQ_DOMAIN_HOSTNAME` / `RABBITMQ_IP_WHITELIST` | `rabbitmq.management.hostname` / `.ipWhitelist` |
| `REDIS_VERSION` | `redis.image` |
| `ADMIN_URL` / `S3_ENDPOINT` | `app.adminUrl` / `app.s3Endpoint` (used by the default nginx vhost) |
| `ENVIRONMENT_VARIABLES` array | `app.env` (non-sensitive) + `app.secretEnv` (passwords, tokens — rendered as a Secret) |
| `STOREFRONT_ENVIRONMENT_VARIABLES` array | `storefront.env` + `storefront.secretEnv` |
| `CRON_INSTANCES` array | `cron.instances` |
| `DEFAULT_CONSUMERS` array | `consumers.instances` |
| `DISPLAY_FINAL_CONFIGURATION`, `DISABLE_WEBSITE_RUNNING_CHECK`, Slack vars | stay env vars of the deploy wrapper |
