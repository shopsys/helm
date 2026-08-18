# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Helm/Helmfile replacement of the legacy [shopsys/deployment](https://github.com/shopsys/deployment)
package (bash + sed/yq + kustomize) for deploying Shopsys Platform e-commerce applications to
Kubernetes. It is a **generic, reusable package** consumed by multiple projects.

Phase 1 (done) is a faithful 1:1 port: the deploy **order** and all **end states** of the
legacy pipeline are preserved. Phase 2 (planned) is manifest modernization — until then,
manifests intentionally keep their legacy shape (including oddities like the `sleep 30` in
the first-deploy migration command). Do not "improve" manifest content without being asked.

**Helm 4 only** — no Helm 3 backward compatibility (e.g. `helm plugin install` uses
`--verify=false`, which Helm 3 does not know). Keep CI's `HELM_VERSION` in sync with the
locally used Helm 4 version.

## Common Commands

```bash
# Render / diff / deploy an environment
helmfile -e devel template
helmfile -e devel diff
./deploy/deploy.sh devel          # full deploy incl. slack, failure recovery, website check

# Tests (run all of these before considering a change done)
./tests/run-golden-tests.sh                    # snapshot tests (5 scenarios × 3 variants)
./tests/run-golden-tests.sh --update           # regenerate snapshots after INTENTIONAL changes
./tests/run-golden-tests.sh basic-production   # single scenario
helm unittest charts/shopsys-app charts/shopsys-infra
helm lint charts/shopsys-infra -f charts/shopsys-infra/tests/values/required.yaml
helm lint charts/shopsys-app -f charts/shopsys-app/tests/values/required.yaml
shellcheck deploy/deploy.sh deploy/lib/functions.sh tests/run-golden-tests.sh tools/compare-legacy.sh

# Validate rendered manifests against the K8s API schemas
./tests/run-golden-tests.sh --keep-tmp && \
  find tests/tmp -name '*.yaml' -print0 | xargs -0 kubeconform -strict -summary -kubernetes-version 1.31.0

# Semantic parity diff against the legacy package (needs a clone of shopsys/deployment)
LEGACY_REPO=~/src/shopsys-deployment ./tools/compare-legacy.sh basic-production

# After changing anything in charts/shopsys-common, rebuild dependencies
helm dependency build charts/shopsys-infra && helm dependency build charts/shopsys-app
```

Note: `helm lint` requires the baseline values file — the values schema requires
`project.name` and at least one domain, which chart defaults intentionally leave empty.

## Architecture

Two Helm releases composed by `helmfile.yaml.gotmpl` (the `.gotmpl` extension is required by
helmfile v1 for templated helmfiles):

1. **shopsys-infra** — Redis, RabbitMQ, their services/configmaps, RabbitMQ management
   ingress, RBAC for hook jobs. Installed first with `wait: true`.
2. **shopsys-app** — webserver+php-fpm, storefront, cron, consumers, ingresses, HPAs,
   secrets, and the deploy hooks. `needs: infra`, `wait + waitForJobs`.

Hook order within one `helmfile apply`:
`cron-suspend` (pre-upgrade, w0, scales cron to 0 → the pod drains itself via preStop) →
`domains-urls-hook` ConfigMap (w5) → `migrate-application` Job (pre-install/pre-upgrade, w10)
→ manifests + rollout wait → `post-deploy` Job (post-install/post-upgrade).

Because infra is ready before the app release, the migration runs as a plain
`pre-install` hook on the very first deploy — first and continuous deploy are the same
single `helmfile apply` (variant selected by `FIRST_DEPLOY` env → `deploy.firstDeploy.*`).

`charts/shopsys-common` is a library chart (helpers only) pulled in via `file://` dependency;
its rendered output lives entirely in `_helpers.tpl` includes.

The wrapper `deploy/deploy.sh <environment>` keeps only what Helm cannot do: slack
notifications, one-time fe-api-keys generation (openssl; Sprig cannot derive a public key
and `lookup` is empty under `helm template`), the migration-failure recovery path (scale
cron back to 1 = crons resume on OLD code, maintenance-off, print job logs, exit 1) and the
per-domain website check (domain URLs + auth state are parsed from the rendered manifests).

## Template Conventions

- Two-space YAML indentation and `- ` list style (Helm best practice) — do not mimic the
  4-space style of the legacy package's manifests.
- Every resource's `metadata.labels` includes the standard labels via
  `{{- include "shopsys.labels" $ }}`; selector labels (`app: ...`) are legacy and immutable —
  never change or extend selectors.
- Image tags are always pinned (no floating tags); full-reference images (CI `TAG`) go into
  `image.repository` with an empty `tag`.

## Values Conventions

- Layering: chart defaults → `environments/base.yaml` → `environments/<name>/values.yaml`
  → `environments/runtime.yaml.gotmpl` (CI/sensitive env vars). Environments are dynamic —
  any directory name works; never enumerate or hardcode environment names in templates.
- **No prod/dev conditionals in templates.** Environment differences (HTTP auth, mailer
  whitelist, downscaled resources, HPA min=max) are expressed purely as values overlays.
- Every workload component (`webserver`, `storefront`, `cron`, `consumers`, `redis`,
  `rabbitmq`) accepts the same standard keys (image, replicas, autoscaling, resources,
  podAnnotations/podLabels, nodeSelector/tolerations/affinity, extraEnv,
  extraVolumes/extraVolumeMounts, probes, securityContext, lifecycle,
  terminationGracePeriodSeconds, priorityClassName). Keep new features consistent with this.
- Autoscaling is per component (`webserver.autoscaling`, `storefront.autoscaling`);
  `replicas` is omitted from the Deployment when autoscaling is enabled.
- `app.env`, `app.secretEnv`, `app.envDefaults`, `storefront.env`, `storefront.secretEnv`
  values MUST be strings (schema-enforced); sensitive keys belong in `secretEnv` (rendered
  as Secrets + envFrom), never in `env`;
  env rendering quotes everything (`| toString | quote`) — this is the escaping parity with
  the legacy `escaping-env` scenario (`"479411e7"` must stay a string).
- Lists in values (domains, whitelistIps) REPLACE on override; maps merge deeply.
- The helmfile passes the full environment state values to BOTH charts, so
  `values.schema.json` files must keep `"additionalProperties": true` at the root.

## Testing Conventions

- Golden scenarios live in `tests/golden/scenarios/<name>/environments/` (a self-contained
  helmfile environments dir selected via `SHOPSYS_ENV_DIR`) + `expected/` snapshots.
  Determinism: fixed env vars in the runner + `DEPLOY_TIMESTAMP=1234567890`; never use
  `lookup`, `now`, or `randAlphaNum` in templates. The `htpasswd` function is salted
  (nondeterministic) — golden scenarios must use `security.httpAuth.existingSecret`,
  never `username`/`password`.
- Any intentional template change requires `./tests/run-golden-tests.sh --update` and the
  regenerated snapshots belong to the same commit.
- helm-unittest suites live in `charts/*/tests/*_test.yaml`; every suite loads
  `./values/required.yaml` (schema baseline). helm-unittest renders with
  `Release.Revision: 0` — set `release.revision` explicitly when asserting on it.

## Key Documentation

- `docs/original-deployment.md` — how the legacy package works (the rewrite reference:
  exact 24-step order, all end states, env contract)
- `docs/deploy-flow.md` — new flow + legacy step/end-state mapping tables
- `docs/values.md` — values reference + legacy env-var mapping
- `docs/migrating-from-shopsys-deployment.md` — migration checklist + the 14 intentional
  deviations from 1:1 (consult before changing behavior; extend it when adding new ones)
