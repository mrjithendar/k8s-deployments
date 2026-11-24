"""Read-only Grafana for everyone (var.grafana_public, docs/grafana-public.md): the dashboards the org "Public" shows
query Prometheus only, and their ConfigMaps exist only while it is on. The gateway side is in test_istio_edge.py."""
import json
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'deploy/minikube/observability/grafana/dashboards'
PUBLIC = yaml.safe_load((CHART / 'values.yaml').read_text())['public']
# Side by side with this checkout, as grafana.tf expects (jithendar_com_dir).
JITHENDAR = ROOT.parent / 'jithendar.com' / 'grafana'
LISTED = [(folder, name) for folder, spec in PUBLIC['folders'].items() for name in spec['dashboards']]
# The data sources the org "Public" has: Prometheus (by uid, or the MOKS dashboards' ${datasource} variable, whose
# default is the org's default data source) and Grafana's own annotations.
ALLOWED = (
    {'type': 'prometheus', 'uid': 'roboshop-prometheus'},
    {'type': 'prometheus', 'uid': '${datasource}'},
    {'type': 'grafana', 'uid': '-- Grafana --'},
)


def data_sources(node):
    """Every data source a dashboard names: panels, targets, annotations, variables."""
    if isinstance(node, dict):
        if 'datasource' in node:
            yield node['datasource']
        for value in node.values():
            yield from data_sources(value)
    elif isinstance(node, list):
        for value in node:
            yield from data_sources(value)


def render(*args):
    output = subprocess.check_output(['helm', 'template', 'd', str(CHART), *args], text=True, stderr=subprocess.PIPE)
    return [d for d in yaml.safe_load_all(output) if d]


def jithendar_values(tmp_path, names):
    path = tmp_path / 'jithendar.yaml'
    path.write_text(yaml.safe_dump({'jithendar': {name: '{"uid": "%s"}' % name for name in names}}))
    return str(path)


@pytest.mark.parametrize('folder,name', LISTED)
def test_public_dashboards_query_prometheus_only(folder, name):
    """Logs and traces carry visitor addresses: the org "Public" has neither, and a panel on them would only fail."""
    path = (JITHENDAR if folder == 'jithendar' else CHART) / name
    if folder == 'jithendar' and not path.exists():
        pytest.skip(f'no jithendar.com checkout at {JITHENDAR.parent}')
    board = json.loads(path.read_text())
    for source in data_sources(board):
        assert source in ALLOWED, (folder, name, source)


def test_public_dashboards_are_in_their_own_folder():
    """Each public copy comes from the folder of the same name (its ConfigMap glob), so it keeps its place."""
    prefixes = {'jithendar': 'jithendar-com-', 'moks': 'moks-', 'platform': 'platform-', 'roboshop': 'roboshop-'}
    assert set(PUBLIC['folders']) == set(prefixes)
    for folder, name in LISTED:
        assert name.startswith(prefixes[folder]) and name.endswith('.json'), (folder, name)
        if folder != 'jithendar':
            assert (CHART / name).is_file(), name
    assert len(LISTED) == len(set(LISTED))


def test_public_configmaps_only_while_public(tmp_path):
    values = jithendar_values(tmp_path, PUBLIC['folders']['jithendar']['dashboards'])
    off = render('-f', values)
    assert not [d for d in off if d['metadata']['name'].startswith('grafana-dashboards-public-')]
    assert not PUBLIC['enabled']

    on = render('-f', values, '--set', 'public.enabled=true')
    public = {d['metadata']['name']: d for d in on if d['metadata']['name'].startswith('grafana-dashboards-public-')}
    assert sorted(public) == sorted(f'grafana-dashboards-public-{folder}' for folder in PUBLIC['folders'])
    for folder, spec in PUBLIC['folders'].items():
        configmap = public[f'grafana-dashboards-public-{folder}']
        assert configmap['metadata']['namespace'] == 'monitoring'
        assert sorted(configmap['data']) == sorted(spec['dashboards'])
    # Copies, verbatim: the same JSON as the folder's own ConfigMap.
    platform = public['grafana-dashboards-public-platform']['data']
    assert json.loads(platform['platform-postgres.json']) == json.loads((CHART / 'platform-postgres.json').read_text())
    assert json.loads(public['grafana-dashboards-public-jithendar']['data']['jithendar-com-news.json']) == {
        'uid': 'jithendar-com-news.json'}


def test_a_missing_public_dashboard_fails_the_render(tmp_path):
    values = jithendar_values(tmp_path, PUBLIC['folders']['jithendar']['dashboards'][1:])
    with pytest.raises(subprocess.CalledProcessError) as failed:
        render('-f', values, '--set', 'public.enabled=true')
    assert 'does not exist' in failed.value.stderr


def test_grafana_needs_a_login_unless_terraform_opens_it():
    """values.yaml stays private; only grafana.tf (var.grafana_public) adds the anonymous org."""
    grafana = yaml.safe_load((ROOT / 'deploy/minikube/observability/grafana/values.yaml').read_text())
    assert grafana['grafana.ini']['auth.anonymous'] == {'enabled': False}
    assert not [key for key in grafana['dashboardsConfigMaps'] if key.startswith('public-')]
