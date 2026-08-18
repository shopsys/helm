# Consuming this package in a project

A project needs three things:

1. **`environments/` directory** — copy `environments/` from this repository and adjust:
   - `base.yaml`: project name, domains, `app.env`, crons, consumers — shared configuration,
   - one directory per environment (`production/`, `devel/`, `staging/`, ... any names and
     any number) with `values.yaml` containing only the differences from base,
   - keep `runtime.yaml.gotmpl` as is (maps CI env vars to values).

2. **`helmfile.yaml.gotmpl`** — reference the charts of this package. During development you
   can point at a git checkout; for releases publish the charts to an OCI registry and use
   `chart: oci://<registry>/shopsys-infra` with a pinned `version:`. The CI image must
   contain **Helm 4** (the package supports Helm 4 only), helmfile and the helm-diff plugin.

3. **CI deploy job** — see [gitlab-ci.yml](gitlab-ci.yml). Required CI variables:

   | Variable | Purpose |
   |---|---|
   | `TAG`, `STOREFRONT_TAG` | full image references built by the pipeline |
   | `CI_REGISTRY`, `DEPLOY_REGISTER_USER`, `DEPLOY_REGISTER_PASSWORD` | registry pull secret |
   | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` | RabbitMQ credentials |
   | `BASIC_AUTH_PATH` | path to the htpasswd file (checked into the project like before) |
   | `FIRST_DEPLOY=1` | only for the very first deploy of an instance (`FIRST_DEPLOY_LOAD_DEMO_DATA=1` to load demo data) |
   | `DISPLAY_FINAL_CONFIGURATION=1` | print rendered manifests into the job log |
   | `HELMFILE_EXTRA_ARGS` | e.g. `--state-values-set ...` or extra `--set-string app.env.DATABASE_PASSWORD=$DB_PASS` style injections |
   | `SLACK_TOKEN`, `SLACK_CHANNEL`, `API_TOKEN`, `JIRA_URL`, `SLACK_DISABLE_CHANGES` | optional Slack notifications |
   | `HTTP_AUTH_CREDENTIALS`, `DISABLE_WEBSITE_RUNNING_CHECK` | website check tuning |

Secrets for the application itself (database password etc.) belong in CI variables and are
referenced from `environments/runtime.yaml.gotmpl` in the project (e.g.
`app: { env: { DATABASE_PASSWORD: {{ requiredEnv "POSTGRES_DATABASE_PASSWORD" | quote }} } }`).

See [../docs/migrating-from-shopsys-deployment.md](../docs/migrating-from-shopsys-deployment.md)
for the full migration checklist.
