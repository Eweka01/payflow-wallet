{{/*
Common labels applied to every resource.
*/}}
{{- define "payflow.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.global.imageTag | quote }}
environment: {{ .Values.global.environment }}
{{- end }}

{{/*
Selector labels for a given service (passed as a string).
Usage: {{ include "payflow.selectorLabels" (dict "service" "api-gateway") }}
*/}}
{{- define "payflow.selectorLabels" -}}
app: {{ .service }}
{{- end }}

{{/*
Full ECR image reference for a service.
Usage: {{ include "payflow.image" (dict "service" "api-gateway" "Values" .Values) }}
*/}}
{{- define "payflow.image" -}}
{{ .Values.global.registry }}/{{ .Values.global.imagePrefix }}/{{ .service }}:{{ .Values.global.imageTag }}
{{- end }}

{{/*
Standard security context applied to all Node.js service containers.
*/}}
{{- define "payflow.securityContext" -}}
allowPrivilegeEscalation: false
runAsUser: 1000
runAsGroup: 1000
readOnlyRootFilesystem: false
{{- end }}

{{/*
DB + Redis environment variables sourced from the db-secrets Secret (populated by ESO).
Included by every backend service.
*/}}
{{- define "payflow.dbEnv" -}}
- name: DB_HOST
  valueFrom:
    secretKeyRef:
      name: db-secrets
      key: DB_HOST
- name: DB_PORT
  valueFrom:
    secretKeyRef:
      name: db-secrets
      key: DB_PORT
- name: DB_NAME
  valueFrom:
    configMapKeyRef:
      name: app-config
      key: DB_NAME
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: db-secrets
      key: DB_USER
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-secrets
      key: DB_PASSWORD
- name: PGSSLMODE
  value: "require"
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      name: db-secrets
      key: REDIS_URL
{{- end }}

{{/*
RabbitMQ URL — only transaction-service and notification-service need this.
*/}}
{{- define "payflow.mqEnv" -}}
- name: RABBITMQ_URL
  valueFrom:
    secretKeyRef:
      name: db-secrets
      key: RABBITMQ_URL
{{- end }}
