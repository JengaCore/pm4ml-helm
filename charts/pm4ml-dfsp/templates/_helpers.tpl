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
{{- /* 0.1.x keys: refused rather than silently ignored (an old values file would
otherwise render a single Valkey node where it asked for HA). */ -}}
{{- if or (hasKey .Values.redis "mode") (hasKey .Values.redis "ha") (hasKey .Values.redis "single") (hasKey .Values "redis-ha") -}}
{{- fail "redis.mode / redis.ha / redis.single / redis-ha are 0.1.x settings: Redis is now the valkey subchart. For HA add -f presets/valkey-ha.yaml; for a managed Redis, presets/redis-external.yaml (README: Upstream charts and presets)" -}}
{{- end -}}
{{- if or (hasKey .Values.store "type") (hasKey .Values.store "persistence") (hasKey .Values.store "image") (hasKey .Values.store "sealSecret") -}}
{{- fail "store.type / store.persistence / store.image / store.sealSecret are 0.1.x settings: the store is now the openbao or vault subchart (openbao.server.*, vault.server.*, presets/store-vault.yaml)" -}}
{{- end -}}
{{- if eq (len (compact (list .Values.openbao.enabled .Values.vault.enabled))) 0 -}}{{ fail "enable one secret store: openbao.enabled or vault.enabled" }}{{- end -}}
{{- if and .Values.openbao.enabled .Values.vault.enabled -}}{{ fail "enable one secret store only: openbao.enabled or vault.enabled" }}{{- end -}}
{{- if and (not .Values.valkey.enabled) (not .Values.redis.external.urlSecret) -}}{{ fail "valkey.enabled is false: set redis.external.urlSecret (a managed Redis), or keep valkey.enabled" }}{{- end -}}
{{- if .Values.valkey.enabled -}}
{{- $v := .Values.valkey -}}
{{- if and $v.replica.enabled (not (and $v.sentinel.enabled $v.haproxy.enabled)) -}}{{ fail "valkey.replica.enabled needs valkey.sentinel.enabled and valkey.haproxy.enabled too (presets/valkey-ha.yaml): without them clients may write to a replica" }}{{- end -}}
{{- if and (not $v.replica.enabled) (or $v.sentinel.enabled $v.haproxy.enabled) -}}{{ fail "valkey.sentinel/haproxy need valkey.replica.enabled (presets/valkey-ha.yaml)" }}{{- end -}}
{{- end -}}
{{- if and .Values.openbao.enabled (ne .Release.Name "pm4ml") (eq (include "dfsp.sealSecret" .) "pm4ml-openbao-seal") -}}
{{- fail (printf "openbao.server.volumes: set the seal Secret to %s-openbao-seal (pm4ml-openbao-seal is the default for a release named pm4ml; releases must not share a seal key)" .Release.Name) -}}
{{- end -}}
{{- if and .Values.networkPolicies.enabled (not .Values.coreConnector.enabled) (not .Values.networkPolicies.sdkOutboundFrom) -}}
{{- fail "coreConnector.enabled is false and networkPolicies are on: list the external core connector's pods in networkPolicies.sdkOutboundFrom, or no payment request reaches the SDK (port 4001)" -}}
{{- end -}}
{{- if and (not (index .Values (include "dfsp.storeKind" .) "server" "dataStorage" "enabled")) (not .Values.store.acceptDataLoss) -}}
{{- fail "the secret store has no volume (openbao/vault .server.dataStorage.enabled false): the DFSP CA, keys and enrolment would be lost whenever its pod is recreated, including by a helm upgrade. Set store.acceptDataLoss: true only for throwaway tests" -}}
{{- end -}}
{{- end -}}

{{- define "dfsp.fspiopHost" -}}{{ .Values.switch.fspiopHost | default (printf "fspiop.%s" .Values.switch.domain) }}{{- end -}}
{{- define "dfsp.mcmUrl" -}}{{ .Values.switch.mcmUrl | default (printf "https://mcm.%s/pm4mlapi" .Values.switch.domain) }}{{- end -}}
{{- define "dfsp.keycloakUrl" -}}{{ .Values.switch.keycloakUrl | default (printf "https://keycloak.%s" .Values.switch.domain) }}{{- end -}}

{{- define "dfsp.mcmSecret" -}}{{ .Values.mcm.clientSecret.existingSecret | default (printf "%s-mcm" (include "dfsp.fullname" .)) }}{{- end -}}
{{/* Name of a subchart's resources, as the upstream charts compute it (release name,
or <release>-<chart> unless the release name already contains the chart name). */}}
{{- define "dfsp.subFullname" -}}
{{- $ctx := index . 0 -}}{{- $chart := index . 1 -}}
{{- $o := index $ctx.Values $chart "fullnameOverride" | default "" -}}
{{- if $o -}}{{ $o | trunc 63 | trimSuffix "-" }}
{{- else if contains $chart $ctx.Release.Name -}}{{ $ctx.Release.Name | trunc 63 | trimSuffix "-" }}
{{- else -}}{{ printf "%s-%s" $ctx.Release.Name $chart | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- end -}}

{{- define "dfsp.storeKind" -}}{{ ternary "openbao" "vault" (.Values.openbao.enabled | default false) }}{{- end -}}
{{- define "dfsp.storeName" -}}{{ include "dfsp.subFullname" (list . (include "dfsp.storeKind" .)) }}{{- end -}}
{{- define "dfsp.storeAddr" -}}http://{{ include "dfsp.storeName" . }}:8200{{- end -}}
{{- define "dfsp.storeImage" -}}
{{- $i := index .Values (include "dfsp.storeKind" .) "server" "image" -}}
{{- if $i.registry }}{{ $i.registry }}/{{ end }}{{ $i.repository }}:{{ $i.tag }}
{{- end -}}
{{/* The OpenBao seal Secret: the "seal" volume of the openbao subchart. */}}
{{- define "dfsp.sealSecret" -}}
{{- range .Values.openbao.server.volumes -}}{{- if eq .name "seal" -}}{{ .secret.secretName }}{{- end -}}{{- end -}}
{{- end -}}
{{- define "dfsp.redisAuthSecret" -}}{{ .Release.Name }}-redis-auth{{- end -}}
{{/* Where clients reach Valkey: HAProxy (always the master) in HA, the service otherwise. */}}
{{- define "dfsp.redisHost" -}}
{{- $v := include "dfsp.subFullname" (list . "valkey") -}}
{{- if .Values.valkey.haproxy.enabled -}}{{ $v | trunc 54 | trimSuffix "-" }}-haproxy{{- else -}}{{ $v }}{{- end -}}
{{- end -}}
{{/* Pods allowed through Valkey's NetworkPolicy (allowExternal: false). */}}
{{- define "dfsp.valkeyClientLabel" -}}
{{- if .Values.valkey.enabled }}
{{ include "dfsp.subFullname" (list . "valkey") }}-client: "true"
{{- end -}}
{{- end -}}

{{- define "dfsp.sdkName" -}}{{ include "dfsp.fullname" . }}-sdk{{- end -}}
{{- define "dfsp.mgmtName" -}}{{ include "dfsp.fullname" . }}-management-api{{- end -}}
{{- define "dfsp.ccName" -}}{{ include "dfsp.fullname" . }}-core-connector{{- end -}}

{{- define "dfsp.backend" -}}
{{- if .Values.coreConnector.enabled -}}{{ include "dfsp.ccName" . }}:{{ .Values.coreConnector.port }}{{ .Values.coreConnector.backendPath }}
{{- else -}}{{ required "coreConnector.externalBackendEndpoint is required when coreConnector.enabled is false" .Values.coreConnector.externalBackendEndpoint }}{{- end -}}
{{- end -}}
