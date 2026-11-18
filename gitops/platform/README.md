# Platform add-ons

Cluster-wide pieces the ShopFlow chart builds on. Each folder holds the Helm
values (and any extra manifests) for one add-on. `local/up.sh` installs them on
a kind cluster; the same values are meant for AKS.

| Folder | What | Phase |
|---|---|---|
| `traefik/` | Ingress controller | 3–5 follow-up |
| `cert-manager/` | TLS certificates; a local CA, Let's Encrypt on Azure | 3–5 follow-up |
| `kyverno/` | Admission policies: registries, tags, non-root, probes, limits, signatures | 7 |
| `monitoring/` | kube-prometheus-stack: Prometheus, Alertmanager, Grafana | 8 |
| `otel-operator/`, `tracing/` | OpenTelemetry Operator, collector and Tempo | 8 |
| `keda/` | Event-driven autoscaling | 9 |
| `chaos-mesh/` | Chaos experiments | 9 |
| `velero/` | Backup and restore drills | 9 |
