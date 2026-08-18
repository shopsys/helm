{{/*
Shared helpers for Shopsys deployment charts.

Naming convention: all helpers are prefixed "shopsys.".
Helpers that operate on a single domain entry take a dict:
  (dict "root" $ "domain" $domain "index" $i)
*/}}

{{/* Standard resource labels (https://helm.sh/docs/chart_best_practices/labels/).
     The legacy `app` selector labels are kept alongside these — selectors are immutable
     on existing Deployments, so they must never change. */}}
{{- define "shopsys.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/* Full image reference. Tag is optional — when empty, "repository" is treated
     as a complete reference (used by CI which provides one full image ref in TAG). */}}
{{- define "shopsys.image" -}}
{{- if .tag -}}
{{- printf "%s:%s" .repository .tag -}}
{{- else -}}
{{- .repository -}}
{{- end -}}
{{- end }}

{{/* Hostname part of a domain (before the first slash).
     "example.com/en" -> "example.com" */}}
{{- define "shopsys.domain.base" -}}
{{- splitList "/" . | first -}}
{{- end }}

{{/* Path part of a path-based domain (after the last slash, legacy semantics).
     "example.com/en" -> "en", "example.com" -> "" */}}
{{- define "shopsys.domain.path" -}}
{{- if contains "/" . -}}
{{- splitList "/" . | last -}}
{{- end -}}
{{- end }}

{{/* Counterpart hostname for the www/non-www redirect. */}}
{{- define "shopsys.domain.redirect" -}}
{{- $base := include "shopsys.domain.base" . -}}
{{- if hasPrefix "www." $base -}}
{{- trimPrefix "www." $base -}}
{{- else -}}
{{- printf "www.%s" $base -}}
{{- end -}}
{{- end }}

{{/* TLS secret name shared by all ingresses of the same hostname.
     Sanitized to lowercase alphanumerics and hyphens, no leading/trailing hyphens. */}}
{{- define "shopsys.domain.tlsSecretName" -}}
{{- $base := include "shopsys.domain.base" . | lower -}}
{{- $sanitized := regexReplaceAll "[^a-z0-9-]" $base "-" -}}
{{- $sanitized = regexReplaceAll "^-+" $sanitized "" -}}
{{- $sanitized = regexReplaceAll "-+$" $sanitized "" -}}
{{- printf "tls-%s" $sanitized -}}
{{- end }}

{{/* Whether HTTP basic auth protects the given domain.
     Returns "1" or "" (usable in `if`). ctx: (dict "root" $ "domain" $d) */}}
{{- define "shopsys.domain.httpAuthEnabled" -}}
{{- if or .root.Values.security.httpAuth.enabled .domain.forceHttpAuth -}}1{{- end -}}
{{- end }}

{{/* Whether the domain is routed through Cloudflare.
     Returns "1" or "". ctx: (dict "root" $ "domain" $d) */}}
{{- define "shopsys.domain.cloudflareEnabled" -}}
{{- if and .root.Values.security.cloudflare.enabled (not .domain.cloudflareExcluded) -}}1{{- end -}}
{{- end }}

{{/* Name of the Secret holding the htpasswd content for HTTP basic auth.
     An externally managed secret (security.httpAuth.existingSecret) takes precedence
     over the chart-managed "http-auth" secret. */}}
{{- define "shopsys.httpAuthSecretName" -}}
{{- .Values.security.httpAuth.existingSecret | default "http-auth" -}}
{{- end }}

{{/* htpasswd content of the chart-managed http-auth secret, generated from
     username + password via the Sprig htpasswd function (bcrypt).
     NOTE: the generated hash uses a random salt, so it is NOT deterministic across
     renders - golden test scenarios must use existingSecret instead. */}}
{{- define "shopsys.httpAuthContent" -}}
{{- $auth := .Values.security.httpAuth -}}
{{- if and $auth.username $auth.password -}}
{{- htpasswd $auth.username $auth.password -}}
{{- end -}}
{{- end }}

{{/* Pod imagePullSecrets list. The chart-managed "dockerregistry" entry is replaced
     by registry.existingSecret when the project brings its own pull secret; when the
     project's imagePullSecrets list does not reference it (e.g. a customized or empty
     list), the existing secret is appended so it is never silently ignored.
     Renders nothing when the resulting list is empty. */}}
{{- define "shopsys.imagePullSecrets" -}}
{{- $existing := (.Values.registry).existingSecret | default "" -}}
{{- $list := list -}}
{{- $covered := false -}}
{{- range .Values.imagePullSecrets -}}
{{- if and (eq . "dockerregistry") $existing -}}
{{- $list = append $list (dict "name" $existing) -}}
{{- $covered = true -}}
{{- else -}}
{{- $list = append $list (dict "name" .) -}}
{{- if eq . $existing -}}
{{- $covered = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $existing (not $covered) -}}
{{- $list = append $list (dict "name" $existing) -}}
{{- end -}}
{{- if $list -}}
{{- toYaml $list -}}
{{- end -}}
{{- end }}

{{/* Whether the http-auth secret / annotations are needed at all. Returns "1" or "". */}}
{{- define "shopsys.httpAuthNeeded" -}}
{{- $needed := .Values.security.httpAuth.enabled -}}
{{- range .Values.domains -}}
{{- if .forceHttpAuth -}}{{- $needed = true -}}{{- end -}}
{{- end -}}
{{- if $needed -}}1{{- end -}}
{{- end }}

{{/* Comma-joined whitelist of IPs allowed to bypass HTTP basic auth. */}}
{{- define "shopsys.whitelistIps" -}}
{{- join "," (.Values.security.whitelistIps | default list) -}}
{{- end }}

{{/* Pod template annotations used by all application workloads.
     ctx: (dict "root" $ "app" "<name>" "logging" "true|false") */}}
{{- define "shopsys.podAnnotations" -}}
logging/enabled: {{ .logging | quote }}
project/app: {{ .app | quote }}
project/environment: {{ .root.Values.project.environment | quote }}
project/name: {{ .root.Values.project.name | quote }}
{{- with .component }}
{{- with .podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}
{{- end }}

{{/* Render a map of environment variables as a container `env` list.
     Keys are sorted (Go template map iteration order), empty values are skipped
     and every value is rendered as a quoted string (escaping parity with legacy). */}}
{{- define "shopsys.envBlock" -}}
{{- range $key, $value := . }}
{{- if ne (toString $value) "" }}
- name: {{ $key }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/* Application (backend) env map: defaults merged with project overrides. */}}
{{- define "shopsys.appEnvMap" -}}
{{- $merged := mergeOverwrite (deepCopy (.Values.app.envDefaults | default dict)) (.Values.app.env | default dict) -}}
{{- toYaml $merged -}}
{{- end }}

{{/* Backend env list (webserver, cron, consumers, migration job) + component extraEnv. */}}
{{- define "shopsys.appEnv" -}}
{{- include "shopsys.envBlock" (include "shopsys.appEnvMap" .root | fromYaml) -}}
{{- with .component }}
{{- with .extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
{{- end }}

{{/* Content of the domains_urls file mounted into application pods. */}}
{{- define "shopsys.domainsUrls.data" -}}
domains_urls:
{{- range $i, $d := .Values.domains }}
  - id: {{ $d.id | default (add $i 1) }}
    url: https://{{ $d.hostname }}
{{- end }}
{{- end }}

{{/* Content of the cron-env .project_env.sh (exports for cron shell). */}}
{{- define "shopsys.cronEnv.data" -}}
{{- range $key, $value := (include "shopsys.appEnvMap" . | fromYaml) }}
{{- if ne (toString $value) "" }}
export {{ $key }}='{{ $value }}'
{{- end }}
{{- end }}
{{- end }}

{{/* Content of the cron-list crontab template. */}}
{{- define "shopsys.cronList.data" -}}
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
{{- range .Values.cron.instances }}
{{ .schedule }} . /root/.project_env.sh && cd /var/www/html/ && ./phing {{ .name }} > /dev/null 2>&1
{{- end }}
{{ end }}

{{/* Checksum annotations forcing a rollout when mounted configuration changes.
     ctx: (dict "root" $ "include" (list "domainsUrls" "appEnv" "cron" "nginx" "phpFpm")) */}}
{{- define "shopsys.checksums" -}}
{{- $root := .root -}}
{{- range .include }}
{{- if eq . "domainsUrls" }}
checksum/domains-urls: {{ include "shopsys.domainsUrls.data" $root | sha256sum }}
{{- else if eq . "appEnv" }}
checksum/app-env: {{ include "shopsys.appEnvMap" $root | sha256sum }}
{{- else if eq . "cron" }}
checksum/cron: {{ printf "%s%s" (include "shopsys.cronList.data" $root) (include "shopsys.cronEnv.data" $root) | sha256sum }}
{{- else if eq . "nginx" }}
checksum/nginx: {{ printf "%s%s" (include "shopsys.nginxConf" $root) (include "shopsys.projectNginxConf" $root) | sha256sum }}
{{- else if eq . "phpFpm" }}
checksum/php-fpm: {{ printf "%s%s" ($root.Values.webserver.phpFpm.config | default "") ($root.Values.webserver.phpFpm.opcacheConfig | default "") | sha256sum }}
{{- end }}
{{- end }}
{{- end }}

{{/* Standard scheduling/security pod fields shared by every component.
     ctx: (dict "root" $ "component" <component values>)
     Rendered at zero indent — use `| nindent N` at the call site. */}}
{{- define "shopsys.podSettings" -}}
{{- with .component.nodeSelector }}
nodeSelector:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .component.tolerations }}
tolerations:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .component.affinity }}
affinity:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .component.podSecurityContext }}
securityContext:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .component.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- if ne .pullSecrets false }}
{{- $pullSecrets := include "shopsys.imagePullSecrets" .root }}
{{- if $pullSecrets }}
imagePullSecrets:
  {{- $pullSecrets | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/* Standard per-container fields (probes, security, lifecycle overrides).
     ctx: component (or container) values dict. Zero indent. */}}
{{- define "shopsys.containerSettings" -}}
{{- with .securityContext }}
securityContext:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .livenessProbe }}
livenessProbe:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .readinessProbe }}
readinessProbe:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end }}

{{/* Default nginx.conf shipped with the chart, overridable via webserver.nginx.config. */}}
{{- define "shopsys.nginxConf" -}}
{{- if .Values.webserver.nginx.config -}}
{{- tpl .Values.webserver.nginx.config . -}}
{{- else -}}
{{- tpl (.Files.Get "files/nginx/nginx.conf") . -}}
{{- end -}}
{{- end }}

{{/* Default project-nginx.conf (vhost), overridable via webserver.nginx.projectConfig. */}}
{{- define "shopsys.projectNginxConf" -}}
{{- if .Values.webserver.nginx.projectConfig -}}
{{- tpl .Values.webserver.nginx.projectConfig . -}}
{{- else -}}
{{- tpl (.Files.Get "files/nginx/project-nginx.conf") . -}}
{{- end -}}
{{- end }}
