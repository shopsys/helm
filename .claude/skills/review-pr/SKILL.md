---
name: review-pr
description: Detailed code review of ONE pull request - scope vs its (possibly stacked) base, verification-first findings (render + tests + web research), posting a GitHub review with anchored inline comments signed "Claude Agent (CR)". Use when asked to review a specific PR; for all open PRs at once use review-open-prs, which fans this out.
---

# Code review of a single PR

Works standalone in the main checkout, or as the per-agent protocol inside a
`review-open-prs` fan-out. When running as a parallel agent, the **(parallel)** notes apply.

## 1. Context before judgment

Read `CLAUDE.md` and `.claude/skills/helm-kubernetes-guidelines/SKILL.md` first. Most
"obvious improvements" in this repo are intentional legacy-parity decisions — check
`docs/migrating-from-shopsys-deployment.md` before flagging behavior as wrong.

## 2. Scope the diff

```bash
gh pr view <N> --json title,body,baseRefName,files
gh pr diff <N>
```

Check `baseRefName`: PRs here are often **stacked** (base = another PR's branch).
Review ONLY this PR's own diff — `gh pr diff <N>` already diffs against the PR's base.
Never attribute base-branch changes to this PR.

Then `gh pr checkout <N>` to inspect full files in context — the diff alone hides
interactions (hook ordering, helper includes, values layering).
**(parallel)** Only ever checkout inside your own isolated worktree.

## 3. Review focus

- **Will it work** — render + runtime reasoning, not just YAML shape. Form PR-specific
  hypotheses and chase them (e.g. "the hook that scales cron needs an API token — does it
  still get one?", "does nginx actually start as non-root with a read-only rootfs?").
  A pointed hypothesis finds real bugs; generic scanning finds style nits.
- **Completeness** — values.schema.json, docs/values.md, deviations doc entry, golden
  snapshots regenerated in the SAME commit, helm-unittest coverage for new values paths.
- **Security** — least privilege, PSS "restricted" alignment, secret handling, footguns
  that fail open (e.g. a mistyped toggle key silently ignored because the schema doesn't
  know it).
- **Improvements** — override/null-merge behavior (verify by actually rendering the
  override), consistency with the standard component keys, docs accuracy.

## 4. Verify, don't speculate

```bash
helm dependency build charts/shopsys-infra && helm dependency build charts/shopsys-app
./tests/run-golden-tests.sh
helm unittest charts/shopsys-app charts/shopsys-infra
# manifest-shape changes: kubeconform the rendered golden output (see CLAUDE.md)
```

- Upstream claims (Kubernetes semantics, ingress-nginx behavior, CVEs, image UIDs) get
  confirmed via WebSearch/WebFetch against primary docs, not memory.
- Only verified findings get posted. Anything needing a real cluster is explicitly marked
  unverifiable — never presented as fact.

## 5. Post the review

One review — summary body + inline comments in a single API call:

```bash
gh api repos/shopsys/helm/pulls/<N>/reviews -X POST --input review-pr<N>.json
# payload: {"event":"COMMENT","body":"<summary>",
#           "comments":[{"path":"...","line":L,"side":"RIGHT","body":"..."}]}
```

- `event: COMMENT` — never APPROVE/REQUEST_CHANGES from an agent.
- Inline `line` values MUST be lines present in this PR's diff hunks (`side: RIGHT` for
  added/context lines) — cross-check against `gh pr diff <N>` immediately before posting;
  one bad anchor 422s the whole review. Unanchorable findings go into the summary body.
- Summary = what was reviewed, what was verified (commands run, sources consulted),
  findings ranked by severity. A clean review is still posted, saying so explicitly.
- English (repo convention); EVERY inline comment and the summary end with the signature:
  `— Claude Agent (CR)`.
- **Unique payload filename** (`review-pr<N>.json`, never `payload.json`).
  **(parallel)** Sibling agents share the scratchpad and WILL overwrite a generic name
  between write and POST (observed: 422 with the other PR's unresolvable paths/lines) —
  re-verify the file's anchors right before the POST.
- Re-run? Check for an existing "Claude Agent (CR)" review first and post only findings
  that are new — no duplicates.

## 6. Report

Return/deliver a severity-ranked findings list, the verification results (honest — failing
tests are reported as failing), and the posted review URL:

```bash
gh api repos/shopsys/helm/pulls/<N>/reviews \
  --jq '.[] | select(.body | contains("Claude Agent (CR)")) | "\(.id) [\(.state)]"'
```

Transient GitHub API `i/o timeout` happens — retry after a few seconds before concluding
the review is missing.

## Don'ts

- Never resolve review threads (same rule as `watch-pr`).
- Never review the stacked siblings' changes.
- Never post speculation as fact.
