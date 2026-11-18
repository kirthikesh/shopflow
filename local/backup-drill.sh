#!/usr/bin/env bash
# Disaster-recovery drill: back up the ShopFlow namespace with Velero, delete
# the namespace, restore it, and check the orders came back. Prints the
# recovery time.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=shopflow-local
name="drill-$(date +%Y%m%d-%H%M%S)"

count_orders() {
  kubectl -n "$NS" exec statefulset/postgres -- psql -U shopflow -d orders -tAc "select count(*) from orders"
}

wait_phase() { # wait_phase <kind> <name> <phase>
  for _ in $(seq 1 120); do
    phase=$(kubectl -n velero get "$1" "$2" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "$3" ] && return 0
    case "$phase" in Failed|PartiallyFailed|FailedValidation) echo "$1 $2: $phase"; kubectl -n velero describe "$1" "$2" | tail -20; exit 1;; esac
    sleep 5
  done
  echo "Timed out waiting for $1 $2"; exit 1
}

local/up.sh velero
# The object storage keeps its data in the pod (emptyDir), so make sure the
# bucket exists in the pod that's running now, then wait for Velero to see it.
kubectl -n velero rollout status deploy/s3 --timeout=5m
for _ in $(seq 1 12); do
  kubectl -n velero exec deploy/s3 -- sh -c \
    'echo "s3.bucket.create -name velero" | timeout 60 weed shell -master=localhost:9333 -filer=localhost:8888' >/dev/null 2>&1 &&
  kubectl -n velero exec deploy/s3 -- sh -c \
    'echo "s3.bucket.list" | timeout 60 weed shell -master=localhost:9333 -filer=localhost:8888' 2>/dev/null | grep -q velero && break
  sleep 5
done
for _ in $(seq 1 60); do
  [ "$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}')" = "Available" ] && break
  sleep 5
done
kubectl -n velero get backupstoragelocation default
[ "$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}')" = "Available" ] ||
  { echo "Backup storage isn't available"; exit 1; }
# A repository created against an earlier (now empty) store would be stale.
kubectl -n velero delete backuprepositories --all >/dev/null 2>&1 || true

before=$(count_orders)
echo "== Orders before: $before"

echo "== Backup $name"
kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata: { name: $name, namespace: velero }
spec:
  includedNamespaces: [$NS]
  defaultVolumesToFsBackup: true
  ttl: 72h0m0s
YAML
wait_phase backup "$name" Completed

echo "== Disaster: deleting namespace $NS"
start=$(date +%s)
kubectl delete namespace "$NS" --wait=true

echo "== Restore"
kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata: { name: $name, namespace: velero }
spec:
  backupName: $name
YAML
wait_phase restore "$name" Completed
kubectl -n "$NS" rollout status statefulset/postgres --timeout=5m
kubectl -n "$NS" wait deploy --all --for=condition=Available --timeout=10m

after=$(count_orders)
echo "== Orders after: $after (recovered in $(( $(date +%s) - start )) s)"
[ "$after" = "$before" ] && echo "PASSED: every order came back." || { echo "FAILED: order count changed"; exit 1; }
