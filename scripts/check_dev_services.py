#!/usr/bin/env python3
"""Isolated acceptance checks for development service recipes; never use live projects."""
import argparse
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def make_checks():
    failures = []
    with tempfile.TemporaryDirectory(prefix="borg-make-") as directory:
        base = Path(directory)
        fixture = base / "checkout"
        fixture.mkdir()
        shutil.copy2(ROOT / "Makefile", fixture)
        shutil.copytree(ROOT / "services", fixture / "services")
        if (ROOT / "scripts/dev_services.py").exists():
            (fixture / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/dev_services.py", fixture / "scripts/dev_services.py")
        tools = base / "bin"
        tools.mkdir()
        temporary = base / 'tmp'
        temporary.mkdir()
        events = base / "events"
        stub = tools / "stub"
        stub.write_text('''#!'''+sys.executable+'''
import json,os,pathlib,sys,time
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
if name=='iex':
 with open(os.environ['EVENTS'],'a') as f: f.write(json.dumps({'args':a,'values':{},'oauth':os.environ.get('CLAUDE_CODE_OAUTH_TOKEN')=='literal-token','port':os.environ.get('POSTGRES_PORT'),'epmd':os.environ.get('ERL_EPMD_ADDRESS')})+'\\n')
 sys.exit(0)
if name=='sudo':
 os.execvpe(a[0],a,{k:v for k,v in os.environ.items() if k not in ('POSTGRES_PASSWORD','POSTGRES_PORT')})
if name in ('podman','docker') and (a[:2]==['compose','version'] or a[:2]==['machine','inspect']):
 sys.exit(0)
if a[:1]==['compose']: a=a[1:]
values={}
if '--env-file' in a:
 p=pathlib.Path(a[a.index('--env-file')+1]); values=dict(x.split('=',1) for x in p.read_text().splitlines())
 assert p.stat().st_mode & 0o777 == 0o600
 assert all(k not in os.environ for k in set(values) | {'POSTGRES_PASSWORD','POSTGRES_PORT','BORG_DIST_COOKIE'})
with open(os.environ['EVENTS'],'a') as f: f.write(json.dumps({'args':a,'values':values})+'\\n')
if 'build' in a: sys.exit(int(os.environ.get('BUILD_STATUS','0')))
if 'up' in a:
 status=int(os.environ.get('UP_STATUS','0'))
 # A provider error that echoes its configuration; the recipe must redact the secret.
 if status: print(' '.join(values.values()))
 sys.exit(status)
if 'exec' in a:
 assert sys.stdin.read()==values['POSTGRES_PASSWORD']+'\\n'
 p=pathlib.Path(os.environ['EVENTS']+'.count'); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n))
 if os.environ.get('READY')=='hung': time.sleep(30)
 if any('ALTER ROLE postgres PASSWORD' in arg for arg in a):
  if os.environ.get('SYNC_STATUS'): sys.exit(int(os.environ['SYNC_STATUS']))
  pathlib.Path(os.environ['EVENTS']+'.synced').write_text('yes')
  sys.exit(0)
 if os.environ.get('AUTH_MISMATCH') and not pathlib.Path(os.environ['EVENTS']+'.synced').exists():
  print('FATAL: password authentication failed for user "postgres"')
  sys.exit(2)
 sys.exit(0 if n>=int(os.environ.get('READY','3')) else 1)
sys.exit(0)
''')
        stub.chmod(0o700)
        for name in ("podman", "docker", "sudo", "iex", "nc", "curl", "lsof", "netstat", "ss"):
            (tools / name).symlink_to(stub)
        env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'], EVENTS=str(events), BORG_ENV_FILE="", TMPDIR=str(temporary))
        for key in ('POSTGRES_PASSWORD','POSTGRES_PORT','BORG_DIST_COOKIE'):
            env.pop(key, None)
        for key in ('COMPOSE', 'CONTAINER', 'CLAUDE_CODE_OAUTH_TOKEN', 'ERL_EPMD_ADDRESS', 'BORG_NODE_NAME', 'BORG_NODE',
                    'LIVEBOOK_PORT', 'LIVEBOOK_IFRAME_PORT', 'LIVEBOOK_WAIT_SECONDS', 'LIVEBOOK_PROJECT'):
            env.pop(key, None)
        password = secrets.token_hex(24)
        cookie = secrets.token_hex(24)
        # Stub Livebook health endpoint: Livebook start cases never probe a real 127.0.0.1:8080.
        hits = []
        state = {'status': 200}

        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(state['status'] if self.path == '/public/health' else 404)
                self.send_header('Content-Length', '0')
                self.end_headers()

            def log_message(self, *_args):
                pass

        health = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Health)
        threading.Thread(target=health.serve_forever, daemon=True).start()
        health_port = health.server_address[1]
        with socket.socket() as first, socket.socket() as second:
            first.bind(('127.0.0.1', 0))
            second.bind(('127.0.0.1', 0))
            iframe_port, dead_port = first.getsockname()[1], second.getsockname()[1]
        lb = {'BORG_DIST_COOKIE': cookie, 'LIVEBOOK_PORT': str(health_port), 'LIVEBOOK_IFRAME_PORT': str(iframe_port),
              'LIVEBOOK_WAIT_SECONDS': '1'}
        owned_vars = ['DB_PROJECT=borg-owned-check', 'DB_WAIT_SECONDS=2']

        def check(name, target, extra=None, expected=True, predicate=lambda rows: True, output=lambda text: True,
                  make_vars=None, health_status=200):
            events.unlink(missing_ok=True)
            Path(str(events)+'.count').unlink(missing_ok=True)
            Path(str(events)+'.synced').unlink(missing_ok=True)
            hits.clear()
            state['status'] = health_status
            if make_vars is None:
                make_vars = ['DB_PROJECT=borg-owned-check', 'LIVEBOOK_PROJECT=borg-owned-check',
                             'DB_WAIT_SECONDS='+str((extra or {}).get('DB_WAIT_SECONDS','2'))]
            start=time.monotonic()
            result=subprocess.run(['make','--no-print-directory',target]+make_vars,cwd=fixture,env=dict(env,**(extra or {})),capture_output=True,timeout=12)
            rows=[json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
            text=(result.stdout+result.stderr).decode()
            good=(result.returncode==0)==expected and predicate(rows) and output(text) and time.monotonic()-start<10
            if not good: failures.append(name)
            print(('PASS ' if good else 'FAIL ')+name)
            assert password not in text and cookie not in text
            return rows

        check('missing password rejected before compose','db-start-dev',expected=False,predicate=lambda r:not r)
        valid={'POSTGRES_PASSWORD':password,'POSTGRES_PORT':'54321'}
        check('waits for authenticated readiness','db-start-dev',valid,
              predicate=lambda r: sum('exec' in x['args'] for x in r)>=3 and
              all(password not in json.dumps(x['args']) for x in r))
        check('repairs stale volume password','db-start-dev',dict(valid, READY='1', AUTH_MISMATCH='1'),
              predicate=lambda r: sum('ALTER ROLE postgres PASSWORD' in json.dumps(x['args']) for x in r)==1 and
              sum('SELECT 1' in json.dumps(x['args']) for x in r)==2 and
              all(password not in json.dumps(x['args']) for x in r),
              output=lambda text: 'Updated PostgreSQL password to match .env' in text)
        check('failed password repair is reported','db-start-dev',
              dict(valid, READY='1', AUTH_MISMATCH='1', SYNC_STATUS='7'), expected=False,
              output=lambda text: 'could not be updated' in text and 'PostgreSQL is ready' not in text)
        check('selected project honored','db-stop-dev',predicate=lambda r:bool(r) and all('borg-owned-check' in x['args'] for x in r))
        for key, invalid in [('POSTGRES_PASSWORD', ''), ('POSTGRES_PASSWORD', 'postgres'),
                             ('POSTGRES_PASSWORD', 'replace-with-password'), ('POSTGRES_PASSWORD', 'bad:password'),
                             ('POSTGRES_PORT', ''), ('POSTGRES_PORT', '5432'), ('POSTGRES_PORT', '0'),
                             ('POSTGRES_PORT', '65536'), ('POSTGRES_PORT', 'bad')]:
            check('invalid '+key+' rejected ('+('empty' if not invalid else 'nonempty')+')',
                  'db-start-dev', dict(valid, **{key: invalid}), expected=False, predicate=lambda r:not r)
        check('startup failure propagates', 'db-start-dev', dict(valid, UP_STATUS='7'), expected=False,
              predicate=lambda r: len(r)==1 and 'up' in r[0]['args'])
        check('never-ready deadline', 'db-start-dev', dict(valid, READY='99999'), expected=False,
              predicate=lambda r: any('logs' in row['args'] for row in r))
        check('hung probe deadline', 'db-start-dev', dict(valid, READY='hung'), expected=False,
              predicate=lambda r: any('logs' in row['args'] for row in r))
        check('invalid wait rejected before compose', 'db-start-dev', dict(valid, DB_WAIT_SECONDS='bad'), expected=False,
              predicate=lambda r:not r)
        compose_text = (ROOT / 'services/iex_livebook.yml').read_text()
        ports = re.search(r'^( *)ports:\n((?:\1 +- .*\n)+)', compose_text, re.M)
        entries = [line.strip()[2:] for line in ports[2].splitlines()] if ports else []
        good = ('attached:${BORG_NODE:?' in compose_text and '../docs/livebooks:/notebooks' in compose_text and
                len(entries) == 2 and all(entry.startswith("'127.0.0.1:") for entry in entries) and
                "LIVEBOOK_TOKEN_ENABLED: 'false'" in compose_text and
                'network_mode' not in compose_text and 'LIVEBOOK_PASSWORD' not in compose_text)
        if not good: failures.append('livebook compose is loopback-only, unauthenticated and mounts docs/livebooks')
        print(('PASS ' if good else 'FAIL ')+'livebook compose is loopback-only, unauthenticated and mounts docs/livebooks')
        livebook_file = ['-p','borg-owned-check','-f','services/iex_livebook.yml']
        livebook_teardown = {'BORG_NODE':'borg@host.containers.internal','BORG_DIST_COOKIE':'unused-teardown',
                             'LIVEBOOK_PORT':'8080','LIVEBOOK_IFRAME_PORT':'8081'}

        def project_args(row, project_and_file):
            args = row['args']
            return any(args[i:i+len(project_and_file)] == project_and_file for i in range(len(args)))

        def ups(rows):
            return [row for row in rows if 'up' in row['args']]

        def rejected(key):
            return lambda text: 'Missing or invalid '+key+' in environment or .env; see .env.example' in text

        for name, extra in [('missing', {k: v for k, v in lb.items() if k != 'BORG_DIST_COOKIE'}),
                            ('empty', dict(lb, BORG_DIST_COOKIE='')),
                            ('placeholder', dict(lb, BORG_DIST_COOKIE='replace-with-a-generated-private-cookie'))]:
            check('livebook '+name+' cookie rejected before compose', 'livebook-start-dev', extra, expected=False,
                  predicate=lambda r: not r, output=rejected('BORG_DIST_COOKIE'))
        lb_values = {'BORG_NODE':'borg@host.containers.internal','BORG_DIST_COOKIE':cookie,
                     'LIVEBOOK_PORT':str(health_port),'LIVEBOOK_IFRAME_PORT':str(iframe_port)}
        check('livebook start uses private env and waits for health', 'livebook-start-dev', lb,
              predicate=lambda r: len(r) == 2 and r[0]['args'][-1:] == ['build'] and r[1]['args'][-2:] == ['up','-d'] and
              all(project_args(row, livebook_file) for row in r) and r[1]['values'] == lb_values and
              all(cookie not in json.dumps(row['args']) for row in r) and '/public/health' in hits,
              output=lambda text: 'Livebook is ready: http://127.0.0.1:'+str(health_port) in text)
        check('livebook health must be 200', 'livebook-start-dev', lb, expected=False, health_status=503,
              predicate=lambda r: any('logs' in row['args'] for row in r) and '/public/health' in hits,
              output=lambda text: 'Livebook is ready' not in text)
        check('livebook never healthy', 'livebook-start-dev', dict(lb, LIVEBOOK_PORT=str(dead_port)), expected=False,
              predicate=lambda r: bool(ups(r)) and any('logs' in row['args'] for row in r),
              output=lambda text: 'Livebook is ready' not in text)
        check('livebook node override', 'livebook-start-dev', dict(lb, BORG_NODE_NAME='borg_two'),
              predicate=lambda r: ups(r)[0]['values']['BORG_NODE'] == 'borg_two@host.containers.internal')
        check('livebook caller shell cannot override env file', 'livebook-start-dev', dict(lb, BORG_NODE='wrong@x'),
              predicate=lambda r: ups(r)[0]['values'] == lb_values)
        for key, invalid in [('LIVEBOOK_PORT',''),('LIVEBOOK_PORT','0'),('LIVEBOOK_PORT','08080'),('LIVEBOOK_PORT','65536'),
                             ('LIVEBOOK_PORT','bad'),('LIVEBOOK_IFRAME_PORT',lb['LIVEBOOK_PORT'])]:
            check('invalid '+key+' rejected before compose ('+(invalid or 'empty')+')', 'livebook-start-dev',
                  dict(lb, **{key: invalid}), expected=False, predicate=lambda r: not r, output=rejected(key))
        check('invalid LIVEBOOK_WAIT_SECONDS rejected before compose', 'livebook-start-dev',
              dict(lb, LIVEBOOK_WAIT_SECONDS='bad'), expected=False, predicate=lambda r: not r)
        check('livebook build failure propagates', 'livebook-start-dev', dict(lb, BUILD_STATUS='7'), expected=False,
              predicate=lambda r: len(r) == 1 and 'build' in r[0]['args'])
        check('livebook startup failure propagates', 'livebook-start-dev', dict(lb, UP_STATUS='7'), expected=False,
              predicate=lambda r: len(ups(r)) == 1)
        check('invalid LIVEBOOK_PROJECT rejected', 'livebook-stop-dev', {'LIVEBOOK_PROJECT':'Bad Name'}, expected=False,
              predicate=lambda r: not r, make_vars=owned_vars, output=rejected('LIVEBOOK_PROJECT'))
        own = fixture / '.env'
        own.write_text('POSTGRES_PASSWORD='+password+'\nPOSTGRES_PORT=54322\nCLAUDE_CODE_OAUTH_TOKEN=literal-token\n'+'BORG_DIST_COOKIE='+cookie+'\n')
        own.chmod(0o600)
        discover_env = dict(env)
        env.pop('BORG_ENV_FILE')
        check('own file selected', 'db-start-dev', {'READY':'1'}, predicate=lambda r:r[0]['values']['POSTGRES_PORT']=='54322')
        direct = check('caller overrides file', 'db-start-dev', dict(valid, READY='1'), predicate=lambda r:r[0]['values']==valid)
        sudo = check('sudo effective values agree', 'db-start-dev', dict(valid, READY='1', COMPOSE='sudo podman compose'),
                     predicate=lambda r:r[0]['values']==valid)
        assert direct[0]['values']==sudo[0]['values']
        check('set-empty caller overrides file', 'db-start-dev', {'POSTGRES_PASSWORD':''}, expected=False, predicate=lambda r:not r)
        check('OAuth file exports to iex', 'iex-start-dev', predicate=lambda r:r[0]['oauth'] and r[0]['port']=='54322')
        expected_iex = ['--name','borg@host.containers.internal','--cookie',cookie,
                        '--erl','-kernel inet_dist_use_interface {127,0,0,1}','-S','mix','phx.server']
        check('iex uses node and cookie from .env', 'iex-start-dev',
              predicate=lambda r: r[0]['args']==expected_iex and r[0]['epmd']=='127.0.0.1')
        check('iex node name override', 'iex-start-dev', {'BORG_NODE_NAME':'borg_two'},
              predicate=lambda r: r[0]['args'][:2]==['--name','borg_two@host.containers.internal'])
        for key, invalid in [('BORG_DIST_COOKIE',''),('BORG_DIST_COOKIE','replace-with-a-generated-private-cookie'),
                             ('BORG_DIST_COOKIE','mysecretcookie'),('BORG_DIST_COOKIE','bad:cookie'),
                             ('BORG_NODE_NAME',''),('BORG_NODE_NAME','Borg'),('BORG_NODE_NAME','1borg'),
                             ('BORG_NODE_NAME','borg@x')]:
            check('invalid '+key+' rejected before iex ('+(invalid or 'empty')+')', 'iex-start-dev',
                  {key: invalid}, expected=False, predicate=lambda r: not r,
                  output=lambda text, key=key: 'Missing or invalid '+key+' in environment or .env; see .env.example' in text)
        own_text = own.read_text()
        own.write_text(own_text+'LIVEBOOK_PROJECT=borg-lb-two\n')
        check('livebook project from .env', 'livebook-stop-dev', make_vars=owned_vars,
              predicate=lambda r: bool(r) and all(project_args(row, ['-p','borg-lb-two']) for row in r))
        own.write_text(own_text)
        check('caller cookie never reaches compose env', 'db-start-dev', dict(valid, READY='1', BORG_DIST_COOKIE=cookie),
              predicate=lambda r: bool(r))
        main = base / 'main'
        metadata = main / '.git/worktrees/check'
        metadata.mkdir(parents=True)
        (metadata/'commondir').write_text('../..\n')
        (main/'.env').write_text('POSTGRES_PASSWORD='+password+'\nPOSTGRES_PORT=54323\n')
        (fixture/'.git').write_text('gitdir: ../main/.git/worktrees/check\n')
        check('own wins over main', 'db-start-dev', {'READY':'1'}, predicate=lambda r:r[0]['values']['POSTGRES_PORT']=='54322')
        own.unlink()
        check('relative main worktree fallback', 'db-start-dev', {'READY':'1'}, predicate=lambda r:r[0]['values']['POSTGRES_PORT']=='54323')
        check('explicit selected file', 'db-start-dev', {'READY':'1', 'BORG_ENV_FILE':str(main/'.env')}, predicate=lambda r:r[0]['values']['POSTGRES_PORT']=='54323')
        (main/'.env').write_text('POSTGRES_PASSWORD=$(touch forbidden)\n')
        check('unsupported literal cannot execute', 'db-start-dev', expected=False, predicate=lambda r:not r)
        assert not (fixture/'forbidden').exists()
        check('livebook stop with broken .env uses default and warns', 'livebook-stop-dev', make_vars=owned_vars,
              predicate=lambda r: bool(r) and all(project_args(row, ['-p','borg-livebook']) for row in r),
              output=lambda text: 'Could not read .env; using Livebook project borg-livebook' in text)
        own.mkdir()
        check('nonregular own file cannot fall back', 'db-start-dev',valid, expected=False,predicate=lambda r:not r)
        own.rmdir()
        for target in ['db-stop-dev','db-logs-dev','db-force-stop-dev']:
            for compose in ['podman compose','sudo podman compose']:
                check('teardown without usable file '+target+' '+compose,target,{'COMPOSE':compose},
                      predicate=lambda r:bool(r) and all('borg-owned-check' in x['args'] or
                                'borg-owned-check_postgres-network' in x['args'] for x in r))
        for target in ['livebook-stop-dev','livebook-logs-dev']:
            for compose in ['podman compose','sudo podman compose']:
                check('teardown without usable file '+target+' '+compose,target,{'COMPOSE':compose},
                      predicate=lambda r:bool(r) and all(project_args(x, livebook_file) and '--env-file' in x['args'] and
                                                         x['values'] == livebook_teardown for x in r))
        env = discover_env
        check('explicit empty disables file discovery','db-start-dev',expected=False,predicate=lambda r:not r)
        check('livebook stop without .env uses default', 'livebook-stop-dev', make_vars=owned_vars,
              predicate=lambda r: bool(r) and all(project_args(row, ['-p','borg-livebook']) for row in r),
              output=lambda text: 'Could not read .env' not in text)
        health.shutdown()
        health.server_close()
        env_init_checks(base, env, failures)
        assert not list(temporary.iterdir()), [path.name for path in temporary.iterdir()]
    if failures:
        raise AssertionError('make checks failed: '+', '.join(failures))


def env_init_checks(base, env, failures):
    """`make env-init` generates a missing or placeholder cookie and leaves a valid one alone."""
    secret = re.compile(r'[0-9a-f]{48}')
    password = secrets.token_hex(24)
    cookie = secrets.token_hex(24)
    valid_password = 'POSTGRES_PASSWORD='+password+'\n'

    def run(name, contents, predicate):
        directory = base / ('env-init-' + str(len(list(base.glob('env-init-*')))))
        directory.mkdir()
        shutil.copy2(ROOT / 'Makefile', directory)
        shutil.copy2(ROOT / '.env.example', directory)
        if contents is not None:
            (directory / '.env').write_text(contents)
        result = subprocess.run(['make','--no-print-directory','env-init'], cwd=directory, env=env, capture_output=True, timeout=10)
        text = (result.stdout+result.stderr).decode()
        after = (directory / '.env').read_text()
        lines = after.splitlines()
        cookies = [line.split('=',1)[1] for line in lines if line.startswith('BORG_DIST_COOKIE=')]
        good = result.returncode == 0 and predicate(contents, after, lines, cookies)
        good = good and not any(value in text for value in [password, cookie] + cookies)
        if not good: failures.append(name)
        print(('PASS ' if good else 'FAIL ')+name)

    def generated(cookies):
        return len(cookies) == 1 and secret.fullmatch(cookies[0]) is not None

    run('env-init creates both secrets', None,
        lambda _c, _a, lines, cookies: generated(cookies) and
        any(secret.fullmatch(line.split('=',1)[1]) for line in lines if line.startswith('POSTGRES_PASSWORD=')))
    run('env-init appends cookie on its own line', valid_password.rstrip('\n'),
        lambda _c, after, lines, cookies: generated(cookies) and lines[0] == valid_password.rstrip('\n') and
        after.startswith(valid_password))
    for invalid in ['replace-with-a-generated-private-cookie', 'cookie', 'bad:cookie', '"quoted"']:
        run('env-init replaces invalid cookie ('+invalid+')', valid_password+'BORG_DIST_COOKIE='+invalid+'\n',
            lambda _c, _a, _l, cookies: generated(cookies))
    run('env-init rewrites export placeholder once', valid_password+'export BORG_DIST_COOKIE=replace-me\n',
        lambda _c, after, _l, cookies: generated(cookies) and after.count('BORG_DIST_COOKIE=') == 1)
    run('env-init keeps valid cookie', valid_password+'BORG_DIST_COOKIE='+cookie+'\n',
        lambda contents, after, _l, _c: after == contents)


def postgres_checks():
    """Run runtime checks only against a randomly named, ownership-checked server."""
    import contextlib
    import errno
    import ipaddress
    import selectors
    import signal
    import socket
    import stat

    password = secrets.token_hex(24)
    project = 'borg-verify-' + secrets.token_hex(8)
    image = 'docker.io/library/postgres:18.4@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636'
    logs = []
    provider = shutil.which('podman') or shutil.which('docker')
    if not provider:
        raise RuntimeError('required container provider is unavailable')
    provider = str(Path(provider).resolve())
    clean_env = dict(os.environ)
    for key in ('POSTGRES_PASSWORD','POSTGRES_PORT','BORG_DIST_COOKIE','MIX_TEST_PARTITION','MIX_ENV','BORG_ENV_FILE','MIX_BUILD_PATH','MIX_DEPS_PATH'):
        clean_env.pop(key, None)
    clean_env['PODMAN_COMPOSE_WARNING_LOGS'] = 'false'

    def run(argv, cwd=ROOT, env=None, timeout=600, ok=True):
        proc = subprocess.Popen([str(arg) for arg in argv], cwd=cwd, env=env or clean_env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            output, _ = proc.communicate(timeout=timeout)
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise
        text = output.decode(errors='replace')
        logs.append(text)
        if password in text:
            raise AssertionError('secret detected in captured command output (withheld)')
        if ok and proc.returncode:
            # Do not expose command output or arguments on failure.
            raise RuntimeError('required command failed: '+Path(str(argv[0])).name+' (status '+str(proc.returncode)+'): '+text[-2000:])
        return proc.returncode, text

    def query(argv):
        return run([provider]+argv, timeout=30)[1]

    def ids():
        return query(['ps','-aq','--filter','label=com.docker.compose.project='+project]).split()

    def container_info(container):
        template = '{"Config":{"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}}},"Mounts":{{json .Mounts}},"NetworkSettings":{"Ports":{{json .NetworkSettings.Ports}}}}'
        return json.loads(query(['inspect','--format',template,container]))

    def ownership():
        owned = ids()
        for container in owned:
            item = container_info(container)
            assert item['Config']['Labels'].get('com.docker.compose.project') == project
        for volume in query(['volume','ls','-q','--filter','label=com.docker.compose.project='+project]).split():
            item = json.loads(query(['volume','inspect',volume]))[0]
            assert item['Labels'].get('com.docker.compose.project') == project
        for network in query(['network','ls','-q','--filter','label=com.docker.compose.project='+project]).split():
            item = json.loads(query(['network','inspect',network]))[0]
            assert item.get('Labels',item.get('labels',{})).get('com.docker.compose.project') == project
        return owned

    with tempfile.TemporaryDirectory(prefix='borg-postgres-') as directory:
        private = Path(directory)
        private.chmod(0o700)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0))
            port = reservation.getsockname()[1]
        assert port != 5432
        effective = private / 'generated.env'
        effective.write_text('POSTGRES_PASSWORD='+password+'\nPOSTGRES_PORT='+str(port)+'\n')
        effective.chmod(0o600)
        guard = private / 'compose-guard'
        guard.write_text('#!'+sys.executable+'\n'+
                         'import os,sys\na=sys.argv[1:]\n'+
                         'assert "-p" in a and a[a.index("-p")+1]=='+repr(project)+'\n'+
                         'assert "-f" in a and a[a.index("-f")+1]=="services/dev_database.yml"\n'+
                         'assert "--env-file" in a\n'+
                         'assert any(x in a for x in ("up","exec","logs","down"))\n'+
                         'os.execv('+repr(provider)+',['+repr(provider)+',"compose"]+a)\n')
        guard.chmod(0o700)
        compose = [str(guard),'--env-file',str(effective),'-p',project,'-f','services/dev_database.yml']
        launched = False
        cleanup_error = None
        primary_error = None
        try:
            query(['version','--format','json'])
            run([provider,'compose','version'], timeout=30)
            assert not ownership(), 'owned project unexpectedly exists before startup'
            # Every mutation passes through the exact-project guard, even recipes under test.
            env = dict(clean_env, POSTGRES_PASSWORD=password, POSTGRES_PORT=str(port), BORG_ENV_FILE='', DB_WAIT_SECONDS='90')
            launched = True
            run(['make','--no-print-directory','db-start-dev','COMPOSE='+str(guard),'DB_PROJECT='+project],env=env,timeout=150)
            containers = query(['ps','-aq','--filter','label=com.docker.compose.project='+project,
                                '--filter','label=com.docker.compose.service=dev-database']).split()
            assert len(containers)==1, 'expected exactly one owned database container'
            container = containers[0]
            item = container_info(container)
            labels = item['Config']['Labels']
            assert labels['com.docker.compose.project']==project
            assert labels['com.docker.compose.service']=='dev-database'
            assert item['Config']['Image'] in (image,image.replace(':18.4@','@'))
            mounts = [mount for mount in item['Mounts'] if mount['Destination']=='/var/lib/postgresql']
            assert len(mounts)==1 and mounts[0]['Type']=='volume'
            volume = mounts[0]['Name']
            assert volume==project+'_postgres18_data'
            assert not any(m['Destination']=='/var/lib/postgresql/data' for m in item['Mounts'])
            volume_info=json.loads(query(['volume','inspect',volume]))[0]
            assert volume_info['Labels']['com.docker.compose.project']==project
            bindings=item['NetworkSettings']['Ports']['5432/tcp']
            assert bindings and all(b['HostIp']=='127.0.0.1' and int(b['HostPort'])==port for b in bindings)
            run(compose+['exec','-T','dev-database','pg_isready','-q','-h','127.0.0.1','-U','postgres','-d','borg_dev'],timeout=10)
            print('PASS owned PG18 image, fresh mount, project/service labels, loopback publish and readiness')

            with socket.create_connection(('127.0.0.1',port),timeout=3): pass
            if sys.platform=='darwin':
                _, rows=run(['lsof','-nP','-iTCP:'+str(port),'-sTCP:LISTEN','-Fn'],timeout=10)
                addresses=[line[1:] for line in rows.splitlines() if line.startswith('n')]
                assert addresses and all(a=='127.0.0.1:'+str(port) for a in addresses)
                lan=None
                for interface in ('en0','en1'):
                    code, output=run(['ipconfig','getifaddr',interface],timeout=5,ok=False)
                    if code==0 and output.strip():
                        lan=output.strip(); break
            else:
                _, rows=run(['ss','-H','-ltn'],timeout=10)
                addresses=[line.split()[3] for line in rows.splitlines() if len(line.split())>=4 and line.split()[3].endswith(':'+str(port))]
                assert addresses and all(a=='127.0.0.1:'+str(port) for a in addresses)
                with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as route:
                    route.connect(('198.51.100.1',9)); lan=route.getsockname()[0]
            assert lan and not ipaddress.ip_address(lan).is_loopback, 'required host LAN IP unavailable'
            # A child listener proves that self-LAN access is permitted in this environment.
            with socket.socket() as reserve:
                reserve.bind((lan,0)); control_port=reserve.getsockname()[1]
            control=subprocess.Popen([sys.executable,'-u','-c',
                'import socket,sys; s=socket.socket(); s.bind((sys.argv[1],int(sys.argv[2]))); s.listen(); print("ready",flush=True); sys.stdin.read()',lan,str(control_port)],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(control.stdout,selectors.EVENT_READ)
                    assert selector.select(5), 'positive control listener did not start'
                    assert control.stdout.readline()==b'ready\n'
                with socket.create_connection((lan,control_port),timeout=2): pass
                try:
                    connection=socket.create_connection((lan,port),timeout=2)
                except OSError as error:
                    assert error.errno in (errno.ECONNREFUSED,errno.ETIMEDOUT) or isinstance(error,TimeoutError), 'LAN probe did not establish refusal'
                else:
                    connection.close()
                    raise AssertionError('database is reachable through LAN IP')
            finally:
                control.terminate()
                try: control.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    control.kill(); control.communicate(timeout=5)
            print('PASS identified listener rows, loopback access and LAN refusal after positive control')

            # Snapshot current source, including nonignored new files, without local settings.
            snapshot=private/'source'
            snapshot.mkdir()
            def refresh_source():
                _, listing=run(['git','ls-files','--cached','--others','--exclude-standard','-z'],timeout=30)
                for name in listing.split('\0'):
                    if not name: continue
                    relative=Path(name)
                    if any(part in ('.git','deps','_build','.aws') or part=='.env' or part.endswith('.env') for part in relative.parts): continue
                    if 'credential' in relative.name.lower() or relative.name.endswith(('.pem','.key')): continue
                    source=ROOT/relative
                    if source.is_file():
                        target=snapshot/relative
                        target.parent.mkdir(parents=True,exist_ok=True)
                        shutil.copy2(source,target,follow_symlinks=True)
            refresh_source()
            shutil.copytree(ROOT/'deps',snapshot/'deps',symlinks=False)
            # Build stays private; dependency files are copied, never hardlinked.
            run(['mix','compile','--warnings-as-errors'],cwd=snapshot,timeout=600)
            print('PASS secret-free dev compilation with private build output')
            fixture=private/'runtime-fixture'
            (fixture/'config').mkdir(parents=True)
            shutil.copy2(ROOT/'config/runtime.exs',fixture/'config/runtime.exs')
            paths=[]
            for ebin in (ROOT/'_build/dev/lib').glob('*/ebin'):
                paths+=['-pa',str(ebin)]

            def runtime_case(root, mode, expectation, overrides=None):
                static='c=Config.Reader.read!("config/config.exs",env: :'+mode+'); ' if root==ROOT or root==snapshot else ''
                expression=static+'try do\n c=Config.Reader.read!("config/runtime.exs",env: :'+mode+'); r=c[:borg][Borg.Repo]; '+expectation+'\nrescue e -> if System.get_env("EXPECT_ERROR")=="1", do: IO.puts("EXPECTED_ERROR:"<>Exception.message(e)), else: reraise(e,__STACKTRACE__) end'
                case_env=dict(clean_env,**(overrides or {}))
                return run(['elixir']+paths+['-e',expression],cwd=root,env=case_env,timeout=30)[1]

            default=runtime_case(fixture,'test','true = r[:password]=="postgres" and r[:port]==5432; IO.puts("CI_DEFAULTS")')
            assert 'CI_DEFAULTS' in default
            def error_case(mode, overrides=None):
                output=runtime_case(fixture,mode,'raise "unexpected successful configuration"',dict(overrides or {},EXPECT_ERROR='1'))
                assert 'EXPECTED_ERROR:' in output and '.env' in output and 'unexpected successful configuration' not in output
                return output
            assert 'POSTGRES_PASSWORD, POSTGRES_PORT' in error_case('dev')
            env_file=fixture/'.env'
            for contents in ('','POSTGRES_PASSWORD='+password+'\n','POSTGRES_PORT='+str(port)+'\n','unsupported secret-free line'):
                env_file.write_text(contents); env_file.chmod(0o600); error_case('test')
            env_file.unlink()
            error_case('test',{'POSTGRES_PORT':str(port)})
            print('PASS actual runtime Config.Reader defaults and fail-closed configuration cases without Repo startup')
            generated=snapshot/'.env'
            generated.write_text(effective.read_text()); generated.chmod(0o600)
            expectation='true = r[:port]=='+str(port)+'; true = r[:password]==System.get_env("EXPECTED_PASSWORD"); IO.puts("OWNED_CONFIG")'
            for checkout, overrides in [(snapshot,{'EXPECTED_PASSWORD':password}), (ROOT,dict(env,EXPECTED_PASSWORD=password))]:
                output=runtime_case(checkout,'test',expectation,overrides)
                assert 'OWNED_CONFIG' in output
                _, static=run(['elixir']+paths+['-e','c=Config.Reader.read!("config/config.exs",env: :test); true=c[:borg][Borg.Repo][:hostname]=="127.0.0.1"; IO.puts("HOST_OK")'],cwd=checkout,timeout=30)
                assert 'HOST_OK' in static
            print('PASS root and file-driven snapshot Repo host/port resolve to the owned server')
            _, existing=run(compose+['exec','-T','dev-database','psql','-U','postgres','-d','postgres','-tAc',"SELECT datname FROM pg_database WHERE datname='borg_test'"],timeout=10)
            assert not existing.strip(), 'fresh server unexpectedly has borg_test'
            # Only now may any Ecto command execute. Bare Mix uses snapshot/.env.
            run(['mix','test'],cwd=snapshot,timeout=600)
            _, exists_test=run(compose+['exec','-T','dev-database','psql','-U','postgres','-d','postgres','-tAc',"SELECT datname FROM pg_database WHERE datname='borg_test'"],timeout=10)
            assert exists_test.strip()=='borg_test'
            print('PASS bare snapshot mix test creates borg_test in the owned server')
            targets=['test/borg/dot_env_test.exs','test/borg/coding/shell/muon_trap_test.exs','test/borg/coding/shell_sessions/program_test.exs']
            run(['mix','test']+targets,env=env,timeout=600)
            before={p:(ROOT/p).read_bytes() for p in ['lib/borg/dot_env.ex','config/runtime.exs']+targets}
            run(['mix','precommit'],env=env,timeout=600)
            if any((ROOT/p).read_bytes()!=contents for p,contents in before.items()):
                refresh_source()
                run(['mix','test']+targets,cwd=snapshot,timeout=600)
            run(['mix','test'],env=env,timeout=600)
            run(['make','quality'],env=env,timeout=1200)
            print('PASS root targeted tests, mix precommit, mix test, make quality')
        except BaseException as error:
            primary_error=error
        finally:
            if launched:
                try:
                    ownership()
                    run(compose+['down','-v','--remove-orphans'],timeout=60)
                    assert not ownership()
                    assert not query(['volume','ls','-q','--filter','label=com.docker.compose.project='+project]).strip()
                    assert not query(['network','ls','-q','--filter','label=com.docker.compose.project='+project]).strip()
                except BaseException as error:
                    cleanup_error=error
            assert all(password not in entry for entry in logs), 'captured secret audit failed'
            if cleanup_error:
                raise RuntimeError('owned-resource cleanup failed; inspect project '+project+'; cleanup: '+str(cleanup_error)+'; original: '+str(primary_error)) from None
        if primary_error:
            raise primary_error
        print('PASS owned resources removed and captured logs audited for generated secrets')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['make','postgres'])
    args=parser.parse_args()
    if args.mode=='make': make_checks()
    else: postgres_checks()

if __name__=='__main__':
    try: main()
    except (AssertionError,RuntimeError,subprocess.SubprocessError,OSError) as error:
        print('FAIL: '+str(error),file=sys.stderr)
        sys.exit(1)

