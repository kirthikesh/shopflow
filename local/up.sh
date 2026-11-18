#!/usr/bin/env bash
# The whole ShopFlow platform on a kind cluster: free, no Azure needed.
#
#   local/up.sh            everything (about 15 minutes the first time)
#   MESSAGING=1 local/up.sh   also run the Service Bus emulator (needs about 2 GB more)
#   local/up.sh <step>     one step: cluster servicebus images platform app
#   local/up.sh tracing    add OpenTelemetry tracing (tracing-off removes it)
#   local/up.sh chaos-mesh / velero    used by the chaos test and backup drill
#
# Needs Docker with about 6 GB of memory, kind, kubectl and helm.
#
# etcd runs in memory (see kind.yaml), so the cluster doesn't survive
# `docker stop` or a Docker restart: run local/down.sh and local/up.sh again.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=shopflow
NS=shopflow-local
SERVICES="product-service cart-service order-service payment-service notification-service frontend"
# Chart versions, pinned to what was tested (18 Nov 2026) so a rebuild gets
# the same platform. Empty means the newest.
CERT_MANAGER_VERSION="v1.21.3"
TRAEFIK_VERSION="42.4.1"
KYVERNO_VERSION="3.10.0"
PROMETHEUS_STACK_VERSION="93.4.0"
OTEL_OPERATOR_VERSION=""   # tracing: not yet run on the laptop
KEDA_VERSION="2.21.1"
CHAOS_MESH_VERSION=""      # chaos test: not yet run on the laptop
VELERO_VERSION="8.0.0"   # Velero 1.15, matches the AWS plugin in platform/velero/values.yaml

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

chart() { # chart <release> <namespace> <repo/chart> <version> [helm args...]
  local release=$1 ns=$2 ref=$3 version=$4; shift 4
  # Install once; re-running the script leaves installed add-ons alone
  # (FORCE=1 upgrades them). Some charts run pre-upgrade checks that fail
  # on a fresh cluster, and there's nothing to upgrade on a laptop anyway.
  if [ -z "${FORCE:-}" ] && [ "$(helm status "$release" -n "$ns" -o json 2>/dev/null | grep -o '"status":"deployed"')" ]; then
    echo "$release is already installed."; return
  fi
  helm upgrade --install "$release" "$ref" -n "$ns" --create-namespace \
    ${version:+--version "$version"} --wait --timeout 10m "$@"
}

step_cluster() {
  say "kind cluster"
  if kind get clusters | grep -qx "$CLUSTER"; then
    echo "Cluster $CLUSTER already exists."
  else
    kind create cluster --config local/kind.yaml --wait 2m
  fi
  kubectl config use-context "kind-$CLUSTER" >/dev/null
}

step_servicebus() {
  say "Service Bus emulator"
  docker compose -f local/servicebus.compose.yaml up -d
  # Pods reach the emulator through a Service with a hand-made endpoint.
  local ip
  for _ in $(seq 1 30); do
    ip=$(docker inspect -f '{{ (index .NetworkSettings.Networks "kind").IPAddress }}' shopflow-servicebus 2>/dev/null || true)
    [ -n "$ip" ] && break; sleep 2
  done
  [ -n "$ip" ] || { echo "The emulator didn't start"; exit 1; }
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
  kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: servicebus-emulator
spec:
  ports: [{ name: amqp, port: 5672 }]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: servicebus-emulator
  labels: { kubernetes.io/service-name: servicebus-emulator }
addressType: IPv4
ports: [{ name: amqp, port: 5672 }]
endpoints: [{ addresses: ["$ip"] }]
YAML
  echo "Emulator at $ip"
}

step_images() {
  say "Build the six images and load them into the cluster"
  for s in $SERVICES; do
    if [ -z "${REBUILD:-}" ] && docker image inspect "shopflow.local/shopflow/$s:local" >/dev/null 2>&1; then
      echo "-- $s (already built; REBUILD=1 to rebuild)"; continue
    fi
    echo "-- $s"
    docker build -q -t "shopflow.local/shopflow/$s:local" "app/services/$s" >/dev/null
  done
  # shellcheck disable=SC2046
  kind load docker-image --name "$CLUSTER" $(for s in $SERVICES; do echo "shopflow.local/shopflow/$s:local"; done)
}

step_platform() {
  say "Helm repositories"
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
  helm repo add kyverno https://kyverno.github.io/kyverno --force-update >/dev/null
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
  helm repo add kedacore https://kedacore.github.io/charts --force-update >/dev/null
  helm repo add chaos-mesh https://charts.chaos-mesh.org --force-update >/dev/null
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update >/dev/null
  helm repo update >/dev/null

  say "cert-manager + local CA"
  chart cert-manager cert-manager jetstack/cert-manager "$CERT_MANAGER_VERSION" -f gitops/platform/cert-manager/values.yaml
  kubectl apply -f gitops/platform/cert-manager/local-ca.yaml
  kubectl -n cert-manager wait certificate/shopflow-local-ca --for=condition=Ready --timeout=2m

  say "Traefik"
  chart traefik traefik traefik/traefik "$TRAEFIK_VERSION" -f gitops/platform/traefik/values.yaml

  say "Kyverno + policies"
  chart kyverno kyverno kyverno/kyverno "$KYVERNO_VERSION" -f gitops/platform/kyverno/values.yaml
  kubectl apply -f gitops/platform/kyverno/policies/

  say "Prometheus, Alertmanager, Grafana"
  chart kube-prometheus-stack monitoring prometheus-community/kube-prometheus-stack "$PROMETHEUS_STACK_VERSION" \
    -f gitops/platform/monitoring/values.yaml

  say "KEDA"
  chart keda keda kedacore/keda "$KEDA_VERSION" -f gitops/platform/keda/values.yaml
}

# The heavier add-ons are switched on only for the demo that needs them, so the
# platform fits on an 8 GB laptop.
step_tracing() {
  say "OpenTelemetry Operator, collector, Tempo"
  chart opentelemetry-operator observability open-telemetry/opentelemetry-operator "$OTEL_OPERATOR_VERSION" \
    -f gitops/platform/otel-operator/values.yaml
  kubectl apply -f gitops/platform/tracing/
  helm upgrade shopflow gitops/charts/shopflow -n "$NS" -f gitops/envs/local/values.yaml \
    --set observability.tracing=true --wait --timeout 10m
}

step_tracing_off() {
  helm upgrade shopflow gitops/charts/shopflow -n "$NS" -f gitops/envs/local/values.yaml --wait --timeout 10m
  kubectl delete -f gitops/platform/tracing/ --ignore-not-found
  helm uninstall opentelemetry-operator -n observability --ignore-not-found
}

step_chaos_mesh() {
  helm status chaos-mesh -n chaos-mesh >/dev/null 2>&1 && return
  say "Chaos Mesh"
  chart chaos-mesh chaos-mesh chaos-mesh/chaos-mesh "$CHAOS_MESH_VERSION" -f gitops/platform/chaos-mesh/values.yaml
}

step_velero() {
  helm status velero -n velero >/dev/null 2>&1 && return
  say "Velero + object storage"
  kubectl get namespace velero >/dev/null 2>&1 || kubectl create namespace velero
  kubectl apply -f gitops/platform/velero/object-store.yaml
  chart velero velero vmware-tanzu/velero "$VELERO_VERSION" -f gitops/platform/velero/values.yaml
}

step_app() {
  say "ShopFlow"
  NS=$NS SERVICEBUS_CONNECTION_STRING="Endpoint=sb://servicebus-emulator.$NS;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;" \
    app/deploy/k8s/create-secrets.sh
  # Locally the chart is installed straight from this folder, so changes can be
  # tried without pushing. dev and prod on Azure are deployed by Argo CD.
  helm upgrade --install shopflow gitops/charts/shopflow -n "$NS" \
    -f gitops/envs/local/values.yaml ${MESSAGING:+--set messaging.enabled=true} --wait --timeout 15m
  kubectl -n "$NS" get pods
  cat <<TXT

  Shop        https://shop.localtest.me:9443  (accept the local certificate)
  Grafana     https://grafana.localtest.me:9443  admin / shopflow
  Email       kubectl -n $NS port-forward svc/mailpit 8025  ->  http://localhost:8025
TXT
}

versions() {
  say "Chart versions in use"
  helm list -A
}

case "${1:-all}" in
  cluster) step_cluster ;;
  servicebus) step_servicebus ;;
  images) step_images ;;
  platform) step_platform; versions ;;
  app) step_app ;;
  tracing) step_tracing ;;
  tracing-off) step_tracing_off ;;
  chaos-mesh) step_chaos_mesh ;;
  velero) step_velero ;;
  all)
    step_cluster
    # The emulator (and its SQL Server) only with MESSAGING=1: see envs/local/values.yaml.
    if [ -n "${MESSAGING:-}" ]; then step_servicebus; fi
    step_images; step_platform; step_app; versions ;;
  *) echo "usage: $0 [cluster|servicebus|images|platform|app|tracing|tracing-off|chaos-mesh|velero|all]"; exit 1 ;;
esac
