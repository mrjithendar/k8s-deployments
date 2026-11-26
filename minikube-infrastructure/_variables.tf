locals {
  # deploy/minikube in this repository: values files and local charts.
  minikube = "${path.module}/../deploy/minikube"

  # One extra value per local chart: a hash of every file in the chart directory. The helm provider plans only chart
  # version and values, so without it a template edit under an unchanged Chart.yaml version plans "No changes"
  # (the /prometheus and /loki VirtualServices never reached mk4, 2026-11-09). The charts ignore the value.
  local_charts = [
    "cert-manager/issuers", "gatekeeper/constraints", "gatekeeper/library", "harbor/access", "istio/edge", "istio/mesh", "observability/jaeger",
    "observability/loki", "observability/otel-collector", "observability/prometheus", "postgres/access",
    "redis/access", "storage/local-path-provisioner",
  ]
  chart_checksum = { for dir in local.local_charts : dir => yamlencode({
    chartChecksum = sha1(join("\n", [
      for f in sort(fileset("${local.minikube}/${dir}", "**")) : "${f} ${filesha1("${local.minikube}/${dir}/${f}")}"
    ]))
  }) }
}

variable "kubeconfig_path" {
  description = "Kubeconfig that contains the mk4 context."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context of the Minikube cluster."
  type        = string
  default     = "mk4"
}

variable "helm_timeout" {
  description = "Seconds Helm waits for each release to become ready."
  type        = number
  default     = 600
}



variable "postgres_allowed_ips" {
  description = "Client addresses (CIDRs) allowed through https://jithendar.com/postgres/ and postgres.jithendar.com:443 (postgres.tf). Everything else is refused on the gateway."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for ip in var.postgres_allowed_ips : can(cidrhost(ip, 0))])
    error_message = "Each entry must be a CIDR, e.g. 203.0.113.7/32."
  }
}

variable "postgres_ui_admin_email" {
  description = "pgAdmin's login at https://jithendar.com/postgres/ (postgres.tf); its password is generated, Secret postgres-db/postgres-ui-admin."
  type        = string
  default     = "admin@jithendar.com"
}

variable "postgres_databases" {
  description = "Applications on the shared PostgreSQL cluster (postgres.tf): database and owning login role named by the key, connection Secret postgres-db-credentials written into namespace, extensions the operator installs in that database. Keys are PostgreSQL identifiers."
  type = map(object({
    namespace        = string
    connection_limit = optional(number, 50)
    # Installed by the operator (superuser): tenant roles cannot create untrusted extensions such as vector (pgvector).
    # Each must ship in the image (ghcr.io/cloudnative-pg/postgresql:18 has vector). Removing a name leaves it installed.
    extensions = optional(list(string), [])
  }))
  default = {}
  validation {
    condition     = alltrue([for name in keys(var.postgres_databases) : can(regex("^[a-z][a-z0-9_]{0,47}$", name))])
    error_message = "Database names: lower case letters, digits and _, starting with a letter, at most 48 characters."
  }
  validation {
    # Names CloudNativePG itself uses: the bootstrap owner, the superuser, replication and PgBouncer roles.
    condition     = length(setintersection(keys(var.postgres_databases), ["app", "postgres", "streaming_replica", "cnpg_pooler_pgbouncer", "template0", "template1"])) == 0
    error_message = "app, postgres, streaming_replica, cnpg_pooler_pgbouncer, template0 and template1 are reserved."
  }
}

variable "redis_tenants" {
  description = "Applications on the shared Valkey (redis.tf): ACL user named by the key, limited to its database numbers, connection Secret redis-<key>-credentials written into namespace."
  type = map(object({
    namespace = string
    # Database numbers (0-31) this application may SELECT; the first is the uri's default. No two tenants share one.
    databases = list(number)
  }))
  default = {}
  validation {
    condition     = alltrue([for name in keys(var.redis_tenants) : can(regex("^[a-z][a-z0-9-]{0,40}$", name)) && !contains(["default", "console", "argocd"], name)])
    error_message = "Tenant names: lower case letters, digits and -, starting with a letter, at most 41 characters; \"default\" (admin), \"console\" (RedisInsight) and \"argocd\" (argocd.tf) are reserved."
  }
  validation {
    condition     = alltrue([for t in values(var.redis_tenants) : length(t.databases) > 0 && alltrue([for d in t.databases : d >= 0 && d <= 31 && floor(d) == d])])
    error_message = "Each tenant needs at least one database number, each an integer from 0 to 31 (databases 32 in deploy/minikube/redis/values.yaml)."
  }
  validation {
    condition     = length(flatten([for t in values(var.redis_tenants) : t.databases])) == length(distinct(flatten([for t in values(var.redis_tenants) : t.databases])))
    error_message = "A database number belongs to one tenant only."
  }
  validation {
    condition     = length(setintersection(flatten([for t in values(var.redis_tenants) : t.databases]), local.argocd_redis.databases)) == 0
    error_message = "Database 7 is Argo CD's (argocd.tf, local.argocd_redis)."
  }
}

variable "redis_allowed_ips" {
  description = "Client addresses (CIDRs) allowed through https://jithendar.com/redis/ and redis.jithendar.com:443 (redis.tf). Everything else is refused on the gateway."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for ip in var.redis_allowed_ips : can(cidrhost(ip, 0))])
    error_message = "Each entry must be a CIDR, e.g. 203.0.113.7/32."
  }
}

variable "dockerhub_username" {
  description = "Docker Hub user for Harbor's private arm64 images (harbor.tf, Secret harbor/dockerhub-pull). CI: repository secret DOCKER_USERNAME; locally: export TF_VAR_dockerhub_username."
  type        = string
  default     = ""
}

variable "dockerhub_password" {
  description = "Docker Hub access token (read-only is enough) for that user. CI: repository secret DOCKER_PASSWORD; locally: export TF_VAR_dockerhub_password. Never in a tfvars file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "postgres_backups" {
  description = "Base backups and WAL archive of postgres-cluster to a private Cloudflare R2 bucket (postgres.tf). null = no backups. The keys are not here: scripts/postgres/backup-secret.sh puts them in Secret postgres-db/postgres-backup-r2, which must exist first."
  type = object({
    account_id = string                  # Cloudflare account ID (the R2 endpoint is https://<account_id>.r2.cloudflarestorage.com)
    bucket     = string                  # a bucket used only for these backups
    retention  = optional(string, "14d") # how far back a point-in-time restore can go
  })
  default = null
  validation {
    condition     = var.postgres_backups == null || can(regex("^[0-9a-f]{32}$", var.postgres_backups.account_id))
    error_message = "account_id is the 32-character hex Cloudflare account ID."
  }
}

variable "cloudflare_proxied" {
  description = "true once DNS records jithendar.com and www are proxied by Cloudflare (orange cloud). The edge then takes the visitor address from CF-Connecting-IP (only from Cloudflare's ranges), and the /postgres and /redis IP allowlists are replaced by Cloudflare Access (they would only ever see Cloudflare's addresses). registry., jfrog., postgres. and redis. must stay DNS-only."
  type        = bool
  default     = false
}

variable "cloudflare_access" {
  description = "Cloudflare Access in front of the admin tools on jithendar.com (istio/edge values cloudflare.access). The gateway refuses those paths without a valid Access token, so nobody can skip Access by connecting to the server's address directly. null = not enforced. Requires cloudflare_proxied."
  type = object({
    team_domain = string       # e.g. jithendar.cloudflareaccess.com (Zero Trust > Settings > Custom pages > Team domain)
    audiences   = list(string) # each Access application's Application Audience (AUD) tag
  })
  default = null
  validation {
    condition     = var.cloudflare_access == null || (can(regex("^[a-z0-9-]+\\.cloudflareaccess\\.com$", var.cloudflare_access.team_domain)) && length(var.cloudflare_access.audiences) > 0)
    error_message = "team_domain is <team>.cloudflareaccess.com and audiences lists at least one AUD tag."
  }
}

variable "grafana_public" {
  description = "Read-only Grafana for everyone (grafana.tf, docs/grafana-public.md). Anonymous visitors become Viewers of the Grafana org \"Public\": Prometheus and Loki (not Jaeger), and the dashboards in mrjithendar/monitoring's dashboards/public/. The gateway serves /grafana only to Cloudflare, whose WAF rule asks each visitor to prove they are human, and /grafana leaves Cloudflare Access. null = Grafana needs a login, as before. Requires cloudflare_proxied. Create the org in Grafana first: provisioning into an org that does not exist stops Grafana from starting."
  type = object({
    org_id = number # the orgId Grafana returned when the org "Public" was created (never 1, the main org)
  })
  default = null
  validation {
    condition     = var.grafana_public == null || try(var.grafana_public.org_id >= 2 && floor(var.grafana_public.org_id) == var.grafana_public.org_id, false)
    error_message = "org_id is the whole-number id of the org \"Public\": 2 or more (1 is the main org, which has Loki and Jaeger)."
  }
}

variable "github_runners_config_url" {
  description = "Where the runner scale set registers (runners.tf): https://github.com/<organization> for every repository of an organization, or https://github.com/<owner>/<repository> for one repository."
  type        = string
  validation {
    condition     = can(regex("^https://github\\.com/[A-Za-z0-9-]+(/[A-Za-z0-9._-]+)?$", var.github_runners_config_url))
    error_message = "github_runners_config_url is https://github.com/<organization> or https://github.com/<owner>/<repository>."
  }
}

variable "github_runners_app_id" {
  description = "App ID (or Client ID) of the GitHub App the runner controller signs in as (runners.tf). CI: secret RUNNERS_GITHUB_APP_ID of environment mk4; locally: export TF_VAR_github_runners_app_id."
  type        = string
  default     = ""
}

variable "github_runners_app_installation_id" {
  description = "That app's installation ID on the organization. CI: secret RUNNERS_GITHUB_APP_INSTALLATION_ID of environment mk4; locally: export TF_VAR_github_runners_app_installation_id."
  type        = string
  default     = ""
}

variable "github_runners_app_private_key" {
  description = "That app's private key (PEM). CI: secret RUNNERS_GITHUB_APP_PRIVATE_KEY of environment mk4; locally: export TF_VAR_github_runners_app_private_key=\"$(cat <file>.pem)\". Never in a tfvars file."
  type        = string
  default     = ""
  sensitive   = true
}
