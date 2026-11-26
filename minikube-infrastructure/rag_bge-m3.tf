# Text embeddings for mk4: BAAI bge-m3 (1024 dimensions) served by Ollama on CPU, cluster-internal only, at
# http://bge-m3.embeddings:11434 (Ollama's /api/embed and the OpenAI-compatible /v1/embeddings). Callers: seo-agent
# (jithendar) and moks (moks-sre). Local chart deploy/minikube/embeddings/bge-m3; README.md there.
#
# Not TEI: Hugging Face's text-embeddings-inference publishes CPU images for amd64 only, and mk4's nodes are arm64.

resource "helm_release" "bge_m3" {
  name      = "bge-m3"
  namespace = kubernetes_namespace_v1.rag.metadata[0].name
  chart     = "${local.minikube}/embeddings/bge-m3"
  values    = [local.chart_checksum["embeddings/bge-m3"]]

  wait = true
  # The first start pulls a 2.9 GB image, attaches a new Hetzner volume and downloads 1.16 GB of weights.
  timeout = max(var.helm_timeout, 1200)
}
