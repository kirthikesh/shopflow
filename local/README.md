# ShopFlow on a laptop

The whole platform on a free [kind](https://kind.sigs.k8s.io) cluster: no Azure subscription needed.
Built and tested on an 8 GB MacBook Air (Docker with about 6 GB).

```bash
local/up.sh            # cluster, platform add-ons, images, app: about 10 minutes
local/down.sh          # delete it all
```

| URL | What |
|---|---|
| https://shop.localtest.me:9443 | The shop, through Traefik with a certificate from a local CA (cert-manager) |
| https://grafana.localtest.me:9443 | Grafana (admin / shopflow), with the ShopFlow dashboard and SLOs |

`*.localtest.me` also resolves to `::1` and the cluster only listens on IPv4, so browsers need
`127.0.0.1 shop.localtest.me grafana.localtest.me` in `/etc/hosts` (the load test pins it itself).

## What runs

| Add-on | Version | Why |
|---|---|---|
| cert-manager | 1.21.3 | Local CA and the shop's TLS certificate |
| Traefik | 3.7.19 (chart 42.4.1) | Ingress on ports 9080/9443 |
| Kyverno | 1.20.0 | Admission policies (CEL `ValidatingPolicy`) |
| kube-prometheus-stack | 93.4.0 | Prometheus, Grafana, the SLO rules and dashboard |
| KEDA | 2.21.1 | Scales product-service on its request rate |
| Velero | 1.15 (chart 8.0.0) + SeaweedFS | Backup and restore drill |

## Demos

```bash
kubectl -n shopflow-local run test --image=nginx:latest   # Kyverno rejects it
make load-test                                            # k6, 12 shoppers, 5 minutes
make backup-drill                                         # back up, delete the namespace, restore
make chaos-test                                           # Chaos Mesh + k6 (see below)
make tracing-on                                           # OpenTelemetry + Tempo (see below)
```

## Results (18 Nov 2026, 8 GB MacBook Air)

**Kyverno** rejected `nginx:latest` on three policies at once: the `latest` tag, no resource
requests or limits, and an untrusted registry.

**Load test** (12 shoppers, 5 minutes):

| | Result | Threshold |
|---|---|---|
| Failed requests | 0.87% | < 1% ✓ |
| Orders placed | 96.5% | > 99% ✗ |
| Product list p95 | 2.25 s | < 500 ms ✗ |

The thresholds are the production SLOs; a laptop running the whole platform misses the latency
ones, and k6 fails the run, which is exactly how it would stop a release in a pipeline.

**KEDA** read the request rate from Prometheus and scaled product-service from 1 to 2 to 3 pods
during the test, then back down.

**Backup drill:** Velero backed up the namespace and its pod volumes, the namespace was deleted,
and Velero restored it (83 resources); every pod was running again. The Postgres rows did not come back:
kind's storage is a `hostPath` volume, which Velero's file-system backup skips. On AKS the disk is an
Azure Disk and Velero snapshots it with CSI; locally the fix would be a `pg_dump` pre-backup hook.

## Limits of a laptop

- **No Service Bus.** The emulator needs SQL Server (2 GB, emulated on Apple Silicon), so locally
  orders are saved as `PENDING_PAYMENT` and payment-service and notification-service aren't
  deployed. `MESSAGING=1 local/up.sh` turns them on where there's memory for it.
- **The cluster doesn't survive a restart.** etcd runs in memory (`kind.yaml`), because the Docker
  disk was too slow for it and the control plane kept timing out. After `docker stop` or a Docker
  restart, run `local/down.sh && local/up.sh`.
- **Tracing and the chaos test are written but haven't run here.** Both add several hundred MB
  (OpenTelemetry Operator, collector and Tempo; Chaos Mesh), which this machine didn't have to spare
  next to everything else.

## Problems I hit, and how I fixed them

| Problem | Cause | Fix |
|---|---|---|
| `Bind for 0.0.0.0:80 failed: port is already allocated` | Another container had port 80 | The cluster uses 9080/9443 |
| Docker Desktop crashed: disk full | Old images and 12 GB of build cache, 7 GB free | Cleared caches and the build cache; images are built only when missing |
| Control plane restarting, `etcdserver: request timed out` | A second kind cluster (another project) and SQL Server competing for 6 GB; etcd on a slow disk | Stopped the other cluster, dropped the Service Bus emulator locally, moved etcd to tmpfs |
| Kyverno rejected every policy | Kyverno 1.20 no longer accepts `ClusterPolicy` | Rewrote them as CEL `ValidatingPolicy` / `ImageValidatingPolicy` |
| Traefik values rejected: `additional properties 'type' not allowed` | The chart moved it to `service.spec.type` | Updated the values |
| Grafana killed while starting | First-start migrations took longer than the liveness probe allowed | 5-minute initial delay |
| Every request 503, pods restarting under load | 1-second probe timeouts and tiny CPU requests on a busy node | 3-second probe timeouts and real CPU shares for the request path |
| k6: `connection refused` on `[::1]` | `localtest.me` resolves to IPv6 too | k6 `hosts` pin, `/etc/hosts` for the browser |
| Velero stuck installing | Its CRD-upgrade hook uses `bitnami/kubectl`, gone from Docker Hub | `upgradeCRDs: false` |
| MinIO image `401 UNAUTHORIZED` | MinIO stopped publishing images | SeaweedFS as the S3 store |
| Kopia: `Signed request requires setting up SeaweedFS S3 authentication` | No S3 identity configured | An identity matching Velero's credentials |
