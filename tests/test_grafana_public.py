"""Grafana's dashboards come from mrjithendar/monitoring (ConfigMaps in grafana-dashboards, loaded by the sidecar), and
read-only Grafana for everyone is Terraform's to switch on (var.grafana_public, docs/grafana-public.md). The gateway
side is in test_istio_edge.py; the Terraform side in minikube-infrastructure/tests/releases.tftest.hcl."""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
GRAFANA = yaml.safe_load((ROOT / 'deploy/minikube/observability/grafana/values.yaml').read_text())


def test_grafana_needs_a_login_unless_terraform_opens_it():
    assert GRAFANA['grafana.ini']['auth.anonymous'] == {'enabled': False}
    assert all(ds.get('orgId', 1) == 1 for ds in GRAFANA['datasources']['datasources.yaml']['datasources'])


def test_the_sidecar_reads_dashboard_configmaps_from_one_namespace():
    sidecar = GRAFANA['sidecar']['dashboards']
    assert sidecar['enabled'] and not sidecar['SCProvider']
    assert (sidecar['label'], sidecar['labelValue']) == ('grafana_dashboard', '1')
    assert sidecar['searchNamespace'] == 'grafana-dashboards' and sidecar['resource'] == 'configmap'
    assert sidecar['folderAnnotation'] == 'grafana_folder'
    # The reload API needs the admin password; the providers poll instead.
    assert sidecar['skipReload'] is True
    # Gatekeeper's requiredResources: a memory limit on every container.
    assert GRAFANA['sidecar']['resources']['limits']['memory']


def test_grafana_gets_no_cluster_wide_read():
    """The chart's ClusterRole would read every Secret and ConfigMap; grafana.tf grants grafana-dashboards only."""
    assert GRAFANA['rbac'] == {'create': False}
    terraform = (ROOT / 'minikube-infrastructure/grafana.tf').read_text()
    assert 'resources  = ["configmaps"]\n    verbs      = ["get", "list", "watch"]' in terraform


def test_one_provider_per_org_reads_its_directory():
    folder = GRAFANA['sidecar']['dashboards']['folder']
    providers = {p['name']: p for p in GRAFANA['dashboardProviders']['dashboardproviders.yaml']['providers']}
    assert set(providers) == {'public', 'private'}
    for name, p in providers.items():
        assert p['options'] == {'path': f'{folder}/{name}', 'foldersFromFilesStructure': True}
        assert p['orgId'] == 1  # grafana.tf moves "public" to the org "Public" while var.grafana_public is set
        assert not p['allowUiUpdates'] and not p['editable']
        assert p['disableDeletion'] is False  # a dashboard removed from monitoring goes
    assert 'dashboardsConfigMaps' not in GRAFANA


def test_home_is_monitoring_s_landing_page():
    folder = GRAFANA['sidecar']['dashboards']['folder']
    path = GRAFANA['grafana.ini']['dashboards']['default_home_dashboard_path']
    assert path == f'{folder}/public/live-infrastructure.json'
