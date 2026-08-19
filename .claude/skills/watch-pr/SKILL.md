---
name: watch-pr
description: Watch a pull request after creation - CI checks, Copilot review comments including suppressed ones, and the protocol for discussing findings with Copilot. Use right after opening a PR, or when asked to check/handle review feedback on one.
---

# Watching a PR and handling the Copilot review

## CI checks

Wait for checks in the background (never foreground-sleep):

```bash
# run with run_in_background: true
until [ "$(gh pr checks <N> -R shopsys/helm 2>/dev/null | grep -c pending)" = "0" ]; do sleep 10; done
gh pr checks <N> -R shopsys/helm | awk -F'\t' '{print $1": "$2}'
```

A stacked PR (base ≠ main) gets NO checks until it is retargeted to main — that is expected,
not a failure.

## Fetching the Copilot review

Copilot feedback arrives in TWO places; always check both:

```bash
# 1. regular review comments (threads) - top-level AND replies
gh api repos/shopsys/helm/pulls/<N>/comments \
  --jq '.[] | "id: \(.id) | reply_to: \(.in_reply_to_id) | \(.path):\(.line // .original_line)\n\(.body)"'

# 2. SUPPRESSED comments - only inside the review body, no threads exist for them
gh api repos/shopsys/helm/pulls/<N>/reviews \
  --jq '.[] | select(.user.login | test("copilot"; "i")) | .body' | grep -A30 "Suppressed"
```

## Triage protocol

For every finding, decide explicitly and act:

- **Valid → fix**: implement, add a test covering it, run the full verification suite, push,
  then reply in the thread referencing the commit short-SHA.
- **Invalid or intentional → justify**: reply in the thread with the concrete reasoning
  (link the upstream issue/doc that proves the point). If the behavior is intentional,
  also document it in the code/values comment or the deviations doc so the next reviewer
  doesn't re-raise it.
- **Suppressed comments**: no thread exists — triage them in a single PR conversation
  comment (`gh pr comment`) listing each finding and its resolution.

Replying to a thread:

```bash
gh api repos/shopsys/helm/pulls/<N>/comments/<comment-id>/replies -f body="..."
```

**NEVER resolve review threads yourself** — leave them open so Copilot can respond; the
maintainer resolves them (or asks for it explicitly). Copilot replies inside threads have
`in_reply_to_id` set — check for them on follow-up passes.

Copilot re-reviews after every push; expect a new review (possibly with new suppressed
comments) after each fix round and repeat the triage.

## Long-running watch across PRs

For a persistent watch over all open PRs (new Copilot comments AND thread replies,
suppressed-comment reviews, CI failures, merges), use the Monitor tool with a poll loop over
`gh api` (state file with seen IDs; poll ≥ 90 s). Caveat: seed the state file with existing
IDs at start, and beware the init race — a review submitted during initialization gets
seeded as already-seen, so after (re)starting the monitor do one manual pass over the PRs.
