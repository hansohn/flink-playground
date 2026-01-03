{{/*
Expand the name of the chart.
*/}}
{{- define "prometheus.name" -}}
{{- .Chart.Name -}}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "prometheus.fullname" -}}
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

{{/*
Common labels
*/}}
{{- define "prometheus.labels" -}}
app.kubernetes.io/name: {{ include "prometheus.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "prometheus.selectorLabels" -}}
app.kubernetes.io/name: {{ include "prometheus.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Prometheus server component name
*/}}
{{- define "prometheus.prometheusName" -}}
{{- printf "%s-prometheus" (include "prometheus.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Prometheus adapter component name
*/}}
{{- define "prometheus.adapterName" -}}
{{- printf "%s-adapter" (include "prometheus.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
