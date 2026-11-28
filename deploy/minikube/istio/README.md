# Istio on mk4: the public edge

The Istio ingress gateway (`ingressgateway.yaml`, release `istio-ingressgateway`) is mk4's edge. The host's HAProxy
(`../expose-ingress.sh`) forwards 80/443 to its NodePorts 31080/31443 with a PROXY protocol v2 header. Release
`istio-edge` (`edge/`, `minikube-infrastructure/istio.tf`) holds:

| What | Where |
|---|---|
| Gateway `istio-ingress/public`: one HTTPS server for jithendar.com, www, registry., jfrog.; a TLS server for db.; port 80 redirects | `edge/templates/gateway.yaml` |
| Wildcard certificate `jithendar.com` + `*.jithendar.com` (DNS-01), Secret `jithendar-com-gateway-tls` | `edge/templates/certificate.yaml` |
| The jithendar.com routing table: www → apex, redirects, one delegation per path prefix, the site last | `edge/templates/root-virtualservice.yaml`, `edge/values.yaml` `root` |
| Logins (basic auth) for /prometheus, /loki, /redis, by path prefix | `edge/templates/basic-auth.yaml`, `basicAuth`; users from Secret `gateway-basic-auth` |
| Read-only prefixes (GET, HEAD, POST to listed search suffixes); none since MOKS's OpenSearch was retired | `edge/templates/read-only.yaml`, `readOnly` |
| Visitor address: PROXY protocol first on 80/443; X-Forwarded-For and X-Real-IP replaced by it | `edge/templates/proxy-protocol.yaml`, `forwarded-for.yaml` |
| ALPN `postgresql` for postgres.jithendar.com, compression | `edge/templates/tls-alpn.yaml`, `compression.yaml` |
| Delegates for Kiali and Grafana (their charts only render Ingresses) | `edge/templates/route-*.yaml` |

Each application owns a delegate VirtualService for its prefix (no hosts, no gateways): moks (`/moks`), roboshop-ai (`/roboshop`), jithendar.com (the site), Prometheus, Loki, Argo CD and
Vault here. Its own hostname gets its own VirtualService on `istio-ingress/public`: JFrog (jfrog.),
PostgreSQL (postgres., TCP), Redis (redis., TCP). One root avoids Istio's merge order for VirtualServices of one host: whichever was created first
would win, and the site's `/` would shadow every later prefix.

A new public prefix: add it to `edge/values.yaml` `root.delegates` (longer prefixes first) and give the application a
delegate VirtualService. A new hostname: add `<namespace>/<host>` to `gateway.https`.

## Logins

`python3 scripts/istio/gateway-basic-auth.py` reads each login's source Secret (`basicAuth[].from`, the same
`kubernetes.io/basic-auth` Secrets Traefik used) and writes `istio-ingress/gateway-basic-auth` as `{SHA}` htpasswd
lines, the only format Envoy's basic_auth accepts. Then `terraform apply`. Rerun both after changing a password. A
missing source Secret gives a locked line (today: `monitoring/loki-read-auth`), and Terraform refuses to plan without
the Secret, so a path never opens by accident. The hashes are in the Terraform state and the EnvoyFilter; the
passwords are not.

## Mesh security (`mesh/`, release `istio-mesh`)

| What | Where |
|---|---|
| STRICT mTLS for every namespace without its own PeerAuthentication (`istio-system/default`); jithendar, moks and roboshop-ai keep a STRICT one of their own, none has a plain-text port | `mesh/templates/peerauthentication.yaml` |
| `allow-known-callers` in argocd, cert-manager, monitoring, observability: only the namespace itself and the listed namespaces' identities | `mesh/values.yaml` `authorization`; the applications keep theirs in their repositories |
| The gateway's access log, JSON with Alloy's allowed fields only (no address, path or header) | `mesh/templates/telemetry.yaml`, provider `edge-access-log` in `istiod.yaml` |
| Two gateway replicas with a PDB, two istiod replicas (chart PDB), Kiali meshed by pod label | `ingressgateway.yaml`, `istiod.yaml`, `kiali.yaml` |

Every client of a meshed pod is meshed: kubelet probes go to the sidecar's :15020, Prometheus scrapes through its own
sidecar (no `includeOutboundIPRanges: ""`: that made scrapes plain text) except the sidecars' own ports 15020 and 15090,
which no sidecar captures ([Monitoring](#monitoring)), Kiali has a sidecar. Before adding a client
outside the mesh, check plain text is gone:
`sum by (destination_workload_namespace,destination_workload) (increase(istio_requests_total{reporter="destination",connection_security_policy="none"}[1h]))`
must be empty; Grafana's Platform · Istio mesh
plots it as **Plain-text requests by workload**. MOKS's session pods in moks-sre, unmeshed by label,
cannot call meshed Services.

**AuthorizationPolicies start as dry runs** (`istio.io/dry-run: "true"`): nothing is refused, Envoy counts what would
be. `python3 scripts/istio/authz-dry-run-report.py` prints the non-zero counts (exit 1); Platform · Istio mesh shows
them over time per pod (**AuthorizationPolicy: would deny / denied**). After a day at 0, enforce:
`authorization.dryRun: false` here, `mesh.authorization.dryRun: false` in moks, and delete the annotation in
jithendar.com `minikube/75-mesh.yaml` and roboshop-ai `argocd-minikube/apps/mesh/authorizationpolicy.yaml`. A new
caller across namespaces needs its namespace added to the callee's list first.

## Monitoring

Grafana → **Platform**: **Istio mesh** (requests, success rate and latency per workload, who calls whom, the public
gateway, TCP per service, mTLS and AuthorizationPolicy counts, proxy CPU and memory; filter by namespace and workload)
and **Istio control plane** (istiod: connected proxies per replica, xDS pushes and their time, rejected config and
conflicts, root certificate expiry, sidecar injection, resources). Kiali draws the same telemetry as a graph. Both read
Prometheus (`../observability/prometheus`, `templates/config.yaml`):

| Job | Scrapes | Notes |
|---|---|---|
| `istiod` | each replica's :15014, found by pod in istio-system | through Prometheus's sidecar, plain text (istiod has none) |
| `envoy-stats` | every sidecar's and gateway's :15090 | bypasses Prometheus's sidecar (`excludeOutboundPorts`), so each namespace's NetworkPolicy must admit `monitoring` on 15090: the applications' `istio-sidecars`, Kiali's `kiali-sidecar-metrics` (`minikube-infrastructure/kiali.tf`). Finished Job pods are skipped. |

`envoy-stats` keeps `istio_*` and the AuthorizationPolicy counters (`envoy_http_rbac`, `envoy_tcp`). Envoy's own
internal stats (~430 series per proxy) and the request/response size histograms are dropped: 46k series → 11k
(2026-11-19). Response and request bytes remain as `_sum` and `_count`.

Alerts, group `istio` in `../observability/prometheus/files/alerts.yml` (shown under Prometheus → Alerts):

- **IstiodDown** — no replica answers. The injection webhook fails closed, so no pod in an injected namespace can be
  created; running pods keep working, and their 24 h certificates are not renewed. `kubectl -n istio-system get pods -l
  app=istiod`, then `describe` and `logs` of the failing pod; `terraform apply` restores the release.
- **IstiodReplicaDown** — one replica down for 10 min: the other serves every proxy, and the PDB no longer protects it
  in a node drain. Same commands; check the node it was scheduled on.
- **IstioProxyNotScraped** — Prometheus → Status → Target health shows the error for that pod. `connection refused`:
  that namespace's NetworkPolicy does not admit `monitoring` on 15090 (add it, as `istio-sidecars` does). A timeout: the
  pod or its node is unhealthy.
- **IstioConfigRejected** — a proxy refused (NACK) what istiod pushed and keeps its last accepted configuration.
  `istioctl proxy-status` names it; `istioctl analyze -A` usually explains why. The last change to a VirtualService,
  DestinationRule or EnvoyFilter is the usual cause: revert it.

## Traefik (gone, 2026-11-09)

The host's HAProxy forwards to the gateway, the gateway requires the PROXY header, and Traefik's release, namespace and
routes are deleted. Left on mk4 until the next `terraform apply` of `prometheus` and `loki`: their old Traefik
Middlewares (Helm deletes them on upgrade). **Only after that apply**, delete the CRDs:
`kubectl --context mk4 get crd -o name | grep traefik.io | xargs kubectl --context mk4 delete`. Deleting them first
breaks the upgrade: Helm cannot build the previous release's Middleware objects without their CRD.
