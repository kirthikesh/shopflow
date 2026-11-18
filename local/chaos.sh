#!/usr/bin/env bash
# Chaos test: steady shopper traffic (k6) while Chaos Mesh kills product-service
# pods, slows the database down and takes payments offline. Passes if the
# shoppers' error rate and checkout latency stay inside the k6 thresholds.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=shopflow-local
exp=gitops/platform/chaos-mesh/experiments

local/up.sh chaos-mesh

# Two product-service pods while pods get killed: KEDA keeps at least two.
kubectl -n "$NS" patch scaledobject product-service --type merge -p '{"spec":{"minReplicaCount":2}}'
kubectl -n "$NS" rollout status deploy/product-service --timeout=3m || true
sleep 20

cleanup() {
  kubectl delete -f "$exp" --ignore-not-found >/dev/null
  kubectl -n "$NS" patch scaledobject product-service --type merge -p '{"spec":{"minReplicaCount":1}}' >/dev/null
}
trap cleanup EXIT

echo "== Starting 6 minutes of traffic"
PROFILE=chaos k6 run --quiet tests/load/shop.js &
k6_pid=$!

sleep 30;  echo "== Chaos: kill a product-service pod every minute"; kubectl apply -f "$exp/kill-product-pod.yaml"
sleep 30;  echo "== Chaos: +100 ms between the order service and Postgres for 3 minutes"; kubectl apply -f "$exp/slow-database.yaml"
if kubectl -n "$NS" get deploy payment-service >/dev/null 2>&1; then
  sleep 60; echo "== Chaos: payment-service down for 2 minutes"; kubectl apply -f "$exp/payment-outage.yaml"
fi

wait "$k6_pid" && result=0 || result=$?
cleanup

echo
echo "== Orders still waiting for payment (should drain to 0 within a minute):"
kubectl -n "$NS" exec statefulset/postgres -- psql -U shopflow -d orders -tAc \
  "select status, count(*) from orders group by status order by status" || true
[ "$result" -eq 0 ] && echo "PASSED: shoppers stayed inside the thresholds during the chaos." \
                    || echo "FAILED: k6 thresholds were crossed (exit $result)."
exit "$result"
