#!/usr/bin/env bash
# Creates or updates Secret observability/tempo-r2: the R2 API token Tempo writes and reads traces with
# (deploy/minikube/observability/tempo/values.yaml, extraEnvFrom; minikube-infrastructure/tempo.tf, var.tempo).
#
# In the Cloudflare dashboard first: R2 > Create bucket (e.g. jithendar-traces, no public access, no lifecycle rule:
# Tempo deletes old blocks itself), then R2 > Manage API tokens > Create API token: "Object Read & Write", applied to
# that bucket only. Copy the Access Key ID and Secret Access Key (shown once). Then:
#
#   scripts/tempo/r2-secret.sh            # prompts for both keys (nothing is echoed or stored in history)
#
# Uses the current kubectl context unless KUBE_CONTEXT is set (KUBE_CONTEXT=mk4 scripts/tempo/r2-secret.sh).
# Afterwards set tempo in minikube-infrastructure/vars/mk4.tfvars and apply. After rotating the token, run this again
# and restart Tempo (kubectl -n observability rollout restart statefulset/tempo): it reads the keys at start-up.
set -euo pipefail

ctx=()
[[ -n "${KUBE_CONTEXT:-}" ]] && ctx=(--context "$KUBE_CONTEXT")
echo "kubectl context: ${KUBE_CONTEXT:-$(kubectl config current-context)}"

read -r -p "R2 Access Key ID: " key_id
read -r -s -p "R2 Secret Access Key: " secret_key; echo
[[ ${#key_id} -ge 20 && ${#secret_key} -ge 40 ]] || { echo "Those do not look like R2 keys (ID 32 chars, secret 64)." >&2; exit 1; }

# The namespace exists while Jaeger or the collector runs; create it if this runs first.
kubectl "${ctx[@]}" get namespace observability >/dev/null 2>&1 || kubectl "${ctx[@]}" create namespace observability

# Through the environment and stdin only: the keys never appear on a command line (ps) or in a file. The key names are
# the ones Tempo's S3 client reads from its environment.
KEY_ID="$key_id" SECRET_KEY="$secret_key" python3 -I -c '
import base64, json, os
b = lambda v: base64.b64encode(v.encode()).decode()
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {"name": "tempo-r2", "namespace": "observability",
                 "labels": {"app.kubernetes.io/part-of": "observability"}},
    "data": {"AWS_ACCESS_KEY_ID": b(os.environ["KEY_ID"]), "AWS_SECRET_ACCESS_KEY": b(os.environ["SECRET_KEY"])},
}))' | kubectl "${ctx[@]}" apply -f -
echo "Secret observability/tempo-r2 is ready. Next: tempo in vars/mk4.tfvars, then terraform apply."
