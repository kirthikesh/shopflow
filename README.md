# ShopFlow

![Azure](https://img.shields.io/badge/Azure-AKS-111?style=flat-square&logo=microsoftazure&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-landing_zone-111?style=flat-square&logo=terraform&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/Azure_DevOps-Pipelines-111?style=flat-square&logo=azuredevops&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo_CD-GitOps-111?style=flat-square&logo=argo&logoColor=white)
![Argo Rollouts](https://img.shields.io/badge/Argo_Rollouts-canary-111?style=flat-square&logo=argo&logoColor=white)
![Ansible](https://img.shields.io/badge/Ansible-agent-111?style=flat-square&logo=ansible&logoColor=white)
![Trivy](https://img.shields.io/badge/Trivy-CVE_gate-111?style=flat-square)

An event-driven microservices store and the enterprise Azure platform it runs on, built end to end:
six services in five languages, a Terraform landing zone, AKS, Azure DevOps pipelines that authenticate
with a managed identity, and GitOps releases with Argo CD, including canary releases in prod.

> **Status:** Phases 1–6 ran on Azure; the environment is torn down to save cost, and the
> screenshots are from the last live release. Phases 7–9 run on a free **local cluster**
> ([`local/`](local)): policies, SLOs, autoscaling, load and backup tests, with results. Their
> Azure halves (Key Vault, Defender, Azure Policy, private API, image signing) are written and
> validated with `terraform validate`, not yet applied.

![ShopFlow running in prod on AKS](app/docs/images/shop-home.jpg)

---

## What's in here

| Folder | What it holds | Pipeline |
|---|---|---|
| [`app/`](app) | Six services (Python, Java, Go, Node, Next.js) over Azure Service Bus, and a local stack that runs it all on a laptop | Test → build + Trivy scan + SBOM → release to dev → approval → promote to prod |
| [`infra/`](infra) | Terraform landing zone (hub-spoke, private DNS, ACR, Key Vault, AKS, Service Bus, guardrails) and the Ansible-built agent | Validate + Trivy IaC → plan → approval → apply the saved plan |
| [`gitops/`](gitops) | Helm chart, per-environment values, the Argo CD ApplicationSet and the canary setup; cluster add-ons in [`gitops/platform`](gitops/platform) | None: Argo CD pulls from it |
| [`local/`](local) | The whole platform on a kind cluster, plus the load, chaos and backup tests | `local/up.sh` |
| [`tests/load`](tests/load) | k6 shopper journey with SLO thresholds | `make load-test` |

Each folder has its own README with the details, the design decisions and the problems I hit along the way.

## How it fits together

```mermaid
flowchart LR
    DEV([git push]) --> CHG{what changed?}
    CHG -->|infra/| IP[Infra pipeline<br/>plan → approval → apply]
    IP --> AZ[(Azure: hub-spoke,<br/>AKS, Service Bus, ACR)]
    CHG -->|app/| AP[App pipeline<br/>test → build → Trivy → push]
    AP --> ACR[(ACR<br/>tag = commit)]
    AP -->|commit tag| GD[gitops/envs/dev]
    GD -->|Argo CD| D[(shopflow-dev)]
    D --> OK{approval}
    OK -->|same tag| GP[gitops/envs/prod]
    GP -->|Argo CD +<br/>canary| P[(shopflow-prod)]
```

- **Each pipeline only runs for its own folder.** The release commit touches `gitops/` only, so it never starts another build.
- **No secrets in Azure DevOps.** The self-hosted agent signs in as its VM's managed identity, with role assignments limited by an ABAC condition. The only stored credential is a deploy key for this repository.
- **Prod runs exactly what dev ran.** Promotion copies the image tag that passed in dev; nothing is rebuilt.
- **Bad releases roll themselves back.** The prod frontend goes out as a canary: 50% of traffic, an automated health check, then 100%, or an automatic rollback.

## Screenshots

| | |
|---|---|
| ![App pipeline: test, build, release to dev, promote to prod](app/docs/images/app-pipeline.jpg) | ![Infra pipeline: validate, plan, apply](infra/docs/images/infra-pipeline.jpg) |
| App pipeline, all four stages | Infra pipeline, apply after approval |
| ![Canary passing its health check in prod](gitops/docs/images/canary-rollout.jpg) | ![Cart and checkout](app/docs/images/shop-cart.jpg) |
| Prod canary: 50% → health check → 100% | Checkout in prod |

## Quick start

```bash
# The whole platform on a free local Kubernetes cluster (kind)
local/up.sh                # https://shop.localtest.me:9443, Grafana on grafana.localtest.me:9443
make load-test             # k6 with SLO thresholds; KEDA scales product-service

# Just the shop with Docker Compose, including the Service Bus emulator
cd app && make up          # http://localhost:3000

# Build the Azure platform (needs an Azure subscription)
cd infra && make bootstrap && make up
```

## Roadmap

- [x] **Phase 1:** Six services, Dockerfiles, local stack with the Service Bus emulator
- [x] **Phase 2:** Terraform landing zone: hub-spoke network, private DNS, remote state, guardrails
- [x] **Phase 3:** AKS with Workload Identity, Cilium and Entra ID RBAC; real Service Bus
- [x] **Phase 4:** Ansible: hardened jump box and self-hosted Azure DevOps agent
- [x] **Phase 5:** Azure DevOps pipelines: templates, Trivy scanning, SBOMs, approvals, managed-identity auth
- [x] **Phase 6:** GitOps CD with Argo CD: dev and prod, approval-gated promotion, canary releases with Argo Rollouts
- [x] **Phases 3–5 follow-ups:** ingress with cert-manager (run locally); private API server and image signing (written for Azure)
- [x] **Phase 7:** Kyverno policies (run locally); Key Vault with Workload Identity, Defender for Containers, Azure Policy (written for Azure)
- [x] **Phase 8:** Prometheus, Grafana dashboard, SLOs with burn-rate alerts (run locally); OpenTelemetry tracing (written, not yet run)
- [x] **Phase 9:** KEDA autoscaling, k6 load test, Velero backup drill (run locally); Chaos Mesh experiments (written, not yet run)
- [x] **Phase 10:** Write-up: this README, [`local/README.md`](local/README.md) with the results and the problems I hit

Known follow-ups: a transactional outbox in the order service, stock reservation as a saga, a
`pg_dump` backup hook so the local drill restores Postgres rows too, and running the tracing and
chaos tests on a machine with more memory.

## History

ShopFlow started as three repositories (`shopflow-app`, `shopflow-infra`, `shopflow-gitops`) and was
merged into this one with every commit kept: `git log -- app/` shows the application's full history.
The pipelines and Argo CD now point here. That wiring hasn't run against Azure yet, because the
environment was torn down before the move.
