---
name: implement-issue
description: Lifecycle of implementing a backlog issue - triage, scope decisions, the PR flow and the closing retrospective comment. Use when asked to implement an issue from the tracker.
---

# Implementing a backlog issue

## 1. Triage before coding

- Read the issue INCLUDING all comments — scope additions, deferrals and upstream-PR specs
  often live there (e.g. probe designs from shopsys/deployment PRs).
- Check `Related:` links: is another issue a prerequisite, or would it supersede this work
  (e.g. #19 CronJobs vs #3 supercronic)? Raise conflicts before implementing.
- `behavior-change` label ⇒ plan the golden regen + deviations entry from the start.
- If reality contradicts the issue text (things moved on), update the issue body first.

## 2. Implement

Follow `helm-kubernetes-guidelines` (conventions/gotchas) and `prepare-pr`
(checklist, verification suite, commit/PR conventions). PR body starts with `Closes #N` —
one PR may close several issues when they share code (`Closes #31` + `Closes #14`).

## 3. Scope deviations are recorded, not silent

Whenever the implementation differs from the issue's proposal:

- **deferred part** → comment on the issue naming what is deferred, why, and where it moved
  (e.g. fe-api-keys defaultMode deferred to #2 because fsGroup is needed first)
- **rejected part** → comment with the reasoning (maintainer decision, upstream constraint)
- **grown scope** → note it in the PR body

## 4. Watch the PR

Follow `watch-pr` — CI, Copilot triage, threads stay open.

## 5. Retrospective (before/at merge)

When the final shape differs from the original proposal, post a closing summary comment on
the issue: **Implemented** (what actually shipped, with the PR link) and **Not implemented
(deliberately)** (each dropped item + reason). This keeps the tracker truthful after the
issue auto-closes — see shopsys/helm#12 for the reference example.
