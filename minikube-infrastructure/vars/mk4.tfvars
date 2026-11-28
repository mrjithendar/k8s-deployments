# terraform -chdir=minikube-infrastructure apply -var-file=vars/mk4.tfvars
kube_context = "mk4"

# Who may reach /postgres and postgres.jithendar.com (same addresses as jithendar.com's /db allowlist,
# jithendar.com minikube/db-access-10-allowlist.yaml): the owner's Mac (home IP, still current on 2026-11-10). The
# Minikube host (46.224.38.14) is gone; that address now belongs to a k3s worker, so it is no longer listed.
postgres_allowed_ips = ["122.177.247.138/32"]

# Who may reach /redis and redis.jithendar.com (redis.tf): the same address.
redis_allowed_ips = ["122.177.247.138/32"]

# Cloudflare in front of jithendar.com and www (docs/cloudflare-access-and-db-backups.md, section 2, step 7). Both DNS
# records are proxied (orange cloud); registry., postgres. and redis. are DNS-only (checked 2026-11-20). The gateway takes
# the visitor's address from CF-Connecting-IP, and only from Cloudflare's ranges: the applications' rate limits, logs and
# Turnstile see the visitor again instead of a Cloudflare edge.
cloudflare_proxied = true

# Step 8, once the Zero Trust application for the admin tools exists (steps 2-5): the gateway then requires its Access
# token on /argocd, /kiali, /grafana, /prometheus, /loki, /postgres, /redis, /qdrant, /docling, /llm, /ui and /v1, and the
# /postgres and /redis IP allowlists switch off. Until then /postgres and /redis answer 403 through Cloudflare (their allowlists only
# ever see Cloudflare's addresses); postgres.jithendar.com and redis.jithendar.com keep their own allowlists either way.
# cloudflare_access = {
#   team_domain = "<team>.cloudflareaccess.com"
#   audiences   = ["<Application Audience (AUD) tag>"]
# }

# Read-only Grafana for everyone behind Cloudflare's human check (docs/grafana-public.md). Uncomment only after steps 1-3
# there: the Cloudflare WAF rule exists, and the Grafana org "Public" exists (put the orgId it returned here). Grafana
# does not start if the org is missing. /grafana then leaves the Access list above.
grafana_public = {
  org_id = 2
}

# Traces in Cloudflare R2 with Grafana Tempo instead of Jaeger's memory (tempo.tf). Uncomment only after steps 1-3 of
# deploy/minikube/observability/tempo/README.md: the bucket, its token, and Secret observability/tempo-r2
# (scripts/tempo/r2-secret.sh); without the Secret the plan stops. Retention: how long a trace is kept, in h/m/s
# (Tempo has no "keep forever"); the owner picks it.
# tempo = {
#   account_id = "<32-hex Cloudflare account ID>"
#   bucket     = "<bucket name>"
#   retention  = "<e.g. 2160h>"
# }

# Applications on the shared cluster (postgres.tf). Each gets database + owner role <key> and Secret
# <namespace>/postgres-db-credentials. Listed ahead of moving them off their own PostgreSQL pods (README.md, PostgreSQL,
# "Moving an application"); until an application switches, its database here stays empty.
postgres_databases = {
  jithendar = { namespace = "jithendar" }                         # jithendar.com site; today jithendar/jithendar-postgres-0 (PG 18)
  moks      = { namespace = "moks-sre", extensions = ["vector"] } # MOKS portal; pgvector for its knowledge search (rag.backend postgres)
  shipping  = { namespace = "roboshop-ai" }                       # RoboShop shipping; today roboshop-ai/shipping-db (PG 18)
  litellm   = { namespace = "rag" }                               # moks-rag LiteLLM: models, credentials, virtual keys (Admin UI /llm)
}

# Applications on the shared Valkey (redis.tf). Each gets ACL user <key>, limited to its database numbers, and Secret
# <namespace>/redis-<key>-credentials, which the application reads (no application runs its own Redis any more).
# Argo CD is a built-in tenant (argocd.tf: user argocd, database 7); "argocd" and database 7 are reserved here.
redis_tenants = {
  practice = { namespace = "jithendar", databases = [1] }   # practice executor queue (EXECUTOR_REDIS_URL)
  roboshop = { namespace = "roboshop-ai", databases = [6] } # cart and shipping cache
  litellm  = { namespace = "rag", databases = [8] }         # moks-rag LiteLLM: rate limits, spend counters, cross-pod model sync (REDIS_URL)
}

# GitHub Actions runners (runners.tf): one scale set for every repository of the organization mrjithendar
# (runs-on: mk4). The GitHub App's credentials come from secrets of environment mk4, not from this file.
github_runners_config_url = "https://github.com/mrjithendar"
