{{/*
Base name for this release, honoring nameOverride.
*/}}
{{- define "rbt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name -- prefixes resource names with the release name,
unless fullnameOverride is set, or the release name already contains the
chart name (standard helm-create convention).
*/}}
{{- define "rbt.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "rbt.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "rbt.labels" -}}
helm.sh/chart: {{ include "rbt.chart" . }}
{{ include "rbt.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels -- kept separate from rbt.labels because selectors are
immutable on Deployments/Services and must never pick up
commonLabels/version churn across upgrades.
*/}}
{{- define "rbt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rbt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Name of the Secret holding S3 credentials -- either the user-supplied
existingSecret, or the one templates/secret-s3.yaml creates.
*/}}
{{- define "rbt.s3SecretName" -}}
{{- if .Values.s3.existingSecret -}}
{{- .Values.s3.existingSecret -}}
{{- else -}}
{{- printf "%s-s3" (include "rbt.fullname" .) -}}
{{- end -}}
{{- end -}}
