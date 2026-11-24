# Mock providers only: no cluster is contacted. Run: terraform init -backend=false && terraform test
mock_provider "helm" {}
mock_provider "kubernetes" {
  # The gateway's logins (scripts/istio/gateway-basic-auth.py writes them on mk4).
  override_data {
    target = data.kubernetes_secret_v1.gateway_basic_auth
    values = {
      data = {
        "prometheus-remote-write" = "a:{SHA}AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        "prometheus"              = "a:{SHA}AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        "loki-push"               = "a:{SHA}AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        "loki-read"               = "a:{SHA}AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        "redis"                   = "a:{SHA}AAAAAAAAAAAAAAAAAAAAAAAAAAA="
      }
    }
  }
}
mock_provider "random" {}
mock_provider "time" {}

# Every run: the access charts refuse to plan without an allowlist (runs below override these to test that).
variables {
  postgres_allowed_ips = ["192.0.2.1/32"]
  redis_allowed_ips    = ["192.0.2.1/32"]
  dockerhub_username   = "ci"
  dockerhub_password   = "token"
  # The runners' GitHub App (runners.tf).
  github_runners_app_id              = "1"
  github_runners_app_installation_id = "2"
  github_runners_app_private_key     = "-----BEGIN RSA PRIVATE KEY-----"
}

run "pinned_releases" {
  command = plan

  assert {
    condition = (
      helm_release.metrics_server.version == "3.14.0" &&
      helm_release.cert_manager.version == "v1.20.4" &&
      helm_release.istio_base.version == helm_release.istiod.version &&
      helm_release.istiod.version == "1.30.7" &&
      helm_release.istio_cni.version == helm_release.istiod.version &&
      helm_release.istio_ingressgateway.version == helm_release.istiod.version &&
      helm_release.kiali.version == "2.34.0" &&
      helm_release.grafana.version == "14.0.1"
    )
    error_message = "Chart versions are pinned; istio-base, istio-cni, istiod and the ingress gateway must stay on one version."
  }

  assert {
    condition = (
      helm_release.metrics_server.namespace == "kube-system" &&
      helm_release.cert_manager.namespace == "cert-manager" &&
      helm_release.letsencrypt.namespace == "cert-manager" &&
      helm_release.istiod.namespace == "istio-system" &&
      helm_release.istio_cni.namespace == "istio-system" &&
      helm_release.istio_ingressgateway.namespace == "istio-ingress" &&
      helm_release.istio_edge.namespace == helm_release.istio_ingressgateway.namespace &&
      helm_release.istio_mesh.namespace == "istio-system" &&
      helm_release.kiali.namespace == "istio-system" &&
      helm_release.prometheus.namespace == "monitoring" &&
      helm_release.grafana.namespace == "monitoring" &&
      helm_release.loki.namespace == "monitoring" &&
      helm_release.otel_collector.namespace == "observability" &&
      helm_release.jaeger.namespace == "observability"
    )
    error_message = "Release namespaces must match the live installations."
  }

  assert {
    condition = alltrue([for r in [
      helm_release.metrics_server, helm_release.cert_manager, helm_release.prometheus, helm_release.grafana,
      helm_release.loki, helm_release.otel_collector, helm_release.jaeger,
    ] : r.take_ownership])
    error_message = "These objects were applied by Argo CD without a Helm release; the first apply must adopt them."
  }

  assert {
    condition     = random_password.kiali_signing_key.length == 32 && !random_password.kiali_signing_key.special
    error_message = "Kiali signing keys must be 16, 24 or 32 characters."
  }
}

run "postgres_releases" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
  }

  assert {
    condition = (
      helm_release.cnpg_operator.version == "0.29.1" &&
      helm_release.cnpg_barman_cloud.version == "0.9.0" &&
      helm_release.cnpg_barman_cloud.namespace == helm_release.cnpg_operator.namespace &&
      helm_release.postgres_cluster.version == "0.9.0" &&
      helm_release.cnpg_operator.namespace == "cnpg-system" &&
      helm_release.postgres_cluster.namespace == "postgres-db" &&
      helm_release.postgres_access.namespace == helm_release.postgres_cluster.namespace &&
      helm_release.local_path_provisioner.namespace == "local-path-storage"
    )
    error_message = "CloudNativePG chart versions are pinned; the cluster and its access chart share namespace postgres-db."
  }
}

run "postgres_without_allowlist_fails" {
  command = plan

  variables {
    postgres_allowed_ips = []
  }

  expect_failures = [helm_release.postgres_access]
}

run "postgres_tenants_get_a_database_role_and_credentials" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    postgres_databases = {
      shop = { namespace = "shop-ns" }
      blog = { namespace = "blog-ns", connection_limit = 10, extensions = ["vector"] }
    }
  }

  assert {
    condition = (
      kubernetes_secret_v1.postgres_role["shop"].metadata[0].namespace == "postgres-db" &&
      kubernetes_secret_v1.postgres_role["shop"].metadata[0].name == "db-shop" &&
      kubernetes_secret_v1.postgres_role["shop"].type == "kubernetes.io/basic-auth" &&
      kubernetes_secret_v1.postgres_app["blog"].metadata[0].namespace == "blog-ns" &&
      kubernetes_secret_v1.postgres_app["blog"].metadata[0].name == "postgres-db-credentials" &&
      kubernetes_secret_v1.postgres_app["blog"].data.host == "postgres-cluster-pooler-rw.postgres-db.svc.cluster.local" &&
      kubernetes_secret_v1.postgres_app["blog"].data.dbname == "blog"
    )
    error_message = "Each application gets db-<name> in postgres-db and postgres-db-credentials (through PgBouncer) in its namespace."
  }

  assert {
    condition = (
      [for r in local.postgres_tenants.cluster.roles : r.connectionLimit if r.name == "blog"][0] == 10 &&
      [for r in local.postgres_tenants.cluster.roles : r.connectionLimit if r.name == "shop"][0] == 50 &&
      alltrue([for d in local.postgres_tenants.databases : d.owner == d.name && d.databaseReclaimPolicy == "retain"])
    )
    error_message = "Each database is owned by its own role and kept when its entry is removed."
  }

  assert {
    condition = (
      [for d in local.postgres_tenants.databases : d.extensions if d.name == "blog"][0] == [{ name = "vector", ensure = "present" }] &&
      length([for d in local.postgres_tenants.databases : d.extensions if d.name == "shop"][0]) == 0
    )
    error_message = "A database lists the extensions the operator installs, and one without any lists none."
  }
}

run "postgres_reserved_names_refused" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    postgres_databases   = { postgres = { namespace = "x" } }
  }

  expect_failures = [var.postgres_databases]
}

run "redis_releases" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = ["192.0.2.1/32"]
  }

  assert {
    condition = (
      helm_release.redis.version == "0.25.16" &&
      helm_release.redis.repository == "oci://registry-1.docker.io/cloudpirates" &&
      helm_release.redis.namespace == "redis" &&
      helm_release.redis_access.namespace == helm_release.redis.namespace &&
      kubernetes_namespace_v1.redis.metadata[0].labels["istio-injection"] == "enabled"
    )
    error_message = "The Valkey chart is pinned; it and its access chart share namespace redis, which is in the mesh."
  }
}

run "embeddings_release" {
  command = plan

  assert {
    condition = (
      helm_release.bge_m3.namespace == "embeddings" &&
      helm_release.bge_m3.chart == "${local.minikube}/embeddings/bge-m3" &&
      kubernetes_namespace_v1.embeddings.metadata[0].labels["istio-injection"] == "enabled" &&
      helm_release.bge_m3.timeout >= 1200
    )
    error_message = "bge-m3 runs in namespace embeddings, in the mesh, with time for its first image pull and model download."
  }
}

run "redis_without_allowlist_fails" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = []
  }

  expect_failures = [helm_release.redis_access]
}

run "redis_tenants_get_a_scoped_user_and_credentials" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = ["192.0.2.1/32"]
    redis_tenants = {
      shop = { namespace = "shop-ns", databases = [3] }
      blog = { namespace = "blog-ns", databases = [4, 5] }
    }
  }

  assert {
    condition = (
      kubernetes_secret_v1.redis_app["blog"].metadata[0].namespace == "blog-ns" &&
      kubernetes_secret_v1.redis_app["blog"].metadata[0].name == "redis-blog-credentials" &&
      kubernetes_secret_v1.redis_app["blog"].data.host == "valkey-master.redis.svc.cluster.local" &&
      kubernetes_secret_v1.redis_app["blog"].data.db == "4" &&
      kubernetes_secret_v1.redis_app["blog"].data.databases == "4,5"
    )
    error_message = "Each tenant gets redis-<name>-credentials in its namespace, pointing at the master proxy and its first database."
  }

  assert {
    condition = (
      local.redis_tenant_acl["blog"] == "~* &* +@all -@admin -flushall -swapdb db=4,5" &&
      local.redis_tenant_acl["shop"] == "~* &* +@all -@admin -flushall -swapdb db=3" &&
      length(local.redis_acl_lines) == 4 &&
      length(local.redis_overrides.config.extraConfig) == length(local.redis_values.config.extraConfig) + 4
    )
    error_message = "Each tenant's user is limited to its own databases and has no admin command; the file's config lines are kept."
  }
}

run "redis_shared_database_refused" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = ["192.0.2.1/32"]
    redis_tenants = {
      a = { namespace = "x", databases = [1] }
      b = { namespace = "y", databases = [1, 2] }
    }
  }

  expect_failures = [var.redis_tenants]
}

run "argocd_uses_the_shared_valkey" {
  command = plan

  assert {
    condition = (
      helm_release.argocd.version == "10.10.5" &&
      helm_release.argocd.namespace == "argocd" &&
      kubernetes_namespace_v1.argocd.metadata[0].labels["istio-injection"] == "enabled" &&
      local.argocd_values.redis.enabled == false &&
      local.argocd_values["redis-ha"].enabled == false &&
      local.argocd_values.externalRedis.host == local.redis_host &&
      kubernetes_secret_v1.argocd_redis.metadata[0].namespace == "argocd" &&
      kubernetes_secret_v1.argocd_redis.data["redis-username"] == "argocd"
    )
    error_message = "Argo CD runs no Redis of its own; it signs in to valkey-master as ACL user argocd, from the mesh."
  }

  assert {
    condition = (
      local.redis_tenant_acl["argocd"] == "~* &* +@all -@admin -flushall -swapdb db=7" &&
      local.argocd_values.configs.params["redis.db"] == "7" &&
      contains(yamldecode(helm_release.redis_access.values[1]).clientNamespaces, "argocd") &&
      !contains(keys(kubernetes_secret_v1.redis_app), "argocd")
    )
    error_message = "ACL user argocd is limited to database 7 and namespace argocd may reach Valkey."
  }
}

run "redis_argocd_database_refused" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = ["192.0.2.1/32"]
    redis_tenants        = { app = { namespace = "x", databases = [7] } }
  }

  expect_failures = [var.redis_tenants]
}

run "redis_reserved_name_refused" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = ["192.0.2.1/32"]
    redis_tenants        = { default = { namespace = "x", databases = [1] } }
  }

  expect_failures = [var.redis_tenants]
}

run "redis_argocd_name_refused" {
  command = plan

  variables {
    postgres_allowed_ips = ["192.0.2.1/32"]
    redis_allowed_ips    = ["192.0.2.1/32"]
    redis_tenants        = { argocd = { namespace = "x", databases = [1] } }
  }

  expect_failures = [var.redis_tenants]
}

run "harbor_on_the_shared_databases" {
  command = plan

  variables {
    postgres_databases = { registry = { namespace = "harbor" } }
    redis_tenants      = { harbor = { namespace = "harbor", databases = [2, 3, 4, 5] } }
  }

  assert {
    condition = (
      helm_release.harbor.version == "1.19.4" &&
      helm_release.harbor.repository == "https://helm.goharbor.io" &&
      helm_release.harbor.namespace == "harbor" &&
      helm_release.harbor_access.namespace == "harbor" &&
      kubernetes_namespace_v1.harbor.metadata[0].labels["istio-injection"] == "enabled" &&
      kubernetes_secret_v1.harbor_dockerhub_pull.type == "kubernetes.io/dockerconfigjson" &&
      random_password.harbor["secretKey"].length == 16 &&
      random_password.harbor["HARBOR_ADMIN_PASSWORD"].min_upper == 1 &&
      kubernetes_secret_v1.harbor_credentials.metadata[0].name == "harbor-credentials" &&
      yamldecode(helm_release.harbor.values[0]).database.external.host == local.postgres_pool_host &&
      yamldecode(helm_release.harbor.values[0]).database.external.existingSecret == "postgres-db-credentials" &&
      yamldecode(helm_release.harbor.values[0]).redis.external.addr == "${local.redis_host}:6379" &&
      yamldecode(helm_release.harbor.values[0]).persistence.persistentVolumeClaim.registry.storageClass == "local-path"
    )
    error_message = "Harbor is pinned, in the mesh, uses the shared PostgreSQL (tenant registry) and Valkey (tenant harbor), on local-path."
  }
}

run "harbor_without_docker_hub_login_fails" {
  command = plan

  variables {
    dockerhub_password = ""
  }

  expect_failures = [kubernetes_secret_v1.harbor_dockerhub_pull]
}

run "gatekeeper_releases" {
  command = plan

  assert {
    condition = (
      helm_release.gatekeeper.version == "3.23.1" &&
      helm_release.gatekeeper.namespace == "gatekeeper-system" &&
      helm_release.gatekeeper_library.namespace == "gatekeeper-system" &&
      helm_release.gatekeeper_constraints.namespace == "gatekeeper-system"
    )
    error_message = "Gatekeeper is pinned and its releases live in gatekeeper-system."
  }

  assert {
    condition     = time_sleep.gatekeeper_constraint_kinds.create_duration == "30s"
    error_message = "Constraints wait for Gatekeeper to create their kinds after the templates."
  }
}

run "github_runners" {
  command = plan

  assert {
    condition = (
      helm_release.arc_controller.version == "0.15.1" &&
      helm_release.arc_runners.version == helm_release.arc_controller.version &&
      helm_release.arc_controller.namespace == "runners-system" &&
      helm_release.arc_runners.namespace == "runners" &&
      kubernetes_secret_v1.runners_github_app.metadata[0].namespace == helm_release.arc_runners.namespace &&
      kubernetes_network_policy_v1.runners.metadata[0].namespace == helm_release.arc_runners.namespace
    )
    error_message = "ARC is pinned, both charts on one version; the controller and the runners have their own namespaces, the app's Secret and the NetworkPolicy sit with the runners."
  }

  assert {
    condition = (
      yamldecode(helm_release.arc_runners.values[1]).githubConfigUrl == "https://github.com/mrjithendar" &&
      yamldecode(helm_release.arc_runners.values[1]).githubConfigSecret == "github-app" &&
      yamldecode(helm_release.arc_runners.values[1]).runnerScaleSetName == "mk4" &&
      yamldecode(helm_release.arc_runners.values[1]).controllerServiceAccount.namespace == "runners-system" &&
      yamldecode(helm_release.arc_runners.values[1]).controllerServiceAccount.name == "arc-gha-rs-controller"
    )
    error_message = "Scale set mk4 registers for the organization mrjithendar with Secret github-app and the controller's ServiceAccount."
  }

  assert {
    condition = (
      can(regex("^ghcr\\.io/mrjithendar/mk4-runner:[0-9.]+-[0-9a-f]{12}$", yamldecode(helm_release.arc_runners.values[0]).template.spec.containers[0].image)) &&
      yamldecode(helm_release.arc_runners.values[0]).template.spec.initContainers[0].image == yamldecode(helm_release.arc_runners.values[0]).template.spec.containers[0].image &&
      !can(yamldecode(helm_release.arc_runners.values[0]).containerMode)
    )
    error_message = "Runners use the organization's pinned runner image (build-runner-image.yml), init container included; the dind layout is written out, not containerMode (whose docker:dind is unpinned)."
  }

  assert {
    condition = (
      can(regex("^docker:[0-9.]+-dind$", yamldecode(helm_release.arc_runners.values[0]).template.spec.initContainers[1].image)) &&
      yamldecode(helm_release.arc_runners.values[0]).template.spec.initContainers[1].securityContext.privileged &&
      yamldecode(helm_release.arc_runners.values[0]).template.spec.initContainers[1].restartPolicy == "Always" &&
      kubernetes_namespace_v1.runners.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "privileged" &&
      kubernetes_namespace_v1.runners_system.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "baseline" &&
      contains(yamldecode(file("${local.minikube}/gatekeeper/constraints/values.yaml")).privilegedContainers.excludedNamespaces, "runners")
    )
    error_message = "Each runner pod has a pinned, privileged dind sidecar; only namespace runners admits it (Pod Security privileged, Gatekeeper exclusion), the controller's namespace stays baseline."
  }

  assert {
    condition = (
      kubernetes_network_policy_v1.runners.spec[0].policy_types == tolist(["Ingress", "Egress"]) &&
      length(kubernetes_network_policy_v1.runners.spec[0].ingress) == 0 &&
      contains(kubernetes_network_policy_v1.runners.spec[0].egress[1].to[0].ip_block[0].except, "10.0.0.0/8") &&
      contains(kubernetes_network_policy_v1.runners.spec[0].egress[1].to[0].ip_block[0].except, "169.254.0.0/16")
    )
    error_message = "Runner pods accept no connections and reach public addresses only (not mk4's networks or the metadata service)."
  }
}

run "github_runners_without_app_fails" {
  command = plan

  variables {
    github_runners_app_private_key = ""
  }

  expect_failures = [kubernetes_secret_v1.runners_github_app]
}

run "github_runners_bad_config_url_fails" {
  command = plan

  variables {
    github_runners_config_url = "github.com/mrjithendar"
  }

  expect_failures = [var.github_runners_config_url]
}

# Dashboards from mrjithendar/monitoring: ConfigMaps in grafana-dashboards, which its deploy workflow may write and
# Grafana's sidecar may read; nobody gets more.
run "grafana_dashboards_namespace" {
  command = plan

  assert {
    condition = (
      kubernetes_namespace_v1.grafana_dashboards.metadata[0].name == "grafana-dashboards" &&
      toset(kubernetes_role_v1.grafana_dashboards_reader.rule[0].resources) == toset(["configmaps"]) &&
      toset(kubernetes_role_v1.grafana_dashboards_reader.rule[0].verbs) == toset(["get", "list", "watch"]) &&
      kubernetes_role_binding_v1.grafana_dashboards_reader.subject[0].name == "grafana" &&
      kubernetes_role_binding_v1.grafana_dashboards_reader.subject[0].namespace == "monitoring"
    )
    error_message = "Grafana's sidecar reads ConfigMaps in grafana-dashboards only."
  }

  assert {
    condition = (
      length(kubernetes_role_v1.dashboards_deployer.rule) == 1 &&
      toset(kubernetes_role_v1.dashboards_deployer.rule[0].api_groups) == toset([""]) &&
      toset(kubernetes_role_v1.dashboards_deployer.rule[0].resources) == toset(["configmaps"]) &&
      !kubernetes_service_account_v1.dashboards_deployer.automount_service_account_token &&
      kubernetes_role_binding_v1.dashboards_deployer.metadata[0].namespace == "grafana-dashboards"
    )
    error_message = "monitoring's deploy workflow manages ConfigMaps in grafana-dashboards, nothing else."
  }
}

# Read-only Grafana for everyone (grafana.tf, docs/grafana-public.md). Off: login only, every dashboard in the main
# org, nothing public on the gateway.
run "grafana_private_by_default" {
  command = plan

  variables {
    grafana_public = null
  }

  assert {
    condition = (
      length(helm_release.grafana.values) == 1 &&
      length(yamldecode(helm_release.istio_edge.values[1]).cloudflare.public) == 0
    )
    error_message = "Without grafana_public Grafana keeps its login and the gateway has no public path."
  }
}

run "grafana_public" {
  command = plan

  variables {
    cloudflare_proxied = true
    grafana_public     = { org_id = 2 }
  }

  assert {
    condition = (
      yamldecode(helm_release.grafana.values[1])["grafana.ini"]["auth.anonymous"].enabled &&
      yamldecode(helm_release.grafana.values[1])["grafana.ini"]["auth.anonymous"].org_name == "Public" &&
      yamldecode(helm_release.grafana.values[1])["grafana.ini"]["auth.anonymous"].org_role == "Viewer"
    )
    error_message = "Anonymous visitors are Viewers of the org \"Public\"."
  }

  assert {
    # Prometheus and Loki, no Jaeger: only the private dashboards read traces. Loki without links into Jaeger.
    condition = (
      [for ds in yamldecode(helm_release.grafana.values[1]).datasources["datasources-public.yaml"].datasources : "${ds.type}/${ds.uid}/${ds.orgId}"] == ["prometheus/roboshop-prometheus/2", "loki/roboshop-loki/2"] &&
      [for ds in yamldecode(helm_release.grafana.values[1]).datasources["datasources-public.yaml"].datasources : ds if ds.type == "loki"][0].jsonData.derivedFields == []
    )
    error_message = "The org \"Public\" gets Prometheus and Loki (without Jaeger links), nothing else."
  }

  assert {
    condition = (
      { for p in yamldecode(helm_release.grafana.values[1]).dashboardProviders["dashboardproviders.yaml"].providers : p.name => p.orgId } == { public = 2, private = 1 } &&
      !contains(keys(yamldecode(helm_release.grafana.values[1]).datasources), "datasources.yaml")
    )
    error_message = "Dashboards from public/ go to the org \"Public\", private/ stay in the main org; the main org's data sources are untouched."
  }

  assert {
    condition     = yamldecode(helm_release.istio_edge.values[1]).cloudflare.public == ["/grafana"]
    error_message = "The gateway serves /grafana only through Cloudflare."
  }
}

run "grafana_public_needs_cloudflare" {
  command = plan

  variables {
    cloudflare_proxied = false
    grafana_public     = { org_id = 2 }
  }

  expect_failures = [helm_release.grafana]
}

run "grafana_public_never_the_main_org" {
  command = plan

  variables {
    grafana_public = { org_id = 1 }
  }

  expect_failures = [var.grafana_public]
}
