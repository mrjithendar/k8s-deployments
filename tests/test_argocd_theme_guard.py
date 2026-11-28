"""EnvoyFilter argocd-theme-guard (deploy/minikube/argocd/values.yaml): Argo CD shares the jithendar.com origin, and
its main.js starts with JSON.parse(localStorage.getItem("theme")) || "light". Open WebUI (/chat) stores a bare word
under "theme" ("system" on its first load), which made that throw: a blank Argo CD page. A Lua filter in
argocd-server's sidecar adds a script to Argo CD's page that hides a non-JSON "theme" from Argo CD."""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
VALUES = yaml.safe_load((ROOT / 'deploy/minikube/argocd/values.yaml').read_text())
GUARD = next(o for o in VALUES['extraObjects'] if o['kind'] == 'EnvoyFilter' and o['metadata']['name'] == 'argocd-theme-guard')
PATCH = GUARD['spec']['configPatches'][0]
LUA = PATCH['patch']['value']['typed_config']['default_source_code']['inline_string']
SCRIPT = re.search(r'\[==\[<script>(.*)</script>\]==\]', LUA, re.S).group(1)

# Argo CD's own first read of the key (main.js, argo-ui's theme context).
ARGO_CD_READ = 'JSON.parse(window.localStorage.getItem("theme")) || "light"'


def test_the_filter_sits_in_argocd_servers_sidecar_on_the_server_port():
    assert GUARD['metadata']['namespace'] == 'argocd'
    assert GUARD['spec']['workloadSelector']['labels'] == {
        'app.kubernetes.io/name': 'argocd-server', 'app.kubernetes.io/instance': 'argocd'}
    assert PATCH['applyTo'] == 'HTTP_FILTER' and PATCH['patch']['operation'] == 'INSERT_BEFORE'
    match = PATCH['match']
    assert match['context'] == 'SIDECAR_INBOUND'
    # argocd-server's --port (the chart's default); the Service sends 80 and 443 there.
    assert match['listener']['portNumber'] == 8080
    assert match['listener']['filterChain']['filter']['subFilter'] == {'name': 'envoy.filters.http.router'}
    assert PATCH['patch']['value']['typed_config']['@type'] == 'type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua'


def test_only_uncompressed_pages_change():
    """The chart passes extraObjects through tpl, so no template braces; pages are asked for uncompressed, a page that
    comes back compressed anyway and everything that is not HTML pass through, and the script goes first in <head>."""
    assert '{{' not in LUA
    assert 'headers:remove("accept-encoding")' in LUA
    assert 'headers:get("content-encoding") ~= nil then\n    return' in LUA
    assert 'string.find(content_type, "text/html", 1, true) == nil then\n    return' in LUA
    assert 'string.find(html, "<head>", 1, true)' in LUA
    assert 'response_handle:headers():replace("content-length", tostring(length))' in LUA


def run_script(local: dict, session: dict | None = None, reads: str = ARGO_CD_READ):
    """The page script in Node, with a stand-in for the browser's Storage. Returns what `reads` evaluates to."""
    program = f"""
globalThis.Storage = class Storage {{
  constructor(items) {{ this.items = new Map(Object.entries(items)); }}
  getItem(key) {{ return this.items.has(key) ? this.items.get(key) : null; }}
  setItem(key, value) {{ this.items.set(key, String(value)); }}
}};
globalThis.window = {{
  localStorage: new Storage({json.dumps(local)}),
  sessionStorage: new Storage({json.dumps(session or {})}),
}};
{SCRIPT}
process.stdout.write(JSON.stringify({reads}));
"""
    out = subprocess.run(['node', '-'], input=program, capture_output=True, text=True, check=True, timeout=30)
    return json.loads(out.stdout)


needs_node = pytest.mark.skipif(shutil.which('node') is None, reason='node not installed')


@needs_node
@pytest.mark.parametrize('stored', ['system', 'light', 'dark', 'oled-dark', 'her', '', '{"broken"'])
def test_argo_cd_starts_whatever_bare_word_another_app_stored(stored):
    assert run_script({'theme': stored}) == 'light'


@needs_node
def test_a_json_theme_and_no_theme_reach_argo_cd_as_before():
    assert run_script({'theme': '"dark"'}) == 'dark'
    assert run_script({}) == 'light'


@needs_node
def test_open_webuis_value_and_everything_else_are_untouched():
    assert run_script({'theme': 'system'}, reads='window.localStorage.items.get("theme")') == 'system'
    assert run_script({'theme': 'system', 'other': 'system'}, reads='window.localStorage.getItem("other")') == 'system'
    assert run_script({}, {'theme': 'system'}, reads='window.sessionStorage.getItem("theme")') == 'system'
    assert run_script({}, reads='(window.localStorage.setItem("theme", "dark"), window.localStorage.items.get("theme"))') == 'dark'
