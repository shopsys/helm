---
name: create-issue
description: Conventions for creating GitHub issues in this repository - body structure, title prefixes, the label taxonomy and cross-linking rules. Use whenever filing new issues or turning analysis/review findings into backlog items.
---

# Creating issues in shopsys/helm

## Language & self-containment

English (public shopsys repo). Issues must be **self-contained**: never reference internal
or local documents — inline the relevant facts instead. Reference code as repo paths and
upstream material as full links (`shopsys/deployment#74`, `kubernetes/ingress-nginx#6340`).

## Title

`[area] Imperative summary` — area prefixes in use: `[app]`, `[infra]`, `[ingress]`,
`[security]`, `[secrets]`, `[hooks]`, `[deploy]`, `[ci]`, `[release]`, `[docs]`,
`[monitoring]`, `[availability]`, `[hygiene]`, `[proposal]`, `[bug]`. Investigations get
`(investigation)` suffix.

## Body structure

```markdown
## Context
What is true today and why it is a problem. Facts, file paths, upstream links.

## Proposal
Concrete design - values sketches, template names, commands. For investigations: options
to compare, evaluation criteria, and "decision record" as the deliverable.

## Tasks
- [ ] checklist the implementer can follow
- [ ] include "regenerate golden snapshots" and "deviations entry" when rendering changes

Related: #N (cross-links); Reference: upstream links
```

## Labels (all exist in the repo)

- exactly one of `priority/high|medium|low`
- area: `area/app-chart`, `area/infra-chart`, `area/deploy`, `area/ci` (multiple allowed)
- type: `enhancement` (default), `bug`, `documentation`, `investigation`, `security`
- `behavior-change` — rendered manifests change ⇒ DoD includes golden regen + deviations doc
- `good first issue` — small, well-bounded

```bash
gh issue create -R shopsys/helm -t "[area] Title" -F body.md -l "enhancement,area/app-chart,priority/medium"
```

## Hygiene

- Cross-link related issues bidirectionally (edit or comment the older one).
- When an issue supersedes/overlaps another (e.g. supercronic #3 vs CronJobs #19), state the
  relationship explicitly so the work is not done twice.
- Scope decisions made later (deferrals, rejected review findings) go back into the issue as
  comments — see the `implement-issue` skill's retrospective step.
