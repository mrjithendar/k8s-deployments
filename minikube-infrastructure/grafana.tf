# Grafana at https://jithendar.com/grafana (admin login from Secret monitoring/monitoring-auth).
# Values: deploy/minikube/observability/grafana/values.yaml.

locals {
  jithendar_dashboards_dir = abspath("${path.module}/${var.jithendar_com_dir}/grafana")
  jithendar_dashboards = {
    for name in fileset(local.jithendar_dashboards_dir, "*.json") : name => file("${local.jithendar_dashboards_dir}/${name}")
  }

  # Read-only Grafana for everyone (var.grafana_public, docs/grafana-public.md). Anonymous visitors are Viewers of the
  # org "Public", which gets the Prometheus data source (the main org's definition, uid included, so the dashboards
  # work unchanged) and the dashboards listed under `public` in the dashboards chart, one folder each. Loki and Jaeger
  # stay in the main org: a Viewer can send any query to every data source of its org, not only the dashboards' own,
  # and logs and traces carry visitor addresses.
  grafana_values          = yamldecode(file("${local.minikube}/observability/grafana/values.yaml"))
  grafana_public_folders  = yamldecode(file("${local.minikube}/observability/grafana/dashboards/values.yaml")).public.folders
  grafana_public_org_name = "Public"
  grafana_public_datasources = [
    for ds in local.grafana_values.datasources["datasources.yaml"].datasources : ds if ds.type == "prometheus"
  ]
  grafana_public_values = var.grafana_public == null ? [] : [yamlencode({
    "grafana.ini" = { "auth.anonymous" = {
      enabled      = true
      org_name     = local.grafana_public_org_name
      org_role     = "Viewer"
      hide_version = true
    } }
    # File names differ from the main org's and from each other: the chart puts both kinds in one ConfigMap.
    datasources = { "datasources-public.yaml" = {
      apiVersion  = 1
      datasources = [for ds in local.grafana_public_datasources : merge(ds, { orgId = var.grafana_public.org_id })]
    } }
    dashboardProviders = { "dashboardproviders-public.yaml" = {
      apiVersion = 1
      providers = [for key, folder in local.grafana_public_folders : {
        name                  = "public-${key}"
        orgId                 = var.grafana_public.org_id
        folder                = folder.title
        type                  = "file"
        disableDeletion       = true
        editable              = false
        allowUiUpdates        = false
        updateIntervalSeconds = 30
        options               = { path = "/var/lib/grafana/dashboards/public-${key}" }
      }]
    } }
    # ConfigMaps from the grafana-dashboards release (public.enabled below).
    dashboardsConfigMaps = { for key, _ in local.grafana_public_folders : "public-${key}" => "grafana-dashboards-public-${key}" }
  })]
}

# ConfigMaps grafana-dashboards-{roboshop,moks,platform} (deploy/minikube/observability/grafana/dashboards) and
# grafana-dashboards-jithendar (the jithendar.com checkout's grafana/ folder). Grafana mounts all four. While
# var.grafana_public is set, also grafana-dashboards-public-<folder> for the org "Public".
resource "helm_release" "grafana_dashboards" {
  name      = "grafana-dashboards"
  namespace = "monitoring"
  chart     = "${local.minikube}/observability/grafana/dashboards"
  values = [yamlencode({
    jithendar = local.jithendar_dashboards
    public    = { enabled = var.grafana_public != null }
  }), local.chart_checksum["observability/grafana/dashboards"]]

  take_ownership = true
  wait           = true
  timeout        = var.helm_timeout

  lifecycle {
    precondition {
      condition     = length(local.jithendar_dashboards) > 0
      error_message = "No dashboards in ${local.jithendar_dashboards_dir}: clone jithendar.com there or set jithendar_com_dir."
    }
  }

  depends_on = [helm_release.prometheus]
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
      condition     = length(local.grafana_public_datasources) == 1
      error_message = "The org \"Public\" gets the one Prometheus data source of grafana/values.yaml; found ${length(local.grafana_public_datasources)}."
    }
  }

  depends_on = [helm_release.grafana_dashboards]
}
