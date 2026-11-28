# Tempo: traces kept in Cloudflare R2

Grafana Tempo 3.1 (grafana-community chart `tempo` 3.2.1, one pod) replaces Jaeger as mk4's trace store while
Terraform's `tempo` variable is set. Jaeger keeps the newest 5000 traces in memory and loses them on every restart;
Tempo writes every span the OpenTelemetry Collector accepts to a private R2 bucket and keeps it for the retention you
set.

```
apps ─OTLP/HTTP─▶ otel-collector (privacy filter) ─▶ tempo:4318 ─▶ live-store (memory + WAL on its volume)
                                                                    └─ a block about every 30 s ─▶ R2 bucket
Grafana (data source Tempo, uid tempo) ─▶ tempo:3200 ─▶ recent traces from the live-store, older ones from R2
```

| Piece | Where |
|---|---|
| Release | `minikube-infrastructure/tempo.tf` (`helm_release.tempo`, only while `var.tempo` is set) |
| Values | [`values.yaml`](values.yaml); Terraform adds the bucket, the endpoint and the retention |
| R2 keys | Secret `observability/tempo-r2` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), made by `scripts/tempo/r2-secret.sh` |
| Volume | PVC `storage-tempo-0`, `local-path`: the WAL and blocks not yet in R2 (replayed after a restart) |
| Grafana | data source `Tempo` (`grafana/tempo.yaml`); Loki's `trace_id=` links open it |
| Prometheus | job `tempo` (`:3200/metrics`); alerts `TempoBlocksNotStored`, `TempoSpansDiscarded`, `TempoMemoryNearLimit` |

"Every span" means every span the collector passes on: it still strips sensitive attributes and drops successful
health, readiness and metrics requests ([`../otel-collector/collector.yaml`](../otel-collector/collector.yaml)).

## Turning it on

Merging the Terraform change does nothing on its own: with `tempo` unset, Jaeger stays.

1. **Bucket.** Cloudflare dashboard → R2 → Create bucket, e.g. `jithendar-traces`. No public access, no custom
   domain, and no lifecycle rule: Tempo deletes blocks past the retention itself, and a rule that deletes earlier
   leaves Tempo's block list pointing at objects that are gone.
2. **Token.** R2 → Manage API tokens → Create API token: permission **Object Read & Write**, applied to that bucket
   only. Copy the Access Key ID and the Secret Access Key (shown once).
3. **Secret.** `scripts/tempo/r2-secret.sh` (prompts for both keys; `KUBE_CONTEXT=mk4` to pick a context).
4. **tfvars.** In `minikube-infrastructure/vars/mk4.tfvars`:

   ```hcl
   tempo = {
     account_id = "<32-hex Cloudflare account ID>" # Account ID on the R2 overview page
     bucket     = "jithendar-traces"
     retention  = "<hours, e.g. 2160h = 90 days>"
   }
   ```

   Tempo has no "keep forever": its retention job always runs, and `0` would delete every block, so `retention` has
   no default. Hours, minutes and seconds only (`720h`, not `30d`).
5. **Apply.** Push to master (Create minikube infrastructure applies it), or by hand:
   `terraform -chdir=minikube-infrastructure apply -var-file=vars/mk4.tfvars`. In one apply Terraform installs
   Tempo, switches the collector to `http://tempo:4318`, provisions Grafana's Tempo data source (and deletes Jaeger's
   from Grafana's database), then uninstalls Jaeger. Traces Jaeger held in memory are not copied.
6. **Dashboards.** The Jithendar.com dashboards in [mrjithendar/monitoring](https://github.com/mrjithendar/monitoring)
   read the `jaeger` data source; merge their switch to `tempo` after this apply.

If the Secret is missing, the plan stops at `data.kubernetes_secret_v1.tempo_r2` with "Secret observability/tempo-r2 …
is missing" and nothing changes.

## Checks

```bash
kubectl -n observability get statefulset/tempo pvc/storage-tempo-0
kubectl -n observability logs statefulset/tempo -c tempo --tail=50 | grep -i -E 'level=(warn|error)'
```

In Prometheus (`https://jithendar.com/prometheus/`):

| Query | Healthy |
|---|---|
| `up{job="tempo"}` | 1 |
| `sum(rate(tempo_distributor_spans_received_total[5m]))` | close to `sum(rate({__name__=~"otelcol_exporter_sent_spans(_total)?", job="otel-collector"}[5m]))` |
| `sum(increase(tempo_live_store_blocks_completed_total[1h]))` | above 0 while spans arrive (blocks written to R2) |
| `sum(increase(tempo_live_store_failed_completions_total[1h]))` | 0 (`TempoBlocksNotStored`) |
| `sum by (operation, status_code) (rate(tempodb_backend_request_duration_seconds_count[5m]))` | only 2xx (and 404 for objects that are not there) |
| `sum by (reason) (increase(tempo_discarded_spans_total[1h]))` | empty (`TempoSpansDiscarded`) |

In Grafana: Explore → Tempo → TraceQL `{}` lists recent traces; paste a trace ID from a log line, or follow a Loki
line's **View trace** link. In R2 the bucket fills under `single-tenant/` (one folder per block).

## Retention and cost

The backend worker deletes blocks whose newest span is older than `retention`, checking every hour. R2 bills storage
and operations, not egress ([pricing](https://developers.cloudflare.com/r2/pricing/)). For a sense of scale: on
2026-11-28 mk4 sent about 2 spans/s on average (9/s at the busiest five minutes of the day), and Tempo writes a block
about every 30 s while spans arrive (around 3,000 small blocks a day, which its compaction merges). Look at the
bucket's size after a week to know what your retention costs.

## Rotating the token

Make a new token (step 2), run `scripts/tempo/r2-secret.sh` again, then
`kubectl -n observability rollout restart statefulset/tempo`: Tempo reads the keys only at start-up. Revoke the old
token afterwards.

## Going back to Jaeger

Set `tempo = null` (or delete the block) and apply: Jaeger comes back empty, the collector sends to it again, and
Grafana gets its Jaeger data source back. Left behind on purpose: the bucket and its traces, PVC `storage-tempo-0`
(and its folder on the node, `local-path` is Retain), Secret `tempo-r2`, and Grafana's `Tempo` data source (delete it
under Connections → Data sources).

## Limits of this setup

- One pod. While it restarts, the collector retries and then drops spans (`otelcol_exporter_send_failed_spans`);
  what Tempo had accepted is on its volume and is replayed.
- `local-path` pins the pod to the node that holds its volume, as with Loki and Prometheus.
- Tempo's per-tenant limits are its defaults (`tempo.overrides.defaults` is empty). Spans over a limit are discarded,
  and `TempoSpansDiscarded` says which limit (`reason`).
- No metrics generator (span metrics, service graph): Tempo stores and searches traces, nothing more.
- Chart and image are pinned (`tempo.tf`, `values.yaml`); Dependabot does not see remote charts in Terraform, so bump
  both by hand, together (the image tag is the chart's `appVersion`).
