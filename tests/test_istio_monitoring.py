"""Istio in Grafana: the Platform · Istio dashboards, what Prometheus scrapes for them (every istiod replica, every
proxy's Envoy stats, filtered), and the istio alerts with their runbooks."""
from pathlib import Path
import json
import re
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
README = (ROOT / 'deploy/minikube/istio/README.md').read_text()
ALERTS = yaml.safe_load((ROOT / 'deploy/minikube/observability/prometheus/files/alerts.yml').read_text())


def scrape_jobs():
    out = subprocess.check_output(['helm', 'template', 'prometheus', str(ROOT / 'deploy/minikube/observability/prometheus'),
                                   '-n', 'monitoring', '-s', 'templates/config.yaml'], text=True)
    config = yaml.safe_load(yaml.safe_load(out)['data']['prometheus.yml'])
    return {job['job_name']: job for job in config['scrape_configs']}


def test_every_envoy_stats_metric_read_survives_the_scrape_filter():
    relabels = scrape_jobs()['envoy-stats']['metric_relabel_configs']
    by_name = [r for r in relabels if r['source_labels'] == ['__name__']]
    assert [r['action'] for r in by_name] == ['keep', 'drop']

    def kept(metric):
        keep, drop = (re.fullmatch(r['regex'], metric) for r in by_name)
        return bool(keep) and not drop

    # What the alerts read, and what the Platform dashboards are known to need (mrjithendar/monitoring checks every one of
    # its queries against this filter: tests/test_k8s_deployments.py).
    read = {'istio_requests_total', 'istio_request_duration_milliseconds_bucket', 'envoy_http_rbac', 'envoy_tcp',
            'istio_response_bytes_sum', 'istio_tcp_connections_opened_total'}
    for expr in [r['expr'] for g in ALERTS['groups'] for r in g['rules']]:
        if 'job="envoy-stats"' in expr:
            read |= set(re.findall(r'\b((?:istio|envoy)_[a-z_]+)\b', expr))
    assert {m for m in read if not kept(m)} == set()
    # And what is meant to go: Envoy's internals and the size histograms.
    assert not kept('envoy_cluster_upstream_cx_total') and not kept('istio_response_bytes_bucket')
    assert kept('istio_response_bytes_sum')


def test_envoy_stats_skips_finished_job_pods():
    phase = [r for r in scrape_jobs()['envoy-stats']['relabel_configs']
             if r.get('source_labels') == ['__meta_kubernetes_pod_phase']]
    assert phase == [{'source_labels': ['__meta_kubernetes_pod_phase'], 'action': 'drop', 'regex': 'Succeeded|Failed'}]


def test_every_istiod_replica_is_a_target():
    job = scrape_jobs()['istiod']
    assert 'static_configs' not in job, 'through the Service, each scrape reaches one replica at random'
    assert job['kubernetes_sd_configs'] == [{'role': 'pod', 'namespaces': {'names': ['istio-system']}}]
    keep = job['relabel_configs'][0]
    assert keep['action'] == 'keep' and keep['regex'] == 'istiod;http-monitoring'
    assert {r.get('target_label') for r in job['relabel_configs']} >= {'namespace', 'pod'}
    # mrjithendar/monitoring's control-plane dashboard expects istiod.yaml's replicaCount (its tests read this file).


def test_istio_alerts_have_runbooks_in_the_readme():
    group = next(g for g in ALERTS['groups'] if g['name'] == 'istio')
    names = [r['alert'] for r in group['rules']]
    assert names == ['IstiodDown', 'IstiodReplicaDown', 'IstioProxyNotScraped', 'IstioConfigRejected']
    assert re.search(r'^## Monitoring$', README, re.M)
    for rule in group['rules']:
        assert rule['annotations']['runbook_url'].endswith('deploy/minikube/istio/README.md#monitoring')
        assert f'**{rule["alert"]}**' in README
        assert re.search(r'job="(istiod|envoy-stats)"', rule['expr'])
