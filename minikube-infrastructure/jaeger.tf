# Jaeger 2.x, in-memory storage, cluster-internal only (Grafana's Jaeger data source; UI by port-forward).
# Local chart deploy/minikube/observability/jaeger. Only while var.tempo is null: setting it replaces Jaeger with Tempo
# (tempo.tf), and the apply that installs Tempo uninstalls this release.
resource "helm_release" "jaeger" {
  name             = "jaeger"
  count            = var.tempo == null ? 1 : 0
  namespace        = "observability"
  create_namespace = true
  chart            = "${local.minikube}/observability/jaeger"
  values           = [local.chart_checksum["observability/jaeger"]]

  # The live objects were applied by the retired Argo CD Application (Kustomize), without a Helm release.
  take_ownership = true
  wait           = true
  timeout        = var.helm_timeout
}

# The release existed before it had a count; keep its state instead of planning a reinstall.
moved {
  from = helm_release.jaeger
  to   = helm_release.jaeger[0]
}
