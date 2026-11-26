"""bge-m3 monitoring: the Platform dashboard reads only bge-m3's series, counts a caller's first request, its alerts
have runbooks, and Prometheus can read the sidecars' own metrics (envoy-stats) instead of its own sidecar's."""
from pathlib import Path
import json
import re
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]
ALERTS = yaml.safe_load((ROOT / 'deploy/minikube/observability/prometheus/files/alerts.yml').read_text())
README = (ROOT / 'docs/bge-m3-monitoring.md').read_text()
SELECTOR = re.compile(r'(istio_\w+)\{([^}]*)\}')
UNDELIVERED = 'response_flags=~".*(UH|UF|UO|NR).*"'


def flat(expr):
    return ' '.join(expr.split())


def counts_new_series(expr, window):
    """Every Istio counter in expr is counted with increase() plus the starting value of a series that appears inside
    the window, which increase() alone reads as 0."""
    expr = flat(expr)
    for name, labels in set(SELECTOR.findall(expr)):
        series = f'{name}{{{labels}}}'
        assert f'increase({series}[{window}])' in expr, series
        assert f'min_over_time({series}[{window}]) unless {series} offset {window}' in expr, series
    return True


def test_failing_alert_counts_new_codes_and_undelivered_requests():
    group = next(g for g in ALERTS['groups'] if g['name'] == 'embeddings')
    expr = next(r['expr'] for r in group['rules'] if r['alert'] == 'BgeM3RequestsFailing')
    assert counts_new_series(expr, '15m')
    assert 'response_code!~"2.."' in expr and UNDELIVERED in expr
    assert flat(expr).endswith(') >= 3')


def test_vector_estimate_matches_the_documented_size():
    # The dashboard divides by the same 12800 (mrjithendar/monitoring, tests/test_platform.py).
    assert '12.8 KB' in README


def test_alerts_have_runbooks_in_the_readme():
    group = next(g for g in ALERTS['groups'] if g['name'] == 'embeddings')
    names = [r['alert'] for r in group['rules']]
    assert names == ['BgeM3NotRunning', 'BgeM3ModelNotLoaded', 'BgeM3RequestsFailing', 'BgeM3MemoryNearLimit']
    for rule in group['rules']:
        assert rule['annotations']['runbook_url'].endswith('docs/bge-m3-monitoring.md#monitoring')
        assert f'**{rule["alert"]}**' in README
    assert re.search(r'^## Monitoring$', README, re.M)


def test_prometheus_reaches_the_sidecar_ports_past_its_own_envoy():
    out = subprocess.check_output(['helm', 'template', 'prometheus', str(ROOT / 'deploy/minikube/observability/prometheus'),
                                   '-n', 'monitoring'], text=True)
    deploy = next(d for d in yaml.safe_load_all(out) if d and d['kind'] == 'Deployment')
    annotations = deploy['spec']['template']['metadata']['annotations']
    assert set(annotations['traffic.sidecar.istio.io/excludeOutboundPorts'].split(',')) == {'15020', '15090'}
    # Only those ports: everything else still goes out through the sidecar, as mTLS to STRICT targets.
    assert 'traffic.sidecar.istio.io/includeOutboundIPRanges' not in annotations


def test_kiali_sidecar_is_scrapable():
    tf = (ROOT / 'minikube-infrastructure/kiali.tf').read_text()
    policy = tf[tf.index('resource "kubernetes_network_policy_v1" "kiali_sidecar_metrics"'):]
    assert '"kubernetes.io/metadata.name" = "monitoring"' in policy
    assert 'port     = "15090"' in policy and 'port     = "15020"' in policy
