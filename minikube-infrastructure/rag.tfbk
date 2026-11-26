# In the mesh: STRICT mTLS (istio-mesh's default PeerAuthentication) and the chart's enforced AuthorizationPolicy.
resource "kubernetes_namespace_v1" "rag" {
  metadata {
    name = "rag"
    labels = {
      "app.kubernetes.io/part-of" = "rag"
      "istio-injection"           = "enabled"
    }
  }
  depends_on = [helm_release.istiod]
}