{{/* Chart name */}}
{{- define "metrics-server.name" -}}
{{ .Chart.Name }}
{{- end }}

{{/* Fully qualified name */}}
{{- define "metrics-server.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Common labels */}}
{{- define "metrics-server.labels" -}}
app.kubernetes.io/name: {{ include "metrics-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Selector labels */}}
{{- define "metrics-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "metrics-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
