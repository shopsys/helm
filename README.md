# Shopsys Platform Helm Deployment

Helm/Helmfile replacement of the legacy [shopsys/deployment](https://github.com/shopsys/deployment)
package (bash + sed/yq + kustomize). Phase 1 is a faithful port: the deploy **order** and all
**end states** of the legacy pipeline are preserved (see [docs/deploy-flow.md](docs/deploy-flow.md)).

## Layout

```
charts/shopsys-common/   library chart with shared template helpers
charts/shopsys-infra/    release 1: Redis, RabbitMQ (+ services, configmaps, mgmt ingress, hook RBAC)
charts/shopsys-app/      release 2: webserver+php-fpm, storefront, cron, consumers,
                         ingresses, HPAs, secrets and the deploy hooks
                         (cron-suspend → migrate-application → post-deploy)
helmfile.yaml.gotmpl     release composition + dynamic environments
environments/            base.yaml + one directory per environment (example setup)
deploy/deploy.sh         thin wrapper: slack, fe-api-keys, failure recovery, website check
tests/                   golden (snapshot) tests + fixtures
charts/*/tests/          helm-unittest suites
tools/compare-legacy.sh  semantic parity diff against the legacy package's snapshots
docs/                    documentation (start with original-deployment.md and deploy-flow.md)
examples/                what a consuming project copies
```

## Requirements

- **Helm 4** (the package supports Helm 4 only), helmfile ≥ 1.7 with the helm-diff plugin
- kubectl, yq, curl, openssl (used by the deploy wrapper)

## Quick start

```bash
# render everything for an environment
helmfile -e devel template

# diff against the cluster
helmfile -e devel diff

# full deploy (slack, hooks, failure recovery, website check)
TAG=<app-image> STOREFRONT_TAG=<storefront-image> \
CI_REGISTRY=... DEPLOY_REGISTER_USER=... DEPLOY_REGISTER_PASSWORD=... \
RABBITMQ_DEFAULT_USER=... RABBITMQ_DEFAULT_PASS=... \
./deploy/deploy.sh devel
```

Environments are **not fixed**: any `environments/<name>/values.yaml` defines a new one,
inheriting from `environments/base.yaml`. Non-sensitive configuration (domains, crons,
consumers, resources) is committed in values; sensitive/CI-dynamic values come from env vars
via `environments/runtime.yaml.gotmpl`. See [docs/values.md](docs/values.md).

## Tests

```bash
./tests/run-golden-tests.sh              # snapshot tests (5 scenarios × 3 deploy variants)
./tests/run-golden-tests.sh --update     # regenerate snapshots after intentional changes
helm unittest charts/shopsys-app charts/shopsys-infra
helm lint charts/shopsys-infra -f charts/shopsys-infra/tests/values/required.yaml && helm lint charts/shopsys-app -f charts/shopsys-app/tests/values/required.yaml
LEGACY_REPO=~/src/shopsys-deployment ./tools/compare-legacy.sh basic-production
```

CI (GitHub Actions) runs lint, unit tests, golden tests, kubeconform validation and
shellcheck on every push/PR to `main`.

## Documentation

- [docs/original-deployment.md](docs/original-deployment.md) — how the legacy package works
  (the reference for the rewrite)
- [docs/deploy-flow.md](docs/deploy-flow.md) — the new deploy flow and end-state mapping
- [docs/values.md](docs/values.md) — values reference + legacy env-var mapping
- [docs/migrating-from-shopsys-deployment.md](docs/migrating-from-shopsys-deployment.md) —
  project migration checklist and the list of intentional deviations
