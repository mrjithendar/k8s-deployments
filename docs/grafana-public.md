# Read-only Grafana for everyone

With `grafana_public` set in `minikube-infrastructure/vars/mk4.tfvars`, anyone can open https://jithendar.com/grafana/
and read dashboards without a login, after Cloudflare's "verify you are human" check. The owner still signs in
(**Sign in**, top right) and sees everything as before.

## How it works

| Part | Where | What it does |
|---|---|---|
| Human check | Cloudflare dashboard: a WAF custom rule (not in Terraform) | Managed Challenge on every `/grafana` request. A visitor who passes gets a `cf_clearance` cookie, valid for the zone's Challenge Passage time. |
| Cloudflare only | `deploy/minikube/istio/edge`, values `cloudflare.public`, AuthorizationPolicy `istio-ingress/cloudflare-public` | The gateway refuses `/grafana` (403) unless the connection comes from Cloudflare's ranges. Without this, anyone could skip the check by connecting to the server's address directly. `/grafana` also leaves the Cloudflare Access check (`cloudflare.access.prefixes`). |
| Anonymous org | `minikube-infrastructure/grafana.tf`; dashboards from [mrjithendar/monitoring](https://github.com/mrjithendar/monitoring) `dashboards/public/` | Anonymous visitors are Viewers of the Grafana org `Public`: Prometheus and Loki, the landing page `live-infrastructure` and the Platform and MOKS folders. Jaeger and the Jithendar.com dashboards (monitoring's `dashboards/private/`) stay in the main org. |

### What anonymous visitors can do

- **Can:** open the public dashboards, change their time range and variables. Through Grafana's API they can also run
  **any query against Prometheus and Loki**, not only the dashboards' own: Grafana OSS has no per-dashboard query
  limit. Prometheus held infrastructure data only on 2026-11-24 (pod and replica addresses inside the cluster, node and
  service names, page route templates). **Loki holds every namespace's logs, jithendar.com's included, with visitor
  addresses**: keeping the Jithendar.com dashboards private hides those dashboards, not those logs (the owner's
  choice, 2026-11-24).
- **Cannot:** see Jaeger traces, see the main org's dashboards (Jithendar.com), edit anything, use Explore (Viewers do
  not get it), or sign up.
- **Unchanged:** the admin login at `/grafana/login` is reachable by anyone, as it is today: password only, with
  Grafana's lockout after repeated failures. MOKS reads Grafana inside the cluster (`grafana.monitoring.svc`), never
  through Cloudflare, so the check does not affect it.
- **Limits of the check:** it stops bots, not people. Someone who passes once can script queries with their cookie
  until Challenge Passage runs out. When a viewer's clearance runs out, the dashboards' background refreshes fail
  (Cloudflare challenges cannot be solved inside an API call) until the page is reloaded.

Caching: Grafana answers `Cache-Control: no-store`, and Cloudflare passes it through (`cf-cache-status: BYPASS` on
`/grafana/`, `/grafana/login` and `/grafana/api/*`, checked 2026-11-24). No cache rule is needed. A signed-in page
can therefore never be served to an anonymous visitor.

## Turning it on

Order matters: Grafana is never open without the check, and never restarts into an org that does not exist.

1. **Merge the pull request.** Nothing changes yet: `grafana_public` is unset (null).
2. **Cloudflare: the human check.** In the Cloudflare dashboard, zone `jithendar.com`, go to **Security rules → Create
   rule → Custom rules**.
   - Rule name: `Grafana human check`.
   - **Edit expression**:
     `(http.host in {"jithendar.com" "www.jithendar.com"} and starts_with(http.request.uri.path, "/grafana"))`.
     In the builder, that is Hostname *is in* both names **and** URI Path *starts with* `/grafana`.
   - Action: **Managed Challenge**. **Deploy**.
   - **Challenge Passage** (a zone-wide setting under Security → Settings) is how long a passed check lasts. It also
     applies to every other challenge on the zone. The time is your choice.
3. **Create the Grafana org `Public`** (once). Use exactly that name, because anonymous visitors go to the org of that
   name:

   ```bash
   kubectl -n monitoring port-forward svc/grafana 3000:80 &
   U=$(kubectl -n monitoring get secret monitoring-auth -o jsonpath='{.data.username}' | base64 -d)
   P=$(kubectl -n monitoring get secret monitoring-auth -o jsonpath='{.data.password}' | base64 -d)
   curl -s -u "$U:$P" -H 'Content-Type: application/json' -d '{"name":"Public"}' \
     http://localhost:3000/grafana/api/orgs
   # {"message":"Organization created","orgId":2}
   ```

   Or in Grafana: **Administration → General → Organizations → New org**. The id is the number at the end of the org's
   page URL (`/grafana/admin/orgs/edit/<id>`).
4. **Terraform.** In `vars/mk4.tfvars`, uncomment `grafana_public` and put in the `orgId` from step 3:
   `grafana_public = { org_id = 2 }`. Merge it, and CI applies it; or apply from a workstation:
   `terraform -chdir=minikube-infrastructure apply -var-file=vars/mk4.tfvars`. Grafana restarts once.
5. **Check:**
   - Open https://jithendar.com/grafana/ in a private window. You should see the Cloudflare check, then Grafana's home
     with **Sign in** at the top right and the four folders holding only the public dashboards.
   - `curl -sI https://jithendar.com/grafana/api/health | grep -i -E '^HTTP|cf-mitigated'`. You should get `403` and
     `cf-mitigated: challenge`, because curl cannot pass the check.
   - Around Cloudflare, straight to the load balancer (46.224.66.128 on 2026-11-20):
     `curl -s -o /dev/null -w '%{http_code}\n' --resolve jithendar.com:443:46.224.66.128 https://jithendar.com/grafana/api/health`.
     You should get `403`. The same command for `/` still answers 200.
   - Signed in as admin, use **Switch organization** to go to `Public`. **Connections → Data sources** should list only
     Prometheus.

The CI check after an apply (`create-mk-infrastructure.yml`) accepts 403 for `/grafana/api/health`, so the challenge
does not fail it.

## Later: Cloudflare Access

When the Access application for the admin tools is created (`cloudflare-access-and-db-backups.md`, section 2, step 3),
leave `jithendar.com/grafana` out of its destinations while `grafana_public` is set. The gateway already leaves
`/grafana` out of its Access check.

## Changing what is public

In [mrjithendar/monitoring](https://github.com/mrjithendar/monitoring): a dashboard under `dashboards/public/` is
public, one under `dashboards/private/` is not. Its checks refuse a public dashboard that reads Jaeger or links to a
private one. Merging deploys (its `deploy.yml`).

## Turning it off

1. Comment out `grafana_public` in `vars/mk4.tfvars` and apply. Grafana needs a login again, and `/grafana` returns to
   the Access list. The org `Public` stays, empty of visitors; delete it in Grafana if you like.
2. Then delete or disable the Cloudflare rule `Grafana human check`.
