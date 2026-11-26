# KEDA

[KEDA](https://keda.sh) (Kubernetes Event-driven Autoscaling) **2.21.1** scales workloads on events and metrics: a
Prometheus query, a queue's length, a cron window, CPU or memory, and [many more](https://keda.sh/docs/2.21/scalers/).
It can scale to zero and back. Installed by
[`minikube-infrastructure/keda.tf`](../../../minikube-infrastructure/keda.tf) as release `keda` (chart
`kedacore/keda` 2.21.1) in namespace `keda`. Values: [`values.yaml`](values.yaml).

| Deployment | Does | Sidecar |
|---|---|---|
| `keda-operator` | Reconciles ScaledObjects and ScaledJobs, runs the scalers, creates one HPA per ScaledObject | yes |
| `keda-operator-metrics-apiserver` | Serves `external.metrics.k8s.io` (APIService `v1beta1.external.metrics.k8s.io`) to those HPAs | no |
| `keda-admission-webhooks` | Validates KEDA's resources (refuses, for example, a second autoscaler for one workload) | no |

The chart also installs and upgrades KEDA's CRDs: `ScaledObject`, `ScaledJob`, `TriggerAuthentication`,
`ClusterTriggerAuthentication`, `CloudEventSource`, `ClusterCloudEventSource`. Metrics Server
(`deploy/minikube/metrics-server`) keeps `metrics.k8s.io`, which KEDA's `cpu` and `memory` scalers read; the two
APIs do not overlap.

## The mesh

Namespace `keda` is in the mesh (`istio-injection=enabled`), but only the operator has a sidecar:

- **Operator: meshed.** Its scalers call Services on mk4, and meshed ones refuse plain text (STRICT mTLS, `istio/mesh`).
  With the sidecar it calls them as `keda/keda-operator`. Namespace `keda` is listed as a caller of `monitoring`
  (`istio/mesh/values.yaml`, `authorization`), so its Prometheus queries keep working once that policy is enforced.
- **Metrics API server and webhooks: no sidecar** (pod label `sidecar.istio.io/inject: "false"`). The Kubernetes API
  server calls them directly for every HPA read and every KEDA object change, as it does cert-manager's webhook.
- **Port 9666 PERMISSIVE.** The metrics API server reads each metric from the operator over gRPC (KEDA's own TLS) on
  that port. PeerAuthentication `keda/keda-operator` (from `extraObjects` in `values.yaml`) makes only that port
  PERMISSIVE.

A scaler that reaches a meshed namespace with an enforced AuthorizationPolicy (Valkey in `redis`, bge-m3 in
`embeddings`) also needs `keda` admitted there, and a namespace with a NetworkPolicy must allow ingress from `keda`.

## Scaling a workload

A ScaledObject lives in the workload's namespace. KEDA creates the HPA (`keda-hpa-<name>`) itself: delete any HPA you
made for that workload first; the webhook refuses a ScaledObject for a workload another HPA already scales.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-app
  namespace: my-namespace
spec:
  scaleTargetRef:
    name: my-app                 # a Deployment in the same namespace
  minReplicaCount: 1             # 0 allows scaling to zero
  maxReplicaCount: 3
  triggers:
    - type: prometheus
      metadata:
        # Prometheus's route prefix is /prometheus (observability/prometheus).
        serverAddress: http://prometheus.monitoring:9090/prometheus
        query: sum(rate(istio_requests_total{destination_workload="my-app",destination_workload_namespace="my-namespace"}[2m]))
        threshold: "10"          # target value per replica
```

The numbers above are placeholders: choose your own for each workload. Credentials for a scaler go in a
TriggerAuthentication (from a Secret in the same namespace), never in the ScaledObject.

## Checking it

```sh
kubectl -n keda get pods                                    # three pods Running; keda-operator 2/2 (sidecar)
kubectl get apiservice v1beta1.external.metrics.k8s.io      # Available True
kubectl get scaledobjects,scaledjobs -A                     # READY and ACTIVE per object
kubectl -n <ns> describe scaledobject <name>                # conditions and events
kubectl -n <ns> get hpa keda-hpa-<name>                     # the HPA KEDA made
kubectl -n keda logs deploy/keda-operator -c keda-operator --tail=100
```

`READY False` with a scaler error in the operator's log usually means the scaler cannot reach its source: check the
mesh and NetworkPolicy notes above. `kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1"` lists the metrics API.

## Resources and replicas

The chart's defaults: one replica of each Deployment; each container requests 100m CPU and 100Mi memory, with limits
of 1 CPU and 1000Mi. Set `operator.replicaCount`, `metricsServer.replicaCount`, `webhooks.replicaCount` and
`resources.*` in `values.yaml` to change them. Before adding replicas, read KEDA's
[high-availability notes](https://keda.sh/docs/2.21/operate/cluster/#high-availability): only one operator is active
at a time (the others stand by), and the API server balances across metrics API server replicas only with
`--enable-aggregator-routing=true` on the API server.

## Upgrading

Change `version` in `keda.tf`, in `values.yaml`'s header and in this README, and the pinned version in
`minikube-infrastructure/tests/releases.tftest.hcl`. Read the [KEDA release notes](https://github.com/kedacore/keda/releases)
first: scalers and CRD fields are deprecated and removed between minors. Dependabot does not read `helm_release` blocks.

## Removing it

Delete every ScaledObject and ScaledJob first, so KEDA removes its HPAs and leaves the workloads at their current
replica count; then remove `keda.tf` and this folder. `helm uninstall` deletes the CRDs with the chart, and with them
any ScaledObject still left.
