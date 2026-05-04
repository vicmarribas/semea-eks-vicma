{{/*
Expand the name of the chart.
*/}}
{{- define "stock-demo.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Namespace: "stock-<customer>" unless values.namespace.name is explicitly set.
*/}}
{{- define "stock-demo.namespace" -}}
{{- if .Values.namespace.name -}}
  {{- .Values.namespace.name }}
{{- else -}}
  stock-{{ .Values.customer }}
{{- end }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "stock-demo.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
team: semea
customer: {{ .Values.customer }}
{{- end }}

{{/*
Selector labels for a given component (pass component name as $.component).
*/}}
{{- define "stock-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Datadog Unified Service Tagging labels.
*/}}
{{- define "stock-demo.ddLabels" -}}
tags.datadoghq.com/env: {{ .Values.datadog.env | quote }}
tags.datadoghq.com/service: {{ .component | quote }}
tags.datadoghq.com/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
DD_AGENT_HOST env var — uses hostIP unless datadog.agentHost is set.
*/}}
{{- define "stock-demo.ddAgentHostEnv" -}}
- name: DD_AGENT_HOST
{{- if .Values.datadog.agentHost }}
  value: {{ .Values.datadog.agentHost | quote }}
{{- else }}
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
{{- end }}
{{- end }}

{{/*
Name of the shared secret.
*/}}
{{- define "stock-demo.secretName" -}}
{{ .Release.Name }}-secrets
{{- end }}
