"""disk-cleanup.yml: disk-cleanup.sh --apply on mk4 every day at 06:00 IST and by hand, from master only."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re

import yaml

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / '.github/workflows/disk-cleanup.yml').read_text()
WORKFLOW = yaml.safe_load(TEXT)
JOB = WORKFLOW['jobs']['cleanup']
IST = timezone(timedelta(hours=5, minutes=30))


def start_utc():
    [entry] = WORKFLOW[True]['schedule']   # PyYAML reads the key "on" as True
    minute, hour, *rest = entry['cron'].split()
    assert rest == ['*', '*', '*'], 'every day'
    return datetime(2026, 1, 1, int(hour), int(minute), tzinfo=timezone.utc)


def step(text):
    """Index of the first step whose run script contains `text`."""
    return next(i for i, s in enumerate(JOB['steps']) if text in s.get('run', ''))


def test_runs_every_day_at_six_ist_and_by_hand():
    assert set(WORKFLOW[True]) == {'schedule', 'workflow_dispatch'}
    assert start_utc().astimezone(IST).strftime('%H:%M') == '06:00'
    assert set(WORKFLOW[True]['workflow_dispatch']['inputs']) == {'dry_run', 'only'}


def test_applies_from_master_through_environment_mk4_one_run_at_a_time():
    assert JOB['environment'] == 'mk4' and JOB['if'] == "github.ref == 'refs/heads/master'"
    assert WORKFLOW['permissions'] == {'contents': 'read'}
    assert WORKFLOW['concurrency']['cancel-in-progress'] is False
    run = JOB['steps'][step('./disk-cleanup.sh')]['run']
    assert 'args=(--yes --only "$ONLY")' in run
    assert 'if [[ "$DRY_RUN" != true ]]; then args+=(--apply); fi' in run
    # A scheduled run has no inputs: it applies everything with the script's defaults.
    assert JOB['env'] == {'DRY_RUN': '${{ inputs.dry_run }}', 'ONLY': "${{ inputs.only || 'pods,nodes' }}"}


def test_inputs_and_secrets_reach_the_shell_only_through_env():
    for s in JOB['steps']:
        assert '${{' not in s.get('run', ''), s.get('name')
    assert not re.search(r'\$\{\{\s*secrets\.', yaml.safe_dump(JOB['env']))


def test_node_addresses_are_masked_before_the_script_prints_them():
    assert step('::add-mask::$ip') < step('./disk-cleanup.sh')


def test_credentials_are_removed_whatever_happened():
    last = JOB['steps'][-1]
    assert last['if'] == 'always()'
    assert '"$RUNNER_TEMP/kubeconfig"' in last['run'] and '"$RUNNER_TEMP/mk4-ssh-key"' in last['run']
    access = JOB['steps'][step('$GITHUB_ENV')]['run']
    assert 'KUBECONFIG="$RUNNER_TEMP/kubeconfig" SSH_KEY="$RUNNER_TEMP/mk4-ssh-key"' in access
