{{- /* Markdown table of the vulnerabilities of a Trivy report, one row each, in Trivy's order (severity, then ID). Used by images.yaml. */ -}}
| Severity | CVE | Package | Installed | Fixed in |
|---|---|---|---|---|
{{- range . }}
{{- range .Vulnerabilities }}
| {{ if eq .Severity "CRITICAL" }}🟥{{ else }}🟧{{ end }} {{ .Severity }} | {{ if .PrimaryURL }}[{{ .VulnerabilityID }}]({{ .PrimaryURL }}){{ else }}{{ .VulnerabilityID }}{{ end }} | `{{ .PkgName }}` | `{{ .InstalledVersion }}` | {{ if .FixedVersion }}`{{ .FixedVersion }}`{{ else }}–{{ end }} |
{{- end }}
{{- end }}
