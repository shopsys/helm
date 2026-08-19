---
name: debug-deploy
description: Diagnosing a failed deploy on a real cluster - identifying which phase failed from the end states, where the logs are, recovery commands, and what must NOT be done. Use when a helmfile/wrapper deploy fails or behaves unexpectedly.
---

# Debugging a failed deploy

Deploy phases (see docs/deploy-flow.md): wrapper prep → infra release (wait) →
app release: cron-suspend hook → migrate-application hook → manifests + rollout wait →
post-deploy hook → website check.

## 1. Identify the failing phase

```bash
NS=<project>-<environment>
helm list -n $NS                                   # which releases exist, their status
kubectl get jobs -n $NS                            # hook jobs + their state
kubectl -n $NS get job migrate-application -o jsonpath='{.status.conditions[*].type}'
kubectl get pods -n $NS                            # rollout state, crashloops, pending
kubectl get events -n $NS --sort-by=.lastTimestamp | tail -30
```

| Symptom | Phase | Logs |
|---|---|---|
| infra release failed/pending | redis/rabbitmq not ready | `kubectl describe pod redis-*/rabbitmq-0`; PVC events (storage class!) |
| job `migrate-application` Failed | migration | `kubectl logs job/migrate-application -n $NS` |
| helm upgrade timed out, pods not Ready | rollout | `kubectl describe pod` (probes, image pull, secrets missing); `kubectl logs` both containers of webserver |
| job `post-deploy` Failed | maintenance-off/cache | `kubectl logs job/post-deploy -n $NS` — `set -e` means the FIRST failing phing target killed it |
| website check ERROR | app runs but responds ≠200/401 | curl manually with `-v`; ingress controller logs |
| ingresses rejected on apply | admission webhook | snippet annotations vs `allow-snippet-annotations` — see README requirements |

## 2. Recovery per failure (what the wrapper does / you may need manually)

- **Migration failed**: previous release is intact. Crons were scaled to 0 by cron-suspend →
  `kubectl scale deployment/cron --replicas=1 -n $NS` restores them on the OLD code. The
  continuous migration may have enabled the maintenance page → `kubectl exec <webserver-pod>
  -n $NS -- ./phing maintenance-off`. Re-run = fix the cause, `helmfile apply` again
  (the failed Job is deleted by `before-hook-creation` automatically).
- **Rollout failed**: migration already ran — **DB migrations are NOT rolled back**.
  `helm rollback` alone can produce old-code/new-schema; check schema compatibility before
  rolling back. Usually: fix the image/config and roll FORWARD.
- **Stuck apply**: hook Jobs are bounded by `activeDeadlineSeconds`; the whole apply by
  `DEPLOY_TIMEOUT` (wrapper env, default 45 min).

## 3. What NOT to do

- Do not delete the `migrate-application` Job before reading its logs (it is kept for them).
- Do not `helm uninstall` to "reset" — PVCs (rabbitmq data) and hook leftovers have their own
  lifecycle; see "Helm hook leftovers" in the migration guide. Decommission = delete namespace.
- Do not edit resources manually to "fix" a deploy — the next apply reverts it; fix values.

## 4. Reproduce locally

```bash
helmfile -e <env> template            # what would be applied
helmfile -e <env> diff                # against the live cluster
DISABLE_WEBSITE_RUNNING_CHECK=true ./deploy/deploy.sh <env>   # skip the curl gate
```
