{{/* Base chart name */}}
{{- define "flink-autoscale.name" -}}
{{ .Chart.Name }}
{{- end }}

{{/* Fully qualified base name */}}
{{- define "flink-autoscale.fullname" -}}
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
{{- define "flink-autoscale.labels" -}}
app.kubernetes.io/name: {{ include "flink-autoscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Selector labels */}}
{{- define "flink-autoscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "flink-autoscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Resource names */}}
{{- define "flink-autoscale.jmName" -}}
{{- printf "%s-jobmanager" (include "flink-autoscale.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "flink-autoscale.tmName" -}}
{{- printf "%s-taskmanager" (include "flink-autoscale.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
