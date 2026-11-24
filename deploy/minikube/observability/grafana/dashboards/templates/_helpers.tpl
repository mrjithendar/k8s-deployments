{{/*
ConfigMap grafana-dashboards-public-<folder>: the dashboards values `public.folders.<folder>` lists, for the Grafana org
"Public" (anonymous, read-only). Rendered only while public.enabled. The JSON is the same as in the folder's own
ConfigMap: chart files, or .Values.jithendar for the jithendar folder. A listed file that does not exist fails the render.
*/}}
{{- define "dashboards.public" -}}
{{- $root := .root }}
{{- $key := .folder }}
{{- if $root.Values.public.enabled }}
{{- $folder := required (printf "public.folders.%s is missing" $key) (index $root.Values.public.folders $key) }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-public-{{ $key }}
  namespace: monitoring
data:
  {{- range $file := $folder.dashboards }}
  {{- $json := "" }}
  {{- if eq $key "jithendar" }}
  {{- $json = index $root.Values.jithendar $file | default "" }}
  {{- else }}
  {{- $json = $root.Files.Get $file }}
  {{- end }}
  {{- if not $json }}{{ fail (printf "public dashboard %s/%s does not exist" $key $file) }}{{ end }}
  {{ $file }}: |-
    {{- $json | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
