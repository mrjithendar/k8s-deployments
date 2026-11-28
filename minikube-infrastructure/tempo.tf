# Grafana Tempo (single binary) in place of Jaeger, only while var.tempo is set: every span the OpenTelemetry Collector
# accepts is written to the private R2 bucket var.tempo.bucket and kept for var.tempo.retention. Setting var.tempo
# installs Tempo, points the collector (otel-collector.tf) and Grafana (grafana.tf, data source uid "tempo") at it and
# uninstalls Jaeger (jaeger.tf), in one apply. Values: deploy/minikube/observability/tempo/values.yaml; setup, checks,
# cost and going back: deploy/minikube/observability/tempo/README.md.
#
# The Secret holds the R2 keys (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) and is made by scripts/tempo/r2-secret.sh, not
# here, so they are not in a tfvars file or CI variable. The data source only checks that it is there before Tempo is
# installed (like postgres.tf's backup Secret, what it reads lands in the encrypted state).
locals {
  tempo_namespace = "observability"
  # Where the collector sends spans: OTLP/HTTP of whichever store is installed.
  traces_otlp_endpoint = var.tempo == null ? "http://jaeger:4318" : "http://tempo:4318"
}

data "kubernetes_secret_v1" "tempo_r2" {
  count = var.tempo == null ? 0 : 1
  metadata {
    name      = "tempo-r2"
    namespace = local.tempo_namespace
  }
  lifecycle {
    postcondition {
      # The provider returns an empty Secret, not an error, when it does not exist.
      condition     = length(setsubtract(["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"], nonsensitive(keys(coalesce(self.data, {}))))) == 0
      error_message = "Secret observability/tempo-r2 (keys AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) is missing: run scripts/tempo/r2-secret.sh before setting var.tempo."
    }
  }
}

resource "helm_release" "tempo" {
  name             = "tempo"
  count            = var.tempo == null ? 0 : 1
  namespace        = local.tempo_namespace
  create_namespace = true
  repository       = "https://grafana-community.github.io/helm-charts"
  chart            = "tempo"
  version          = "3.2.1"
  values = [
    file("${local.minikube}/observability/tempo/values.yaml"),
    yamlencode({
      tempo = {
        # Rendered into the backend worker's and scheduler's block_retention.
        retention = var.tempo.retention
        storage = { trace = { s3 = {
          bucket   = var.tempo.bucket
          endpoint = "${var.tempo.account_id}.r2.cloudflarestorage.com"
        } } }
      }
    }),
  ]

  wait    = true
  timeout = var.helm_timeout

  # The pod starts only with the Secret; checked first so a missing one fails the plan, not a 10-minute Helm wait.
  depends_on = [data.kubernetes_secret_v1.tempo_r2]
}
