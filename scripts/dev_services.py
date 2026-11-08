#!/usr/bin/env python3
"""Literal local configuration and bounded development service commands.

No shell evaluates file values. The child environment is assembled explicitly,
so a caller's present (even empty) environment always wins over file values.
"""
import argparse
import contextlib
import http.client
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

PROTECTED = ('POSTGRES_PASSWORD', 'POSTGRES_PORT', 'BORG_DIST_COOKIE')
DIST_HOST = 'host.containers.internal'


class ConfigurationError(Exception):
    """Safe diagnostic, never includes local configuration values."""


def regular_text(path, description='.env'):
    try:
        info = path.stat()
        if not stat.S_ISREG(info.st_mode):
            raise ConfigurationError(description + ' must be a regular file; see .env.example')
        if not info.st_mode & 0o444:
            raise OSError('no read permissions')
        return path.read_text()
    except (OSError, UnicodeError):
        raise ConfigurationError(description + ' is unreadable; see .env.example') from None


def exists(path):
    try:
        path.stat()
        return True
    except FileNotFoundError:
        # A dangling symlink is a selected, invalid file, not absence.
        return path.is_symlink()
    except OSError:
        raise ConfigurationError('.env discovery failed: unreadable path') from None


def discover(root):
    own = root / '.env'
    if exists(own):
        return own
    git = root / '.git'
    if not exists(git) or git.is_dir():
        return None
    pointer = regular_text(git, 'Git worktree metadata')
    match = re.fullmatch(r'gitdir: ([^\r\n]+)\r?\n?', pointer)
    if not match:
        raise ConfigurationError('.env discovery failed: invalid Git worktree metadata')
    gitdir = (root / match[1]).resolve()
    common = regular_text(gitdir / 'commondir', 'Git worktree metadata').strip()
    common_path = (gitdir / common).resolve()
    if not common or any(c in common for c in '\r\n\0') or common_path.name != '.git' or not common_path.is_dir():
        raise ConfigurationError('.env discovery failed: invalid Git worktree metadata')
    main = common_path.parent / '.env'
    return main if exists(main) else None


def parse_file(path):
    values = {}
    for line in regular_text(path).split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        match = re.fullmatch(r'(?:export[\t ]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)', line)
        if not match:
            raise ConfigurationError('.env has unsupported literal syntax; see .env.example')
        key, value = match.groups()
        if value.startswith(('"', "'")):
            quote = value[0]
            # Whole-value quotes; a trailing whitespace comment is permitted.
            quoted = re.fullmatch(re.escape(quote) + '([^' + re.escape(quote) + ']*)' + re.escape(quote) + r'(?:[\t ]+#.*)?', value)
            if not quoted:
                raise ConfigurationError('.env has unsupported literal syntax; see .env.example')
            value = quoted[1]
        else:
            value = re.sub(r'[\t ]+#.*$', '', value).rstrip()
            if any(c in value for c in " \t'\"\\"):
                raise ConfigurationError('.env has unsupported literal syntax; see .env.example')
        if any(c in value for c in '$`\0\r'):
            raise ConfigurationError('.env has unsupported literal syntax; see .env.example')
        values[key] = value
    return values


def environment(root):
    if 'BORG_ENV_FILE' in os.environ:
        selected = Path(os.environ['BORG_ENV_FILE']) if os.environ['BORG_ENV_FILE'] else None
    else:
        selected = discover(root)
    values = parse_file(selected) if selected else {}
    values.update(os.environ)
    return values


def validate_postgres(values):
    password = values.get('POSTGRES_PASSWORD', '')
    port = values.get('POSTGRES_PORT', '')
    invalid = []
    if (not re.fullmatch(r'[A-Za-z0-9_-]+', password) or
            password.lower().startswith(('replace', 'change', 'your-')) or
            password.lower() in ('postgres', 'password', 'secret', 'placeholder')):
        invalid.append('POSTGRES_PASSWORD')
    if not re.fullmatch(r'[0-9]+', port) or not 1 <= int(port) <= 65535 or int(port) == 5432:
        invalid.append('POSTGRES_PORT')
    if invalid:
        raise ConfigurationError('Missing or invalid ' + ', '.join(invalid) + ' in environment or .env; see .env.example')


COOKIE_PLACEHOLDERS = ('mysecretcookie', 'cookie', 'secret', 'placeholder')


def validate_dist(values):
    """Return the distribution node name and cookie shared by `make iex` and Livebook."""
    cookie = values.get('BORG_DIST_COOKIE', '')
    name = values.get('BORG_NODE_NAME', 'domovoy')
    invalid = []
    # The cookie must never contain ':', Livebook splits its runtime setting on the last colon.
    if (not re.fullmatch(r'[A-Za-z0-9_-]+', cookie) or
            cookie.lower().startswith(('replace', 'change', 'your-')) or
            cookie.lower() in COOKIE_PLACEHOLDERS):
        invalid.append('BORG_DIST_COOKIE')
    if not re.fullmatch(r'[a-z][a-z0-9_]*', name):
        invalid.append('BORG_NODE_NAME')
    if invalid:
        raise ConfigurationError('Missing or invalid ' + ', '.join(invalid) + ' in environment or .env; see .env.example')
    return name + '@' + DIST_HOST, cookie


def bounded(argv, env, timeout, capture=False, input=None):
    """Own process-group watchdog; kills and reaps descendants on deadline/signals."""
    process = subprocess.Popen(argv, env=env, start_new_session=True,
                               stdin=subprocess.PIPE if input is not None else None,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        output, _ = process.communicate(input=input, timeout=max(0.01, timeout))
        return process.returncode, output
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise


def postgres_values(values):
    validate_postgres(values)
    return {key: values[key] for key in ('POSTGRES_PASSWORD', 'POSTGRES_PORT')}


def postgres_ready(run, values, remaining):
    # The image may trust its loopback interface. Use its bridge address so
    # PostgreSQL checks the same password that outside clients must provide.
    probe = ['exec', '-T', 'dev-database', 'sh', '-c',
             'IFS= read -r PGPASSWORD; export PGPASSWORD; set -- $(hostname -i); '
             'exec psql -h "$1" -U postgres -d domovoy_dev -Atqc "SELECT 1"']
    password = (values['POSTGRES_PASSWORD'] + '\n').encode()
    code, output = run(probe, min(5, remaining), input=password)
    if code == 0:
        return True
    if b'password authentication failed' not in output:
        return False

    # The volume can retain an older password after .env changes. The official
    # Postgres image permits its OS postgres user to connect over a local socket.
    # Keep the selected password in SQL stdin, never in process arguments.
    sync = ['exec', '-T', '-u', 'postgres', 'dev-database', 'sh', '-c',
            'IFS= read -r POSTGRES_PASSWORD; '
            'printf "ALTER ROLE postgres PASSWORD \'%s\';\\n" "$POSTGRES_PASSWORD" | '
            'psql -U postgres -d postgres -q -v ON_ERROR_STOP=1']
    sync_code, _ = run(sync, min(5, remaining), input=password)
    if sync_code:
        raise ConfigurationError('PostgreSQL password differs from .env and could not be updated; '
                                 'check the database container and its volume')
    code, _ = run(probe, min(5, remaining), input=password)
    if code:
        raise ConfigurationError('PostgreSQL password update did not restore access; '
                                 'check the database container and its volume')
    print('Updated PostgreSQL password to match .env')
    return True


def livebook_values(values):
    node, cookie = validate_dist(values)
    ports = {key: values.get(key, default) for key, default in (('LIVEBOOK_PORT', '8080'), ('LIVEBOOK_IFRAME_PORT', '8081'))}
    invalid = [key for key, value in ports.items() if not re.fullmatch(r'[1-9][0-9]{0,4}', value) or int(value) > 65535]
    if not invalid and int(ports['LIVEBOOK_PORT']) == int(ports['LIVEBOOK_IFRAME_PORT']):
        invalid = ['LIVEBOOK_IFRAME_PORT']
    if invalid:
        raise ConfigurationError('Missing or invalid ' + ', '.join(invalid) + ' in environment or .env; see .env.example')
    return dict(BORG_NODE=node, BORG_DIST_COOKIE=cookie, **ports)


def livebook_ready(run, values, remaining):
    # http.client ignores proxy settings; a published port accepts TCP before Livebook is up.
    connection = http.client.HTTPConnection('127.0.0.1', int(values['LIVEBOOK_PORT']), timeout=max(0.1, min(2, remaining)))
    try:
        connection.request('GET', '/public/health')
        return connection.getresponse().status == 200
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


SERVICES = {
    'database': {
        'file': 'services/dev_database.yml',
        'values': postgres_values,
        'teardown': {'POSTGRES_PASSWORD': 'unused-teardown', 'POSTGRES_PORT': '54321'},
        'secret': 'POSTGRES_PASSWORD',
        'wait': ('DB_WAIT_SECONDS', '60'),
        'build': False,
        'ready': postgres_ready,
        'ready_message': lambda values: 'PostgreSQL is ready on 127.0.0.1:' + values['POSTGRES_PORT'],
        'logs_service': 'dev-database',
        'network': '_postgres-network',
        'label': 'PostgreSQL',
    },
    'livebook': {
        'file': 'services/iex_livebook.yml',
        'values': livebook_values,
        'teardown': {'BORG_NODE': 'borg@' + DIST_HOST, 'BORG_DIST_COOKIE': 'unused-teardown',
                     'LIVEBOOK_PORT': '8080', 'LIVEBOOK_IFRAME_PORT': '8081'},
        'secret': 'BORG_DIST_COOKIE',
        'wait': ('LIVEBOOK_WAIT_SECONDS', '120'),
        'build': True,
        'ready': livebook_ready,
        'ready_message': lambda values: ('Livebook is ready: http://127.0.0.1:' + values['LIVEBOOK_PORT'] +
                                         ' (new notebooks attach to ' + values['BORG_NODE'] + ')'),
        'logs_service': 'livebook',
        'network': None,
        'label': 'Livebook',
    },
}


def service(args, root, spec):
    teardown = args.action in ('stop', 'logs', 'force-stop')
    effective = dict(spec['teardown']) if teardown else spec['values'](environment(root))
    wait_var, wait_default = spec['wait']
    wait = os.environ.get(wait_var, wait_default)
    if not re.fullmatch(r'[0-9]+', wait):
        raise ConfigurationError(wait_var + ' must be a nonnegative integer')
    # Compose's process env beats --env-file for interpolation: unset every key the file sets.
    unset = list(dict.fromkeys(PROTECTED + tuple(effective)))
    child_env = dict(os.environ)
    for key in unset:
        child_env.pop(key, None)
    with tempfile.TemporaryDirectory(prefix='domovoy-compose-') as private:
        env_file = Path(private) / 'effective.env'
        descriptor = os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            for key, value in effective.items():
                stream.write(key + '=' + value + '\n')
        command = ['env'] + [arg for key in unset for arg in ('-u', key)]
        command += shlex.split(args.compose) + ['--env-file', str(env_file), '-p', args.project, '-f', spec['file']]

        def run(tail, timeout=60, input=None):
            return bounded(command + tail, child_env, timeout, input=input)

        def emit(output):
            text = output.decode(errors='replace')
            # Provider failures/logs must not accidentally reveal the effective secret.
            print(text.replace(effective[spec['secret']], '[REDACTED]'), end='')

        if teardown:
            tail = ['logs', '-f'] if args.action == 'logs' else ['down']
            if args.action == 'force-stop':
                tail += ['--remove-orphans']
            if args.action == 'logs':
                # Follow logs until interrupted; Python still owns env-file cleanup.
                result = subprocess.call(command + tail, env=child_env)
            else:
                result, output = run(tail)
                emit(output)
            if args.action == 'force-stop' and spec['network']:
                code, output = bounded(shlex.split(args.container) + ['network', 'rm', args.project + spec['network']], child_env, 15)
                emit(output)
                result = result or code
            return result
        if spec['build']:
            print('Building the ' + spec['label'] + ' image (the first run takes several minutes)…', flush=True)
            # Streamed and unbounded like logs; the Dockerfile takes no build args, so no secrets.
            result = subprocess.call(command + ['build'], env=child_env)
            if result:
                return result
        result, output = run(['up', '-d'])
        emit(output)
        if result:
            return result
        deadline = time.monotonic() + int(wait)
        while time.monotonic() < deadline:
            try:
                if spec['ready'](run, effective, deadline - time.monotonic()):
                    print(spec['ready_message'](effective))
                    return 0
            except subprocess.TimeoutExpired:
                pass
            time.sleep(min(0.2, max(0, deadline-time.monotonic())))
        print(spec['label'] + ' readiness timeout (' + wait_var + '); recent service logs:', file=sys.stderr)
        try:
            _, output = run(['logs', '--tail', '30', spec['logs_service']], 3)
            emit(output)
        except subprocess.TimeoutExpired:
            print(spec['label'] + ' log retrieval timed out', file=sys.stderr)
        return 1


LIVEBOOK_PROJECT = 'domovoy-livebook'


def livebook_project(args, root):
    """An explicit --project wins; otherwise LIVEBOOK_PROJECT from the env or .env, else the default."""
    project = args.project
    if not project:
        try:
            project = environment(root).get('LIVEBOOK_PROJECT', LIVEBOOK_PROJECT)
        except ConfigurationError:
            if args.action == 'start':
                raise
            project = LIVEBOOK_PROJECT
            print('Could not read .env; using Livebook project ' + LIVEBOOK_PROJECT +
                  ' (pass LIVEBOOK_PROJECT=<name> to make to choose another)', file=sys.stderr)
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', project):
        raise ConfigurationError('Missing or invalid LIVEBOOK_PROJECT in environment or .env; see .env.example')
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'stop', 'logs', 'force-stop', 'iex', 'ping'])
    parser.add_argument('--compose', default='podman compose')
    parser.add_argument('--container', default='podman')
    parser.add_argument('--service', choices=sorted(SERVICES), default='database')
    parser.add_argument('--project', default='')
    args = parser.parse_args()
    root = Path.cwd()
    if args.action in ('iex', 'ping'):
        values = environment(root)
        validate_postgres(values)
        if args.action == 'iex':
            node, cookie = validate_dist(values)
            values['MIX_ENV'] = 'dev'
            # Effective only if this node starts EPMD; an EPMD started earlier keeps its binding.
            values.setdefault('ERL_EPMD_ADDRESS', '127.0.0.1')
            os.execvpe('iex', ['iex', '--name', node, '--cookie', cookie,
                               '--erl', '-kernel inet_dist_use_interface {127,0,0,1}',
                               '-S', 'mix', 'phx.server'], values)
        with socket.create_connection(('127.0.0.1', int(values['POSTGRES_PORT'])), timeout=2):
            print('PostgreSQL (127.0.0.1:' + values['POSTGRES_PORT'] + ') UP')
        return 0
    args.project = livebook_project(args, root) if args.service == 'livebook' else args.project or 'domovoy-dev-db'
    return service(args, root, SERVICES[args.service])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ConfigurationError, OSError, subprocess.SubprocessError) as error:
        # Subprocess exceptions can contain argv: emit only our safe errors.
        print(str(error) if isinstance(error, ConfigurationError) else 'Development service command failed', file=sys.stderr)
        sys.exit(1)

