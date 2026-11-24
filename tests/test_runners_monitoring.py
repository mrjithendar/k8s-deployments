"""GitHub Actions runners in Grafana: the Platform · GitHub runners and · GitHub runner pods dashboards, the metrics
Actions Runner Controller exports for them (controller.yaml), and Prometheus job arc that scrapes the controller and
the listener."""
from pathlib import Path
import json
import re
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = yaml.safe_load((ROOT / 'deploy/minikube/runners/controller.yaml').read_text())
SCALE_SET = yaml.safe_load((ROOT / 'deploy/minikube/runners/values.yaml').read_text())
README = (ROOT / 'deploy/minikube/runners/README.md').read_text()

# What ARC 0.15.1 exports: the listener (cmd/ghalistener/metrics, every one of them with listenerMetrics unset) and the
# controller (controllers/actions.github.com/metrics).
LISTENER_METRICS = {
    'gha_assigned_jobs', 'gha_running_jobs', 'gha_registered_runners', 'gha_busy_runners', 'gha_min_runners',
    'gha_max_runners', 'gha_desired_runners', 'gha_idle_runners', 'gha_started_jobs_total',
    'gha_completed_jobs_total', 'gha_job_startup_duration_seconds', 'gha_job_execution_duration_seconds'}
CONTROLLER_METRICS = {
    f'gha_controller_{m}' for m in ('pending_ephemeral_runners', 'running_ephemeral_runners',
                                    'succeeded_ephemeral_runners', 'failed_ephemeral_runners',
                                    'outdated_ephemeral_runners', 'running_listeners')}
def scrape_jobs():
    out = subprocess.check_output(['helm', 'template', 'prometheus', str(ROOT / 'deploy/minikube/observability/prometheus'),
                                   '-n', 'monitoring', '-s', 'templates/config.yaml'], text=True)
    config = yaml.safe_load(yaml.safe_load(out)['data']['prometheus.yml'])
    return {job['job_name']: job for job in config['scrape_configs']}


def test_every_arc_metric_read_survives_the_scrape_filter():
    job = scrape_jobs()['arc']
    (keep,) = job['metric_relabel_configs']
    assert keep['source_labels'] == ['__name__'] and keep['action'] == 'keep'
    # Every metric ARC exports that the dashboards may read (mrjithendar/monitoring checks the ones they do).
    names = set()
    for m in LISTENER_METRICS | CONTROLLER_METRICS:
        names |= {f'{m}_{s}' for s in ('bucket', 'sum', 'count')} if m.endswith('_seconds') else {m}
    assert {n for n in names if not re.fullmatch(keep['regex'], n)} == set()


def test_arc_exports_metrics_where_job_arc_looks():
    metrics = CONTROLLER['metrics']
    assert metrics['controllerManagerAddr'] != '0' and metrics['listenerAddr']
    job = scrape_jobs()['arc']
    assert job['metrics_path'] == metrics['listenerEndpoint'] == '/metrics'   # the controller's is always /metrics
    assert job['kubernetes_sd_configs'] == [{'role': 'pod', 'namespaces': {'names': ['runners-system']}}]
    keep = job['relabel_configs'][0]
    assert keep == {'source_labels': ['__meta_kubernetes_pod_container_port_name'], 'regex': 'metrics',
                    'action': 'keep'}
    components = {r['replacement'] for r in job['relabel_configs'] if r.get('target_label') == 'component'}
    assert components == {'controller', 'listener'}
    # The listener's series carry the scale set's namespace (runners); a target label would rename it.
    assert 'namespace' not in {r.get('target_label') for r in job['relabel_configs']}


def test_the_job_metrics_keep_arc_s_default_labels():
    # The dashboards group job metrics by repository, job_name, job_result...: ARC's defaults, unset listenerMetrics.
    assert 'listenerMetrics' not in SCALE_SET


def test_the_readme_names_both_dashboards():
    assert '## Metrics and dashboards' in README
    for title in ('Platform · GitHub runners', 'Platform · GitHub runner pods'):
        assert title in README
