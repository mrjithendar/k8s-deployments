# OpenTelemetry Collector (OTLP in, traces to Jaeger, or to Tempo while var.tempo is set), plus the ExternalName Service
# roboshop-ai/otel-collector. Local chart deploy/minikube/observability/otel-collector.
resource "helm_release" "otel_collector" {
  name             = "otel-collector"
  namespace        = "observability"
  create_namespace = true
  chart            = "${local.minikube}/observability/otel-collector"
  values = [
    local.chart_checksum["observability/otel-collector"],
    yamlencode({ tracesEndpoint = local.traces_otlp_endpoint }),
  ]

  # The live objects were applied by the retired Argo CD Application (Kustomize), without a Helm release.
  take_ownership = true
  wait           = true
  timeout        = var.helm_timeout

  # The store it sends to is up first. When var.tempo is set, Tempo is installed, then the collector switches, then
  # Jaeger is uninstalled (a dependency is destroyed only after the resources that depend on it have changed).
  depends_on = [helm_release.jaeger, helm_release.tempo]
}
