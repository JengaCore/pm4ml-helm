{{- define "dfsp.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 40 | trimSuffix "-" }}
{{- else -}}{{ .Release.Name | trunc 40 | trimSuffix "-" }}{{- end -}}
{{- end -}}

{{- define "dfsp.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: pm4ml-dfsp
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* selector labels: component name + instance */}}
{{- define "dfsp.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{- define "dfsp.required" -}}
{{- $_ := required "dfspId is required" .Values.dfspId -}}
{{- $_ := required "switch.domain is required" .Values.switch.domain -}}
{{- $_ := required "switch.currency is required" .Values.switch.currency -}}
{{- $_ := required "callback.host is required" .Values.callback.host -}}
{{- end -}}

{{- define "dfsp.fspiopHost" -}}{{ .Values.switch.fspiopHost | default (printf "fspiop.%s" .Values.switch.domain) }}{{- end -}}
{{- define "dfsp.mcmUrl" -}}{{ .Values.switch.mcmUrl | default (printf "https://mcm.%s/pm4mlapi" .Values.switch.domain) }}{{- end -}}
{{- define "dfsp.keycloakUrl" -}}{{ .Values.switch.keycloakUrl | default (printf "https://keycloak.%s" .Values.switch.domain) }}{{- end -}}

{{- define "dfsp.mcmSecret" -}}{{ .Values.mcm.clientSecret.existingSecret | default (printf "%s-mcm" (include "dfsp.fullname" .)) }}{{- end -}}
{{- define "dfsp.storeName" -}}{{ include "dfsp.fullname" . }}-vault{{- end -}}
{{- define "dfsp.storeAddr" -}}http://{{ include "dfsp.storeName" . }}:8200{{- end -}}
{{- define "dfsp.sealSecret" -}}{{ .Values.store.sealSecret | default (printf "%s-openbao-seal" (include "dfsp.fullname" .)) }}{{- end -}}
{{- define "dfsp.redisAuthSecret" -}}
{{- if eq .Values.redis.mode "ha" -}}{{ required "redis-ha.existingSecret is required with redis.mode ha" (index .Values "redis-ha" "existingSecret") }}
{{- else -}}{{ include "dfsp.fullname" . }}-redis-auth{{- end -}}
{{- end -}}

{{/* Host:port of the Redis this release uses (wait-for-redis, and the default URL) */}}
{{- define "dfsp.redisHost" -}}
{{- if eq .Values.redis.mode "ha" -}}{{ include "dfsp.fullname" . }}-redis-ha-haproxy
{{- else -}}{{ include "dfsp.fullname" . }}-redis{{- end -}}
{{- end -}}

{{- define "dfsp.sdkName" -}}{{ include "dfsp.fullname" . }}-sdk{{- end -}}
{{- define "dfsp.mgmtName" -}}{{ include "dfsp.fullname" . }}-management-api{{- end -}}
{{- define "dfsp.ccName" -}}{{ include "dfsp.fullname" . }}-core-connector{{- end -}}

{{- define "dfsp.backend" -}}
{{- if .Values.coreConnector.enabled -}}{{ include "dfsp.ccName" . }}:{{ .Values.coreConnector.port }}{{ .Values.coreConnector.backendPath }}
{{- else -}}{{ required "coreConnector.externalBackendEndpoint is required when coreConnector.enabled is false" .Values.coreConnector.externalBackendEndpoint }}{{- end -}}
{{- end -}}
