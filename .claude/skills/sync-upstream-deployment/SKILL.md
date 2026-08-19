---
name: sync-upstream-deployment
description: Porting changes from the legacy shopsys/deployment package (upstream PRs, manifest fixes) into these charts. Use when asked to review/port upstream deployment PRs or to check what changed upstream.
---

# Porting changes from legacy shopsys/deployment

This package replaced github.com/shopsys/deployment, but the legacy repo still receives PRs
(often by the same maintainer) until every project migrates. Changes flow one way:
legacy → here.

## 1. Survey upstream

```bash
gh pr list -R shopsys/deployment --state open --json number,title
gh pr view <N> -R shopsys/deployment --json title,body,files
gh pr diff <N> -R shopsys/deployment | awk '/^diff --git/{f=$3; show=(f !~ /expected|UPGRADE|README/)} show'
```

Skip `tests/scenarios/*/expected/*` (legacy snapshots), `UPGRADE.md`, `README.md` — the
substance is in `kubernetes/*.yaml` and `deploy/*.sh`.

## 2. Map legacy mechanics to this package

| Legacy | Here |
|---|---|
| manifest edit in `kubernetes/` | chart template + values default |
| `deploy/parts/*.sh` logic (sed/yq at deploy time) | values/env overlay, helper, or helmfile mechanism |
| new env variable | committed value; env interpolation in `runtime.yaml.gotmpl` only if sensitive/CI-dynamic |
| kubectl exec / imperative step | helm hook Job or wrapper step (last resort) |
| new kustomize resource | new template (+ schema + docs) |

Check first whether the change is already covered — by the phase-1 port itself, an existing
issue (search the tracker), or an intentional deviation
(`docs/migrating-from-shopsys-deployment.md`).

## 3. Decide per upstream PR

- **trivial & obviously right** → implement directly (own PR, reference
  `shopsys/deployment#N` in commit/PR/deviations entry)
- **substantial** → file an issue with the concrete spec extracted from the upstream diff
  (`create-issue` skill); if an issue already covers the topic, add the spec as a comment
- **not applicable here** (solved differently by the rewrite) → note why, nothing else

## 4. Parity verification

`tools/compare-legacy.sh` semantically diffs our render against the legacy snapshots:

```bash
LEGACY_REPO=/path/to/shopsys-deployment ./tools/compare-legacy.sh <scenario>
```

It canonicalizes both sides (sorted keys, sorted env, stripped hook/checksum noise). Expect
the documented deviations to show up; anything else is a finding. Note yq-v4 artifacts:
`0644`-style octals display as decimal (YAML 1.1 vs 1.2) — cosmetic only.
