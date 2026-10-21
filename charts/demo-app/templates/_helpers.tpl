{{/* Common labels */}}
{{- define "demo-app.labels" -}}
app.kubernetes.io/part-of: banking-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Container security context shared by all workloads */}}
{{- define "demo-app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: ["ALL"]
seLinuxOptions:
  type: container_t
{{- end -}}
