# bge-m3 embeddings

[BAAI/bge-m3](https://huggingface.co/BAAI/bge-m3) served by [Ollama](https://github.com/ollama/ollama) on CPU, for
seo-agent (Ask the Blog, crews, news desk) and moks (knowledge search). Installed by
[`minikube-infrastructure/embeddings.tf`](../../../../minikube-infrastructure/embeddings.tf) as release `bge-m3` in
namespace `embeddings`.

| | |
|---|---|
| Endpoint | `http://bge-m3.embeddings:11434`, cluster-internal only |
| Model | `bge-m3:567m` (F16, 1.16 GB), weights digest pinned in `values.yaml` |
| Output | dense vectors, 1024 dimensions, L2-normalised; no query or passage prefix |
| Input | up to 2048 tokens (`ollama.contextLength`); longer input is truncated |
| Callers | `jithendar/seo-agent` (service account `default`), `moks/*` (service account `moks`) |
| Footprint | 1.5 GiB requested, 2.5 GiB limit, no CPU limit; a 10 Gi Hetzner volume for the model |

Not TEI: text-embeddings-inference has no arm64 CPU image, and mk4's nodes are arm64. Ollama serves only the dense
vectors of bge-m3, not its sparse or multi-vector outputs; both callers do keyword search in PostgreSQL already.

## Calling it

```sh
# Ollama's API: the vectors in "embeddings"
curl -s http://bge-m3.embeddings:11434/api/embed -d '{"model": "bge-m3:567m", "input": ["first text", "second text"]}'

# OpenAI-compatible: the vectors in data[].embedding (moks's openai provider, endpoint http://bge-m3.embeddings:11434/v1)
curl -s http://bge-m3.embeddings:11434/v1/embeddings -d '{"model": "bge-m3:567m", "input": ["first text"]}'
```

A new caller needs three things: an entry in `callers` (`values.yaml`), an egress rule to namespace `embeddings`
port 11434 in its own NetworkPolicy, and a sidecar (the AuthorizationPolicy admits mTLS identities only).

## Checking it

```sh
kubectl -n embeddings logs deploy/bge-m3 -c fetch-model      # "downloaded" or "already on the volume"
kubectl -n embeddings port-forward svc/bge-m3 11434:11434 &   # port-forward reaches the pod past the mesh policy
curl -s localhost:11434/api/embed -d '{"model":"bge-m3:567m","input":["hello"]}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["embeddings"][0]))'   # 1024
```

## Monitoring

Grafana → Platform → **Embeddings (bge-m3)** (`https://jithendar.com/grafana/d/platform-embeddings`, JSON in
mrjithendar/monitoring, `dashboards/public/Platform/platform-embeddings.json`). Ollama exports no metrics of its own,
so:

- **Traffic** (requests, codes, latency per caller) comes from bge-m3's own Istio sidecar (`istio_requests_total`,
  `reporter="destination"`). Its counters live as long as the bge-m3 pod, so a request still counts after the caller
  restarts (a caller's sidecar loses its counters with its pod). Requests that never reached the pod are only on the
  caller's side, so they are added from `reporter="source"` with flags `UH`, `UF`, `UO` or `NR`. *Vectors/s* is an
  estimate: response bytes ÷ 12.8 KB, the size of one 1024-dimension vector in Ollama's JSON.
- **First requests count.** A caller's first request (or a code it has not had before) creates a counter that is
  already at 1 when Prometheus first scrapes it, and `increase()` reads that as 0. The Requests, Failed and p95 stats
  and `BgeM3RequestsFailing` add the starting value of every series that appears inside the window
  (`min_over_time(x[w]) unless x offset w`). The rate panels can't do that: one lone request shows in the stats only.
  A Prometheus gap longer than 5 min at the very start of the window makes old series look new and overcounts.
- `kubectl port-forward` reaches Ollama on the pod's loopback, past both sidecars, so test calls made that way
  (`127.0.0.1` in the ollama log; mesh calls show `127.0.0.6`) never appear on the dashboard.
- **Model in memory**, CPU, memory and network come from cAdvisor (container `ollama`); the volume from the kubelet.

Alerts (`deploy/minikube/observability/prometheus/files/alerts.yml`, group `embeddings`):

- **BgeM3NotRunning**: no `ollama` container for 10 min. `kubectl -n embeddings get pods,pvc` and
  `kubectl -n embeddings describe pod -l app=bge-m3`: a volume stuck attaching (Hetzner), `fetch-model` failing (logs
  say whether the digest no longer matches) or the pod unschedulable (1.5 GiB memory request).
- **BgeM3ModelNotLoaded**: running, but under 1 GiB resident, so the weights are not in memory. `kubectl -n
  embeddings logs deploy/bge-m3 -c ollama --tail=50`; one request through "Checking it" loads the model again
  (about 5 s).
- **BgeM3RequestsFailing**: a caller keeps getting non-2xx answers; the code says which. `403`: the caller is not in
  `callers` or has no sidecar. `503` (flags `UH`): no ready pod. `404`: the model name differs from `model.name`.
  `0` or flags `DC`: the caller gave up first, so raise its timeout (moks: `timeout_seconds` 300).
- **BgeM3MemoryNearLimit**: over 90% of the 2.5 GiB limit for 15 min. Large batches of long texts grow the compute
  buffers. Lower the caller's batch size or `ollama.contextLength`, or raise `resources.limits.memory`.

## Changing the model

Every caller's stored vectors belong to one model. A new model, a new tag or a re-pushed digest means a full reindex in
seo-agent (it builds `seo_article_chunks_next` and swaps it in) and `moks reindex` (a new index generation). Update
`model.name` and `model.digest` together: the digest is the `application/vnd.ollama.image.model` layer of
`https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`.
