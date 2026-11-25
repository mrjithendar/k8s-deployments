# Grafana at https://jithendar.com/grafana (admin login from Secret monitoring/monitoring-auth).
# Values: deploy/minikube/observability/grafana/values.yaml.
#
# Dashboards come from mrjithendar/monitoring: its deploy workflow applies one ConfigMap per dashboard to namespace
# grafana-dashboards, as ServiceAccount github-dashboards-deployer (below), and Grafana's dashboard sidecar loads them.
# dashboards/public/ goes to the org "Public" while var.grafana_public is set, dashboards/private/ to the main org.

locals {
  grafana_values               = yamldecode(file("${local.minikube}/observability/grafana/values.yaml"))
  grafana_main_datasources     = local.grafana_values.datasources["datasources.yaml"].datasources
  grafana_providers            = local.grafana_values.dashboardProviders["dashboardproviders.yaml"].providers
  grafana_dashboards_namespace = local.grafana_values.sidecar.dashboards.searchNamespace

  # Read-only Grafana for everyone (var.grafana_public, docs/grafana-public.md). Anonymous visitors are Viewers of the
  # org "Public", which gets Prometheus and Loki with the main org's definitions (uids included, so the dashboards
  # work unchanged) and the "public" dashboard provider. Jaeger stays in the main org: only the private Jithendar.com
  # dashboards read traces, so Loki's derived fields (links into Jaeger) are dropped too. A Viewer can send any query
  # to every data source of its org; Loki holds every namespace's logs, visitor addresses included.
  grafana_public_org_name = "Public"
  grafana_public_org_id   = try(var.grafana_public.org_id, 1)
  grafana_public_datasources = concat(
    [for ds in local.grafana_main_datasources : merge(ds, { orgId = local.grafana_public_org_id }) if ds.type == "prometheus"],
    [for ds in local.grafana_main_datasources : merge(ds, {
      orgId    = local.grafana_public_org_id
      jsonData = merge(ds.jsonData, { derivedFields = [] })
    }) if ds.type == "loki"],
  )
  grafana_public_values = var.grafana_public == null ? [] : [yamlencode({
    "grafana.ini" = { "auth.anonymous" = {
      enabled      = true
      org_name     = local.grafana_public_org_name
      org_role     = "Viewer"
      hide_version = true
    } }
    # Its own file name: the chart keeps data source and provider files in one ConfigMap, keyed by name.
    datasources = { "datasources-public.yaml" = { apiVersion = 1, datasources = local.grafana_public_datasources } }
    # The same providers, "public" moved to the org "Public" (a list: Helm replaces it whole).
    dashboardProviders = { "dashboardproviders.yaml" = {
      apiVersion = 1
      providers  = [for p in local.grafana_providers : merge(p, { orgId = p.name == "public" ? local.grafana_public_org_id : p.orgId })]
    } }
    # When a visitor's pass through Cloudflare's check runs out, Grafana's API calls get the challenge (403) instead
    # of data. A Lua filter in Grafana's own sidecar adds a script to Grafana's page that reloads it then, so the
    # visitor passes the check again and keeps the URL (time range, variables): cloudflare-challenge-reload.lua.
    extraObjects = [{
      apiVersion = "networking.istio.io/v1alpha3"
      kind       = "EnvoyFilter"
      metadata   = { name = "grafana-cloudflare-challenge-reload" }
      spec = {
        workloadSelector = { labels = { "app.kubernetes.io/name" = "grafana", "app.kubernetes.io/instance" = "grafana" } }
        configPatches = [{
          applyTo = "HTTP_FILTER"
          match = {
            context = "SIDECAR_INBOUND"
            listener = {
              portNumber = local.grafana_port
              filterChain = { filter = {
                name      = "envoy.filters.network.http_connection_manager"
                subFilter = { name = "envoy.filters.http.router" }
              } }
            }
          }
          patch = {
            operation = "INSERT_BEFORE"
            value = {
              name = "grafana.cloudflare-challenge-reload"
              typed_config = {
                "@type"             = "type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua"
                default_source_code = { inline_string = file("${local.minikube}/observability/grafana/cloudflare-challenge-reload.lua") }
              }
            }
          }
        }]
      }
    }]
  })]
  # Grafana's container port (the chart's default; the Service's targetPort "grafana").
  grafana_port = 3000
}

# Nothing runs here: only the dashboards' ConfigMaps.
resource "kubernetes_namespace_v1" "grafana_dashboards" {
  metadata {
    name = local.grafana_dashboards_namespace
    labels = {
      "app.kubernetes.io/part-of"          = "monitoring"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Grafana's sidecar reads the ConfigMaps here, and nothing else in the cluster (the chart's own RBAC is off:
# grafana/values.yaml, rbac.create).
resource "kubernetes_role_v1" "grafana_dashboards_reader" {
  metadata {
    name      = "grafana-sidecar"
    namespace = kubernetes_namespace_v1.grafana_dashboards.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "grafana_dashboards_reader" {
  metadata {
    name      = "grafana-sidecar"
    namespace = kubernetes_namespace_v1.grafana_dashboards.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.grafana_dashboards_reader.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "grafana" # fullnameOverride in grafana/values.yaml
    namespace = "monitoring"
  }
}

# Identity of mrjithendar/monitoring's deploy workflow: ConfigMaps in this namespace, nothing else. Its token Secret
# is not Terraform's (it would sit in the state): monitoring's scripts/setup-ci-access.sh creates it and stores the
# token in that repository's environment "mk4".
resource "kubernetes_service_account_v1" "dashboards_deployer" {
  metadata {
    name      = "github-dashboards-deployer"
    namespace = kubernetes_namespace_v1.grafana_dashboards.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_role_v1" "dashboards_deployer" {
  metadata {
    name      = "github-dashboards-deployer"
    namespace = kubernetes_namespace_v1.grafana_dashboards.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "create", "patch", "update", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "dashboards_deployer" {
  metadata {
    name      = "github-dashboards-deployer"
    namespace = kubernetes_namespace_v1.grafana_dashboards.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.dashboards_deployer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.dashboards_deployer.metadata[0].name
    namespace = kubernetes_namespace_v1.grafana_dashboards.metadata[0].name
  }
}

resource "helm_release" "grafana" {
  name             = "grafana"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://grafana-community.github.io/helm-charts"
  chart            = "grafana"
  version          = "14.0.1"
  values           = concat([file("${local.minikube}/observability/grafana/values.yaml")], local.grafana_public_values)

  # The live objects were rendered by the retired Argo CD Application (same release name), without a Helm release.
  take_ownership = true
  wait           = true
  timeout        = var.helm_timeout

  lifecycle {
    precondition {
      # The human check is a Cloudflare WAF rule, and the gateway serves the public /grafana only to Cloudflare.
      condition     = var.grafana_public == null || var.cloudflare_proxied
      error_message = "grafana_public needs cloudflare_proxied = true: the human check in front of the public Grafana is a Cloudflare rule."
    }
    precondition {
      condition     = toset([for p in local.grafana_providers : p.name]) == toset(["public", "private"])
      error_message = "grafana/values.yaml needs the dashboard providers \"public\" and \"private\" (mrjithendar/monitoring's two orgs)."
    }
  }

  depends_on = [helm_release.prometheus, kubernetes_role_binding_v1.grafana_dashboards_reader]
}
