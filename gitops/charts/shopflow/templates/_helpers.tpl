{{/*
Image reference for one of our services. Every service in a release runs the
same tag: the git commit the app pipeline built and scanned.
  {{ include "shopflow.image" (list . "order-service") }}
*/}}
{{- define "shopflow.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- required "image.tag is required" $root.Values.image.tag | printf "%s/shopflow/%s:%s" $root.Values.image.registry $name -}}
{{- end -}}

{{/*
Pod annotations for one service: Prometheus scrape hints, and OpenTelemetry
auto-instrumentation when tracing is on (the OpenTelemetry Operator injects
the agent, so the service code doesn't change). Go has no injected agent.
  {{ include "shopflow.podAnnotations" (list . "order-service" "java") }}
*/}}
{{- define "shopflow.podAnnotations" -}}
{{- $root := index . 0 -}}
{{- $lang := index . 2 -}}
{{- if and $root.Values.observability.tracing $lang -}}
annotations:
  instrumentation.opentelemetry.io/inject-{{ $lang }}: "shopflow"
{{- end -}}
{{- end -}}

{{/*
Non-empty when KEDA scales this workload, so the Deployment leaves replicas alone.
*/}}
{{- define "shopflow.autoscaled" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- if and $root.Values.autoscaling.enabled (hasKey $root.Values.autoscaling.workloads $name) -}}true{{- end -}}
{{- end -}}

{{/*
Secrets from Azure Key Vault (secrets.provider: keyvault). The Secrets Store
CSI driver reads them with the workload's managed identity and keeps the
shopflow-secrets Kubernetes secret in sync, so the env vars stay the same.
A pod has to mount the volume for the sync to happen, so every pod that
reads shopflow-secrets mounts it.
*/}}
{{- define "shopflow.keyvault" -}}
{{- eq .Values.secrets.provider "keyvault" -}}
{{- end -}}

{{- define "shopflow.serviceAccount" -}}
{{- if eq .Values.secrets.provider "keyvault" -}}
serviceAccountName: shopflow
{{- end -}}
{{- end -}}

{{- define "shopflow.secretsVolume" -}}
{{- if eq .Values.secrets.provider "keyvault" -}}
- name: keyvault
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: shopflow-keyvault
{{- end -}}
{{- end -}}

{{- define "shopflow.secretsMount" -}}
{{- if eq .Values.secrets.provider "keyvault" -}}
- name: keyvault
  mountPath: /mnt/secrets
  readOnly: true
{{- end -}}
{{- end -}}
