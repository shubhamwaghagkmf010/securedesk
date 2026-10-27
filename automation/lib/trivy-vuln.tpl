{{- range . -}}
{{- range .Vulnerabilities -}}
{{ .Severity }}|{{ .VulnerabilityID }}|{{ .PkgName }}|{{ .InstalledVersion }}|{{ .FixedVersion }}
{{ end -}}
{{- end -}}
