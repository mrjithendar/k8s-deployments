"""disk-cleanup.sh: what it removes from the cluster and its nodes and how it reports sizes; no cluster or SSH (fake
kubectl and ssh on PATH)."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'scripts/lib'
GiB, MiB = 1 << 30, 1 << 20
pytestmark = pytest.mark.skipif(shutil.which('jq') is None, reason='jq not installed')


def unused(tmp_path, images, containers):
    (tmp_path / 'i.json').write_text(json.dumps({'images': images}))
    (tmp_path / 'c.json').write_text(json.dumps({'containers': containers}))
    out = subprocess.run(['jq', '-n', '--slurpfile', 'i', str(tmp_path / 'i.json'), '--slurpfile', 'c',
                          str(tmp_path / 'c.json'), '-f', str(LIB / 'unused-images.jq')],
                         capture_output=True, text=True, check=True)
    return [i['name'] for i in json.loads(out.stdout)]


def test_unused_images_skip_running_exited_and_pinned(tmp_path):
    images = [
        {'id': 'sha256:a', 'repoTags': ['app:latest'], 'repoDigests': [], 'size': '10'},          # running
        {'id': 'sha256:b', 'repoTags': [], 'repoDigests': ['old@sha256:b1'], 'size': '30'},       # unused, untagged
        {'id': 'sha256:c', 'repoTags': ['job:1'], 'repoDigests': [], 'size': '20'},               # exited container
        {'id': 'sha256:d', 'repoTags': ['pause:3.10'], 'repoDigests': [], 'size': '1', 'pinned': True},
        {'id': 'sha256:e', 'repoTags': ['gone:2'], 'repoDigests': [], 'size': '50'},              # unused
    ]
    containers = [{'imageRef': 'sha256:a', 'image': {'image': 'sha256:a'}, 'state': 'CONTAINER_RUNNING'},
                  {'imageRef': 'job:1', 'image': {'image': 'job:1'}, 'state': 'CONTAINER_EXITED'}]
    assert unused(tmp_path, images, containers) == ['gone:2', 'old@sha256:b1']


def test_node_without_containers_lists_every_unpinned_image(tmp_path):
    assert unused(tmp_path, [{'id': 'sha256:x', 'size': '5'}], []) == ['sha256:x']


@pytest.mark.parametrize('args', [['--keep', '2'], ['--only', 'harbor'], ['--only', 'disks'], ['--bogus']])
def test_bad_arguments_stop_before_touching_anything(args):
    result = subprocess.run(['bash', str(ROOT / 'disk-cleanup.sh'), *args], cwd='/tmp', capture_output=True, text=True)
    assert result.returncode == 2


# --- node-disk-cleanup.sh on its own, with fake k3s, df and du ---------------------------------------------------------
@pytest.mark.parametrize('second_pass, removed, errors', [('Deleted: b\n', 2, 0), ('E1119 still DeadlineExceeded\n', 1, 1)])
def test_node_prune_goes_round_again_after_a_timeout(tmp_path, second_pass, removed, errors):
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    fakes = {
        'k3s': f'''#!/bin/sh
case "$*" in *"--timeout 10m rmi --prune"*) ;; *) echo "unexpected k3s $*" >&2; exit 1 ;; esac
if [ -e "{tmp_path}/pruned" ]; then printf '{second_pass}'; exit 0; fi
touch "{tmp_path}/pruned"; printf 'Deleted: a\\nE1119 RemoveImage failed: DeadlineExceeded\\n'
''',
        'df': '#!/bin/sh\nprintf "Used Avail\\n100 900\\n"\n',
        'du': '#!/bin/sh\nprintf "7\\ttotal\\n"\n',
        'journalctl': '#!/bin/sh\nexit 0\n',
        'apt-get': '#!/bin/sh\nexit 0\n',
    }
    for name, body in fakes.items():
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)
    result = subprocess.run(['bash', str(LIB / 'node-disk-cleanup.sh'), 'apply', 'pvc-1'], capture_output=True,
                            text=True, env={'PATH': f'{bin_dir}:/usr/bin:/bin'})
    lines = result.stdout.splitlines()
    assert lines[:3] == ['disk 100 900', 'journal 7', 'apt 7']
    assert f'removed {removed}' in lines and 'disk_after 100 900' in lines
    assert len([line for line in lines if line.startswith('error crictl:')]) == errors


# --- the script end to end, against fakes --------------------------------------------------------------------------
FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
state = os.environ['FAKE_STATE']
args = sys.argv[1:]
if args[:2] == ['config', 'current-context']:
    print('test'); sys.exit(0)
assert args[:2] == ['--context', 'test'], args
args = [a for a in args[2:] if not a.startswith('--request-timeout')]
with open(os.path.join(state, 'calls'), 'a') as f:
    f.write(json.dumps(args) + '\n')
if args == ['get', '--raw', '/readyz']:
    print('ok')
elif args[:2] == ['get', 'pv']:
    print('pvc-1')
elif args[:2] == ['get', 'nodes']:
    print(json.dumps({'items': [
        {'metadata': {'name': 'node-a'}, 'status': {'addresses': [{'type': 'ExternalIP', 'address': '10.0.0.1'}]}},
        {'metadata': {'name': 'node-b'}, 'status': {'addresses': [{'type': 'InternalIP', 'address': '10.0.0.2'}]}}]}))
else:
    print(f'unexpected kubectl {args}', file=sys.stderr); sys.exit(1)
'''

# Answers node-disk-cleanup.sh and the crictl calls the way a node would; NODES is keyed by IP.
FAKE_SSH = r'''#!/usr/bin/env python3
import json, os, sys
args, script = sys.argv[1:], sys.stdin.read()
node = json.load(open(os.path.join(os.environ['FAKE_STATE'], 'nodes.json')))[args[-2].split('@')[1]]
if 'crictl images' in script:
    print(json.dumps({'images': node['images']}))
elif 'crictl ps' in script:
    print(json.dumps({'containers': node['containers']}))
else:
    mode = args[-1].split()[3]
    print(node['report'] + ('\n' + node['apply'] if mode == 'apply' else ''))
'''

NODES = {
    '10.0.0.1': {   # node-a: one unused 3 GiB image, journald 100 MiB over the limit, a folder without a PV
        'images': [{'id': 'sha256:a', 'repoTags': ['app:1'], 'size': str(3 * GiB)},
                   {'id': 'sha256:b', 'repoTags': ['app:2'], 'size': str(GiB)}],
        'containers': [{'imageRef': 'sha256:b', 'image': {'image': 'sha256:b'}}],
        'report': f'disk {50 * GiB} {25 * GiB}\njournal {300 * MiB}\napt {MiB}\n'
                  f'orphan {2 * GiB} /var/local-path-provisioner/pvc-old_ns_data',
        'apply': f'removed 1\njournal_after {200 * MiB}\napt_after 0\ndisk_after {30 * GiB} {45 * GiB}',
    },
    '10.0.0.2': {   # node-b: nothing unused
        'images': [], 'containers': [],
        'report': f'disk {10 * GiB} {60 * GiB}\njournal {100 * MiB}\napt 0',
        'apply': f'removed 0\njournal_after {100 * MiB}\napt_after 0\ndisk_after {9 * GiB} {61 * GiB}',
    },
}


@pytest.fixture
def cleanup(tmp_path):
    bin_dir, state = tmp_path / 'bin', tmp_path / 'state'
    bin_dir.mkdir(), state.mkdir()
    for name, body in {'kubectl': FAKE_KUBECTL, 'ssh': FAKE_SSH}.items():
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)
    (state / 'nodes.json').write_text(json.dumps(NODES))

    def run(*args, only='nodes'):
        """The script's result and the kubectl calls it made."""
        env = {'PATH': f'{bin_dir}:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin', 'FAKE_STATE': str(state),
               'HOME': str(tmp_path)}
        result = subprocess.run(['bash', str(ROOT / 'disk-cleanup.sh'), '--only', only, *args], env=env,
                                capture_output=True, text=True, stdin=subprocess.DEVNULL)
        log = state / 'calls'
        return result, [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return run


def summary(stdout):
    return stdout.split('== Summary', 1)[1].split('== Done', 1)[0]


def test_nodes_dry_run_shows_each_node_and_what_could_go(cleanup):
    result, calls = cleanup()
    assert result.returncode == 0, result.stderr
    assert {c[0] for c in calls} == {'get'}
    out = result.stdout
    assert '  -- node-a (10.0.0.1)' in out and '  -- node-b (10.0.0.2)' in out
    assert 'disk          50.0 GiB used of 75.0 GiB, 25.0 GiB free (67%)' in out
    assert 'images        1 unused, 3.0 GiB compressed' in out and '3.0 GiB  app:1' in out
    assert 'no PersistentVolume  2.0 GiB  /var/local-path-provisioner/pvc-old_ns_data  (left in place)' in out
    assert 'could free    ~3.1 GiB (images 3.0 GiB, journald 100.0 MiB, apt cache 1.0 MiB)' in out
    table = summary(out)
    assert 'node-a                              50.0 GiB (67%)      ~3.1 GiB' in table
    assert 'node-b                              10.0 GiB (14%)      ~0.0 B' in table
    assert 'total                                                   ~3.1 GiB' in table


def test_apply_reports_each_node_before_and_after(cleanup):
    result, _ = cleanup('--apply', '--yes')
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert 'removed       1 images; journald 300.0 MiB -> 200.0 MiB; apt cache 1.0 MiB -> 0.0 B' in out
    assert 'disk after    30.0 GiB used, 45.0 GiB free: freed 20.0 GiB' in out
    table = summary(out)
    assert 'node-a                              50.0 GiB (67%)      30.0 GiB (40%)      20.0 GiB' in table
    assert 'node-b                              10.0 GiB (14%)      9.0 GiB (13%)       1.0 GiB' in table
    assert 'total freed                                                                 21.0 GiB' in table


def test_apply_without_a_terminal_needs_yes(cleanup):
    result, calls = cleanup('--apply')
    assert result.returncode == 1 and 'add --yes' in result.stderr
    assert calls == [['get', '--raw', '/readyz']]
