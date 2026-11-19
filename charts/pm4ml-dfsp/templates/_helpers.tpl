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
{{- if not (has .Values.redis.mode (list "ha" "single" "external")) -}}{{ fail "redis.mode must be ha, single or external" }}{{- end -}}
{{- if and (eq .Values.redis.mode "ha") (not .Values.redis.ha.enabled) -}}{{ fail "redis.mode is ha: set redis.ha.enabled: true (it enables the redis-ha subchart)" }}{{- end -}}
{{- if and (ne .Values.redis.mode "ha") .Values.redis.ha.enabled -}}{{ fail "redis.mode is not ha: set redis.ha.enabled: false, or the redis-ha subchart is installed for nothing" }}{{- end -}}
{{- if and (eq .Values.redis.mode "ha") (ne .Release.Name "pm4ml") (eq (index .Values "redis-ha" "existingSecret") "pm4ml-redis-auth") -}}
{{- fail (printf "redis-ha.existingSecret: set it to %s-redis-auth (the default pm4ml-redis-auth is for a release named pm4ml; releases sharing a namespace must not share a Redis password)" .Release.Name) -}}
{{- end -}}
{{- if and (not .Values.store.persistence.enabled) (not .Values.store.persistence.acceptDataLoss) -}}
{{- fail "store.persistence.enabled is false: the store (DFSP CA, keys, enrolment) would be lost whenever its pod is recreated, including by a helm upgrade. Set store.persistence.acceptDataLoss: true only for throwaway tests" -}}
{{- end -}}
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

{{/* Redis host of this release. The redis-ha subchart names its Services from the
release name, not from fullnameOverride. */}}
{{- define "dfsp.redisHost" -}}
{{- if eq .Values.redis.mode "ha" -}}{{ .Release.Name }}-redis-ha-haproxy
{{- else -}}{{ include "dfsp.fullname" . }}-redis{{- end -}}
{{- end -}}

{{- define "dfsp.sdkName" -}}{{ include "dfsp.fullname" . }}-sdk{{- end -}}
{{- define "dfsp.mgmtName" -}}{{ include "dfsp.fullname" . }}-management-api{{- end -}}
{{- define "dfsp.ccName" -}}{{ include "dfsp.fullname" . }}-core-connector{{- end -}}

{{- define "dfsp.backend" -}}
{{- if .Values.coreConnector.enabled -}}{{ include "dfsp.ccName" . }}:{{ .Values.coreConnector.port }}{{ .Values.coreConnector.backendPath }}
{{- else -}}{{ required "coreConnector.externalBackendEndpoint is required when coreConnector.enabled is false" .Values.coreConnector.externalBackendEndpoint }}{{- end -}}
{{- end -}}
