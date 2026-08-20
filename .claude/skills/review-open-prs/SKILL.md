---
name: review-open-prs
description: Fan-out code review of multiple/all open PRs - one parallel worktree-isolated agent per PR, each following the review-pr skill protocol, then cross-PR verification, cleanup and summary. Use when asked to review all open PRs or several PRs at once; a single PR needs only review-pr.
---

# Multi-agent review of open PRs

Orchestration only — the per-PR review protocol lives in
`.claude/skills/review-pr/SKILL.md` and is NOT duplicated here.

## 1. Discover the PRs and the stack topology

```bash
gh pr list --state open --json number,title,headRefName,baseRefName,url --limit 50
```

Note which PRs are stacked (`baseRefName` ≠ main) — pass each PR's base branch into its
agent prompt so the "own diff only" rule is explicit.

## 2. Launch one agent per PR

Agent tool, all launches in a single message (parallel), each with
`isolation: "worktree"` so agents can `gh pr checkout` and run the test suite without
touching the main checkout or each other.

Each agent's prompt:

- "You are an expert Kubernetes/Helm code reviewer. Review PR #<N> (<title>, base
  `<baseRefName>`) and post the review to GitHub."
- "Follow the protocol in `.claude/skills/review-pr/SKILL.md` — read it first; the
  **(parallel)** notes apply to you."
- PR-specific hypotheses worth chasing (see the review-focus section of `review-pr`) —
  tailor them per PR; this is what separates real findings from style nits.
- "Return a severity-ranked findings report, verification results, and the posted
  review URL."

## 3. After all agents finish

1. **Verify every review landed on the right PR** (the shared-scratchpad collision
   described in `review-pr` makes this non-optional):

   ```bash
   for pr in <numbers>; do echo "=== PR #$pr ==="; \
     gh api repos/shopsys/helm/pulls/$pr/reviews \
       --jq '.[] | select(.body | contains("Claude Agent (CR)")) | "\(.id) [\(.state)]"'; done
   ```

2. **Clean up the agent worktrees** (a PR-branch checkout marks them "changed", so they
   are not auto-removed):

   ```bash
   git worktree list | grep agent- | awk '{print $1}' \
     | while read wt; do git worktree remove --force "$wt"; done
   git branch | grep worktree-agent | xargs -r git branch -D
   ```

3. **Summarize for the user**: cross-PR severity ranking (lead with the worst finding
   overall, not per-PR), per-PR test results, and links to all posted reviews.
