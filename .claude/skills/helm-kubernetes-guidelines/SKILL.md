---
name: helm-kubernetes-guidelines
description: Helm and Kubernetes best practices plus this repository's hard-won gotchas (template pitfalls, hook lifecycle, secrets patterns, determinism rules). Read BEFORE writing or modifying any chart template, values file or hook.
---

# Helm & Kubernetes guidelines for this repository

## Chart conventions (enforced here)

- Two-space YAML indentation, `- ` list style; template filenames `<kind>-<name>.yaml`.
- Every resource's `metadata.labels` includes `{{- include "shopsys.labels" $ }}`.
  **Selector labels (`app: ...`) are immutable on live Deployments — never change or extend
  selectors**, and never put dynamic values (date, version) into them.
- No `namespace:` in template metadata — helmfile/`-n` owns it.
- All helpers namespaced `shopsys.*` in `charts/shopsys-common`; use `include`, never
  `template`. After editing shopsys-common run `helm dependency build` on both charts.
- Image tags always pinned; full CI references go into `image.repository` with empty `tag`
  (the `shopsys.image` helper handles both).
- Every workload exposes the standard component keys (image, replicas, autoscaling,
  resources, podAnnotations/podLabels, scheduling keys, extraEnv, extraVolumes/-Mounts,
  probes, securityContexts, lifecycle, terminationGracePeriodSeconds, priorityClassName).
- values: camelCase, no prod/dev conditionals in templates (environment overlays only),
  lists REPLACE on override while maps deep-merge, `values.schema.json` roots must keep
  `additionalProperties: true` (helmfile passes the shared state values to both charts).

## Determinism rules (golden tests depend on them)

- Never use `lookup`, `now`, `randAlphaNum`, or `htpasswd` outputs in anything a golden
  scenario renders. `htpasswd` is salted — scenarios must use `existingSecret`.
- Rollout-on-change is done with `checksum/*` pod annotations (sha256 of the source values),
  not name-hashes or timestamps. Trade-off: the digest is derivable from secret plaintext —
  documented; requires strong secrets.
- The cron `date` label comes from `deploy.timestamp` (tests pin `1234567890`).

## Helm hook lifecycle (source of most review findings)

- Hook resources are **unmanaged**: they survive successful deploys AND `helm uninstall`;
  `before-hook-creation` deletes only when the hook renders again on the next deploy.
  - Consequence 1: a hook Job kept with only `before-hook-creation` retains its logs — used
    deliberately for `migrate-application`.
  - Consequence 2: a conditionally-rendered hook is never scrubbed once its condition turns
    false → **render credential-bearing hooks unconditionally** (empty when unused) so every
    deploy replaces them (see `app-secret-env-hook`).
- `pre-install`/`pre-upgrade` hooks run BEFORE regular resources exist/are updated — a hook
  must never reference a regular ConfigMap/Secret; give it a hook-scoped copy with a lower
  weight (`domains-urls-hook`, `app-secret-env-hook`). `post-*` hooks may use regular
  resources (already applied).
- `hook-succeeded` on a plain (non-Job) hook resource deletes it as soon as it is "ready" —
  i.e. before later-weight hooks run. Don't use it on Secrets/ConfigMaps consumed by Jobs.

## Kubernetes gotchas encountered here

- **`env` beats `envFrom`** — never define a key in both `env` and `secretEnv`.
- **crond scrubs the environment** — cron jobs need env via sourced files (until
  supercronic/#3 or CronJobs/#19 land).
- **RabbitMQ `RABBITMQ_DEFAULT_USER/PASS` are bootstrap-only** with a persisted data dir —
  changing them does NOT rotate the broker user; rotation = `rabbitmqctl change_password`.
- **`0644`-style octals** are YAML 1.1 (kubectl/helm parse them as octal); yq v4 reads them
  as decimal — a comparison artifact, not a bug.
- **ingress-nginx redirects**: built-in `from-to-www-redirect`/`app-root` redirect BEFORE
  the HTTPS upgrade (kubernetes/ingress-nginx#6340, unresolved, repo archived). The
  https-first chain needs the `configuration-snippet` (default `ingress.redirectStyle:
  snippet`, requires `allow-snippet-annotations: true`); `native` is the documented lesser
  fallback.
- **PVC sizes in volumeClaimTemplates are immutable** via helm upgrade — resizing means
  editing the PVC manually (storage class permitting).

## Template-language pitfalls (Sprig/Go templates)

- `regexReplaceAll` argument order is `(regex, input, replacement)` — piping the input makes
  it the LAST argument (the replacement!). Call it explicitly, don't pipe.
- `splitn ":" 2 $s` returns a **dict** with `_0`/`_1` keys, not a list.
- Go regexp has **no lookahead** (`(?!...)`) — only PCRE strings passed through to nginx may
  contain it.
- Map iteration (`range $k, $v := ...`) is key-sorted — env lists render alphabetically.
- Accessing a field on a missing map errors (`nil pointer`) — guard with `(.Values.x).y` or
  define the default in BOTH charts' values when a shared key is used by both.
- Helpers render at zero indent; compose with `| nindent N` at call sites. Prefer building a
  list and `toYaml` over hand-emitting `- name:` lines (avoids leading-newline/indent traps).
- helm-unittest renders with `Release.Revision: 0` — set `release.revision` explicitly when
  asserting on it; every suite must load `./values/required.yaml` (schema baseline).

## Tooling quirks

- **Helm 4 only**: `helm plugin install --verify=false` for unsigned plugins; keep CI
  `HELM_VERSION` in sync with local.
- helmfile v1 requires the `.gotmpl` extension for templated helmfiles; `{{ .Environment.Name }}`
  works in the environments block (double rendering).
- zsh `echo "$VAR"` interprets backslash escapes — corrupts rendered manifests in pipelines;
  use `printf '%s\n'`.
- zsh does not word-split unquoted variables — use explicit loops/`while read`, or arrays.
