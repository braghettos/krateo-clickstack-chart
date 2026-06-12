{{- define "krateo-clickstack-agent.genaiEnv" -}}
{{- if .Values.vertexAI.enabled }}
- name: GOOGLE_GENAI_USE_VERTEXAI
  value: "1"
- name: GOOGLE_CLOUD_PROJECT
  value: {{ .Values.vertexAI.projectID | quote }}
- name: GOOGLE_CLOUD_LOCATION
  value: {{ .Values.vertexAI.location | quote }}
{{- else }}
- name: GOOGLE_GENAI_USE_VERTEXAI
  value: "0"
{{- end }}
{{- end -}}
