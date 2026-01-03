{{/*
Expand the name of the chart.
*/}}
{{- define "vertical-pod-autoscaler.name" -}}
{{- .Chart.Name -}}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "vertical-pod-autoscaler.fullname" -}}
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
{{- define "vertical-pod-autoscaler.labels" -}}
app.kubernetes.io/name: {{ include "vertical-pod-autoscaler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "vertical-pod-autoscaler.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vertical-pod-autoscaler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Recommender component name
*/}}
{{- define "vertical-pod-autoscaler.recommenderName" -}}
{{- printf "%s-recommender" (include "vertical-pod-autoscaler.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Updater component name
*/}}
{{- define "vertical-pod-autoscaler.updaterName" -}}
{{- printf "%s-updater" (include "vertical-pod-autoscaler.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Admission Controller component name
*/}}
{{- define "vertical-pod-autoscaler.admissionControllerName" -}}
{{- printf "%s-admission-controller" (include "vertical-pod-autoscaler.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
