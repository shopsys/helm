---
name: prepare-pr
description: End-to-end workflow for preparing a pull request in this repository - branching, implementation checklist, the full verification suite, commit/PR conventions and stacked-PR handling. Use whenever implementing an issue or any change that will become a PR.
---

# Preparing a pull request

## 1. Branch

```bash
git checkout main && git pull
git checkout -b <short-kebab-topic>        # e.g. secrets-out-of-manifests
```

**Stacked PRs:** when the change touches the same files as another open PR, branch from that
PR's branch instead and open the PR with `--base <that-branch>`. GitHub retargets it to
`main` automatically once the base PR is merged (squash) and its branch deleted. Note the
stacking in the PR body ("only the last commit belongs to this PR"). After the base merges,
rebase with `git rebase --onto origin/main <old-base-tip> <branch>` and force-push with
`--force-with-lease`.

## 2. Implementation checklist

A chart change is not done until ALL of these ship in the same commit:

- [ ] templates + `values.yaml` defaults + `values.schema.json` for any new keys
- [ ] helm-unittest cases for every new behavior variant (on/off, existingSecret, failure)
- [ ] regenerated golden snapshots (`./tests/run-golden-tests.sh --update`) when the
      rendered output changes — never regenerate to hide an unintended diff; inspect it first
- [ ] docs: `docs/values.md` (structure + legacy mapping table), and a new numbered entry in
      `docs/migrating-from-shopsys-deployment.md` § Deviations when behavior differs from the
      legacy package
- [ ] `CLAUDE.md` when a new convention or gotcha emerges

Consult the `helm-kubernetes-guidelines` skill for chart conventions and known gotchas
BEFORE writing templates.

## 3. Verification suite (all must pass locally before pushing)

```bash
helm dependency build charts/shopsys-infra && helm dependency build charts/shopsys-app
helm unittest charts/shopsys-app charts/shopsys-infra
./tests/run-golden-tests.sh
helm lint charts/shopsys-infra -f charts/shopsys-infra/tests/values/required.yaml
helm lint charts/shopsys-app -f charts/shopsys-app/tests/values/required.yaml
./tests/run-golden-tests.sh --keep-tmp && \
  find tests/tmp -name '*.yaml' -print0 | xargs -0 kubeconform -strict -summary \
    -kubernetes-version 1.31.0 -schema-location default; rm -rf tests/tmp
shellcheck deploy/deploy.sh deploy/lib/functions.sh tests/run-golden-tests.sh tools/compare-legacy.sh
```

For render spot-checks pipe helmfile output through yq — use `printf '%s\n' "$VAR"`, never
`echo "$VAR"` (zsh echo mangles backslashes in the ingress snippets).

## 4. Commit

- One logical change per commit; imperative-mood summary line, body explains the why.
- Footer (always): `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- `Closes #N` in the final commit or the PR body (both works; PR body is the convention here).

## 5. Pull request

```bash
gh pr create -R shopsys/helm --base main --head <branch> -t "<imperative title>" -F body.md
```

Body structure: `Closes #N` first, then `## What`, `## Why` (if not obvious), `## Changes`
or `## Notes` (golden impact, deviations entry, test counts). Footer:
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## 6. After creating the PR

Switch back to `main` locally, then follow the `watch-pr` skill: wait for CI, triage the
Copilot review (including suppressed comments), reply in threads and **leave them open**.
