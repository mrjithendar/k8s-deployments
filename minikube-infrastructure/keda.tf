# KEDA: event-driven autoscaling. A ScaledObject scales a Deployment or StatefulSet on events and metrics (a
# Prometheus query, a queue's length, a cron window, ...), down to zero and back; KEDA creates and feeds the HPA for it
# through the external metrics API. A ScaledJob starts Jobs the same way. Values: deploy/minikube/keda/values.yaml;
# README.md there.
#   keda-operator                    reconciles ScaledObjects and ScaledJobs, runs the scalers (meshed)
#   keda-operator-metrics-apiserver  serves external.metrics.k8s.io to the HPAs (no sidecar)
#   keda-admission-webhooks          validates ScaledObjects, ScaledJobs, TriggerAuthentications, ... (no sidecar)

# In the mesh, for the operator's calls to meshed Services; the API server's two callees opt out (values.yaml).
# Pod Security as for redis: baseline enforced, restricted warned. KEDA's own containers already meet restricted.
resource "kubernetes_namespace_v1" "keda" {
  metadata {
    name = "keda"
    labels = {
      "app.kubernetes.io/part-of"          = "keda"
      "istio-injection"                    = "enabled"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
  # The operator's sidecar is injected by istiod; the release's PeerAuthentication is an Istio CRD.
  depends_on = [helm_release.istiod]
}

# The chart installs and upgrades KEDA's CRDs (ScaledObject, ScaledJob, TriggerAuthentication, ...) as templates.
resource "helm_release" "keda" {
  name       = "keda"
  namespace  = kubernetes_namespace_v1.keda.metadata[0].name
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = "2.21.1"
  values     = [file("${local.minikube}/keda/values.yaml")]

  wait    = true
  timeout = var.helm_timeout
}
