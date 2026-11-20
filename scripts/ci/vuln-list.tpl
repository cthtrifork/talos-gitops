{{- /* one row per vulnerability, in Trivy's order */ -}}
| Severity | CVE | Package | Installed | Fixed in |
|---|---|---|---|---|
{{- range . }}
{{- range .Vulnerabilities }}
| {{ if eq .Severity "CRITICAL" }}🟥{{ else }}🟧{{ end }} {{ .Severity }} | {{ if .PrimaryURL }}[{{ .VulnerabilityID }}]({{ .PrimaryURL }}){{ else }}{{ .VulnerabilityID }}{{ end }} | `{{ .PkgName }}` | `{{ .InstalledVersion }}` | {{ if .FixedVersion }}`{{ .FixedVersion }}`{{ else }}–{{ end }} |
{{- end }}
{{- end }}
