"""mk4's public edge (deploy/minikube/istio/edge) and mesh policies (istio/mesh): routing order, logins that fail
closed, client addresses, response headers, mTLS, who may call whom."""
import json
from pathlib import Path
import re
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'deploy/minikube/istio/edge'
VALUES = yaml.safe_load((CHART / 'values.yaml').read_text())
LOGINS = [login['name'] for login in VALUES['basicAuth']]
USERS = {name: f'{name}:{{SHA}}' + 'A' * 27 + '=' for name in LOGINS}


def render(*args, users=USERS):
    command = ['helm', 'template', 'edge', str(CHART), '-n', 'istio-ingress', *args]
    if users is not None:
        command += ['--set-json', 'basicAuthUsers=' + json.dumps(users)]
    return [d for d in yaml.safe_load_all(subprocess.check_output(command, text=True, stderr=subprocess.PIPE)) if d]


def of(docs, kind, name):
    return next(d for d in docs if d['kind'] == kind and d['metadata']['name'] == name)


def test_a_longer_prefix_comes_before_the_one_it_starts_with_and_the_site_is_last():
    routes = of(render(), 'VirtualService', 'jithendar-com')['spec']['http']
    prefixes = [r['match'][0]['uri']['prefix'] for r in routes if r.get('match') and 'uri' in r['match'][0]]
    for i, earlier in enumerate(prefixes):
        assert not any(later.startswith(earlier) and later != earlier for later in prefixes[i + 1:]), earlier
    assert routes[0]['redirect'] == {'authority': 'jithendar.com', 'redirectCode': 308}   # www first
    assert routes[-1] == {'name': 'site', 'delegate': {'name': 'jithendar-com-site', 'namespace': 'jithendar'}}
    assert all('route' not in r for r in routes)   # the root only redirects and delegates


def test_only_the_owning_namespace_binds_a_hostname():
    gateway = of(render(), 'Gateway', 'public')['spec']
    hosts = [h for s in gateway['servers'] for h in s['hosts']]
    assert all('/' in h and not h.startswith('*/') for h in hosts)
    # HTTPS first, one TLS (TCP) server per gateway.tls entry in its order, plain HTTP last.
    https, *tcp_servers, http = gateway['servers']
    assert [s['hosts'] for s in tcp_servers] == [[t['host']] for t in VALUES['gateway']['tls']]
    for tcp in tcp_servers:
        assert tcp['tls']['credentialName'] == https['tls']['credentialName'] == VALUES['gateway']['certificate']['secretName']
        assert tcp['port']['protocol'] == 'TLS'
    assert {h for s in tcp_servers for h in s['hosts']} >= {'postgres-db/postgres.jithendar.com', 'redis/redis.jithendar.com'}
    assert http['tls'] == {'httpsRedirect': True}   # plain HTTP never reaches a login


def test_every_except_is_covered_by_another_login():
    for login in VALUES['basicAuth']:
        if 'except' in login:
            assert any(other is not login and login['except'].startswith(other['prefix']) for other in VALUES['basicAuth']), login


def test_logins_are_required_to_render():
    with pytest.raises(subprocess.CalledProcessError) as failure:
        render(users={})
    assert 'gateway-basic-auth.py' in failure.value.stderr


def test_the_terraform_test_mock_has_every_login():
    # istio.tf refuses to plan without a line per login, so terraform test (mock providers) fails the same way when
    # its mocked gateway-basic-auth Secret misses one (#40 added "docling" to values.yaml but not to the mock).
    mock = (ROOT / 'minikube-infrastructure/tests/releases.tftest.hcl').read_text()
    block = mock.split('target = data.kubernetes_secret_v1.gateway_basic_auth', 1)[1]
    block = re.split(r'\n(?:mock_provider|run |\s*override_data)', block, maxsplit=1)[0]
    assert set(re.findall(r'"([a-z0-9-]+)"\s*=\s*"[^"\n]*\{SHA\}', block)) == set(LOGINS)


def test_logins_run_on_https_only_and_skip_paths_outside_their_prefix():
    patches = of(render(), 'EnvoyFilter', 'basic-auth')['spec']['configPatches']
    assert len(patches) == len(LOGINS)
    for patch, login in zip(patches, VALUES['basicAuth']):
        assert patch['match']['listener']['portNumber'] == 443
        value = patch['patch']['value']['typed_config']
        assert value['extension_config']['typed_config']['users']['inline_string'] == USERS[login['name']]
        matchers = value['xds_matcher']['matcher_list']['matchers']
        # Last matcher: skip unless the path starts with the prefix. No on_no_match: everything else must log in.
        assert matchers[-1]['predicate']['not_matcher']['single_predicate']['value_match'] == {'prefix': login['prefix']}
        assert 'on_no_match' not in value['xds_matcher']
        if 'except' in login:
            assert matchers[0]['predicate']['single_predicate']['value_match'] == {'prefix': login['except']}


def test_read_only_rules_never_touch_the_tcp_hosts():
    # values.yaml lists no read-only prefix since MOKS's OpenSearch was retired, so give the template one.
    read_only = [{'prefix': '/search', 'except': '/search-ui', 'postSuffixes': ['/_search']}]
    rules = of(render('--set-json', 'readOnly=' + json.dumps(read_only)), 'AuthorizationPolicy', 'read-only')['spec']['rules']
    snis = [t['host'].split('/', 1)[1] for t in VALUES['gateway']['tls']]
    assert rules and all(r['when'] == [{'key': 'connection.sni', 'notValues': snis}] for r in rules)
    assert all(r['to'][0]['operation']['ports'] == ['443'] for r in rules)
    # And with values.yaml as it is, there is no policy at all.
    assert not [d for d in render() if d['kind'] == 'AuthorizationPolicy' and d['metadata']['name'] == 'read-only']


def test_clients_cannot_choose_their_address():
    docs = render()
    headers = of(docs, 'EnvoyFilter', 'forwarded-for')['spec']['configPatches'][0]['patch']['value']['request_headers_to_add']
    assert {h['header']['key']: h['append_action'] for h in headers} == {'x-forwarded-for': 'OVERWRITE_IF_EXISTS_OR_ADD',
                                                                         'x-real-ip': 'OVERWRITE_IF_EXISTS_OR_ADD'}
    first = of(docs, 'EnvoyFilter', 'proxy-protocol')['spec']['configPatches']
    assert {p['match']['listener']['portNumber'] for p in first} == {80, 443}
    assert all(p['patch']['operation'] == 'INSERT_FIRST' for p in first)
    gateway_values = yaml.safe_load((ROOT / 'deploy/minikube/istio/ingressgateway.yaml').read_text())
    assert 'numTrustedProxies' not in json.dumps(gateway_values)


def test_the_proxy_header_is_required_and_nothing_targets_traefik():
    docs = render()
    assert not [d for d in docs if d['apiVersion'].startswith('traefik.io/')]
    allow = {p['patch']['value']['typed_config']['allow_requests_without_proxy_protocol']
             for p in of(docs, 'EnvoyFilter', 'proxy-protocol')['spec']['configPatches']}
    assert allow == {False}
    assert 'traefik' not in (ROOT / 'minikube-infrastructure/istio.tf').read_text()


def test_visitors_never_see_backend_timings():
    patch = of(render(), 'EnvoyFilter', 'response-headers')['spec']['configPatches'][0]
    assert patch['applyTo'] == 'ROUTE_CONFIGURATION' and patch['match']['context'] == 'GATEWAY'
    assert 'x-envoy-upstream-service-time' in patch['patch']['value']['response_headers_to_remove']


MESH = ROOT / 'deploy/minikube/istio/mesh'


def render_mesh(*args):
    command = ['helm', 'template', 'istio-mesh', str(MESH), '-n', 'istio-system', *args]
    return [d for d in yaml.safe_load_all(subprocess.check_output(command, text=True, stderr=subprocess.PIPE)) if d]


def test_mesh_default_is_strict_in_the_root_namespace():
    pa = of(render_mesh(), 'PeerAuthentication', 'default')
    assert pa['metadata']['namespace'] == 'istio-system' and 'selector' not in pa['spec']
    assert pa['spec']['mtls']['mode'] == 'STRICT'


def test_authorization_allows_own_namespace_and_starts_as_dry_run():
    policies = [d for d in render_mesh() if d['kind'] == 'AuthorizationPolicy']
    assert policies and all(p['metadata']['annotations'] == {'istio.io/dry-run': 'true'} for p in policies)
    for p in policies:
        namespace = p['metadata']['namespace']
        assert namespace != 'istio-system'
        assert 'selector' not in p['spec'] and p['spec']['action'] == 'ALLOW'
        assert p['spec']['rules'][0]['from'][0]['source']['namespaces'][0] == namespace
    enforced = [d for d in render_mesh('--set', 'authorization.dryRun=false') if d['kind'] == 'AuthorizationPolicy']
    assert all('annotations' not in p['metadata'] for p in enforced)


def test_every_listed_namespace_has_its_template():
    listed = set(yaml.safe_load((MESH / 'values.yaml').read_text())['authorization']['namespaces'])
    files = {p.stem.removeprefix('authorization-') for p in (MESH / 'templates').glob('authorization-*.yaml')} - {'guard'}
    assert listed == files


def test_authorization_never_lists_the_root_namespace():
    command = ['helm', 'template', 'm', str(MESH), '-n', 'istio-system', '--set-json',
               'authorization.namespaces={"istio-system": ["monitoring"]}']
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0 and 'whole mesh' in result.stderr


def test_gateway_access_log_only_has_fields_alloy_keeps():
    telemetry = of(render_mesh(), 'Telemetry', 'edge-access-log')
    assert telemetry['spec']['selector']['matchLabels'] == {'istio': 'ingressgateway'}
    istiod = yaml.safe_load((ROOT / 'deploy/minikube/istio/istiod.yaml').read_text())
    provider = next(p for p in istiod['meshConfig']['extensionProviders'] if p['name'] == 'edge-access-log')
    labels = provider['envoyFileAccessLog']['logFormat']['labels']
    # Alloy's allowlist (observability/loki/config.alloy); never a client address, path, query or header.
    assert set(labels) <= {'event', 'level', 'method', 'status', 'durationMs', 'operation', 'errorCode', 'route',
                           'dependency', 'outcome', 'errorType', 'logger_name', 'traceId'}
    assert not any(word in json.dumps(labels) for word in ('PATH', 'REMOTE_ADDRESS', 'X-FORWARDED', 'AUTHORITY'))


def test_edge_and_control_plane_survive_one_node():
    gateway = yaml.safe_load((ROOT / 'deploy/minikube/istio/ingressgateway.yaml').read_text())
    assert gateway['replicaCount'] >= 2 and gateway['podDisruptionBudget'] == {'minAvailable': 1}
    istiod = yaml.safe_load((ROOT / 'deploy/minikube/istio/istiod.yaml').read_text())
    assert istiod['pilot']['replicaCount'] >= 2
    kiali = yaml.safe_load((ROOT / 'deploy/minikube/istio/kiali.yaml').read_text())
    assert kiali['deployment']['pod_labels'] == {'sidecar.istio.io/inject': 'true'}   # Prometheus is STRICT


def test_the_forged_header_rule_judges_the_proxy_protocol_address_not_the_load_balancer():
    """ipBlocks is the physical peer (the load balancer), so a rule on it refused every request Cloudflare sent.
    remoteIpBlocks is the PROXY protocol's address: Cloudflare's edge through Cloudflare, the visitor directly."""
    docs = render('--set', 'cloudflare.proxied=true')
    rule = of(docs, 'AuthorizationPolicy', 'cloudflare-forged-header')['spec']['rules'][0]
    source = rule['from'][0]['source']
    assert 'notIpBlocks' not in source and 'ipBlocks' not in source
    assert source['notRemoteIpBlocks'] == VALUES['cloudflare']['ipRanges']
    assert {'key': 'request.headers[cf-connecting-ip]', 'values': ['*']} in rule['when']
    assert not [d for d in render() if d['metadata']['name'] == 'cloudflare-forged-header']   # only while proxied


ACCESS = ('--set', 'cloudflare.access.enabled=true', '--set', 'cloudflare.access.teamDomain=team.cloudflareaccess.com',
          '--set', 'cloudflare.access.audiences[0]=aud')


def test_public_paths_are_served_only_through_cloudflare():
    """The public Grafana's human check is a Cloudflare rule: straight to the server's address it would be skipped.
    Judged on the PROXY protocol's address (remoteIpBlocks), like the forged-header rule, never the load balancer."""
    docs = render('--set', 'cloudflare.proxied=true', '--set-json', 'cloudflare.public=["/grafana"]')
    policy = of(docs, 'AuthorizationPolicy', 'cloudflare-public')['spec']
    assert policy['action'] == 'DENY'
    rule = policy['rules'][0]
    assert rule['from'] == [{'source': {'notRemoteIpBlocks': VALUES['cloudflare']['ipRanges']}}]
    assert rule['to'] == [{'operation': {'paths': ['/grafana', '/grafana/*']}}]
    assert rule['when'][0]['key'] == 'connection.sni'   # off the TLS (TCP) hosts
    assert VALUES['cloudflare']['public'] == []   # Terraform opens it (var.grafana_public)
    assert not [d for d in render('--set', 'cloudflare.proxied=true') if d['metadata']['name'] == 'cloudflare-public']


def test_public_paths_need_cloudflare_in_front():
    with pytest.raises(subprocess.CalledProcessError) as failed:
        render('--set-json', 'cloudflare.public=["/grafana"]')
    assert 'cloudflare.public needs cloudflare.proxied' in failed.value.stderr


def test_a_public_path_leaves_cloudflare_access():
    paths = lambda docs: of(docs, 'AuthorizationPolicy', 'cloudflare-access')['spec']['rules'][0]['to'][0]['operation']['paths']
    private = paths(render('--set', 'cloudflare.proxied=true', *ACCESS))
    public = paths(render('--set', 'cloudflare.proxied=true', *ACCESS, '--set-json', 'cloudflare.public=["/grafana"]'))
    assert {'/grafana', '/grafana/*'} <= set(private)
    assert set(private) - set(public) == {'/grafana', '/grafana/*'}
