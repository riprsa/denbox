"""Tests of install.sh with a fake container CLI, on a real terminal where it asks.

    python3 -m unittest discover -s deploy/tests

The fake CLI, as docker and as podman, logs every call and plays the image:
its git reads the repository anonymously when FAKE_PUBLIC is set, and
otherwise only with the token TOKEN handed over on standard input; its
`denbox host` prints the declaration in state/host.json; everything else it
runs is the real deploy/render. A fake systemctl plays the user's systemd.
Neither TOKEN nor the secret KEY may reach a command line or the
environment of the CLI.
"""
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOKEN = 'fixture-secret-token'
KEY = 'fixture-api-key'
REPOSITORY = 'https://git.example.com/me/environment.git'
DEFAULT = json.loads((ROOT / 'deploy/tests/render/default.json').read_text())
API_KEY = {'api_key': {'target': '/run/secrets/denbox_api_key', 'allowEmpty': False,
                       'description': 'Key of the example API'}}
LOGIN = {'login': {'target': '/run/secrets/denbox_login', 'allowEmpty': True,
                   'description': 'Login key; empty to log in by hand'}}

CLI = r'''
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
state = pathlib.Path(os.environ['FAKE_STATE'])
secrets = (os.environ['FAKE_SECRET'], os.environ['FAKE_KEY'])
event = {'cli': pathlib.Path(sys.argv[0]).name, 'args': args,
         'token_in_env': any(s in v for k, v in os.environ.items() if not k.startswith('FAKE_') for s in secrets)}
status = 0
if args[:2] == ['volume', 'inspect']:
    status = 0 if (state / ('volume-' + args[2])).exists() else 1
elif args[:2] == ['volume', 'create']:
    (state / ('volume-' + args[2])).touch()
elif args[0] == 'volume':
    status = 99
elif args[0] == 'run':
    script = args[args.index('-c') + 1]
    rest = args[args.index('-c') + 2:]
    event['mounts'] = [args[i + 1] for i, a in enumerate(args) if a == '-v']
    if 'git ls-remote' in script:
        event['token_handed'] = sys.stdin.read().strip() == os.environ['FAKE_SECRET']
        if os.environ.get('FAKE_NO_BRANCH'): status = 2
        elif os.environ.get('FAKE_PUBLIC') or event['token_handed']: status = 0
        else: status = 128
    elif 'runtime/denbox host' in script:
        bootstrap, _, handed = sys.stdin.read().partition('\n')
        event['evaluated'] = json.loads(bootstrap)
        event['token_handed'] = handed.strip() == os.environ['FAKE_SECRET']
        sys.stdout.write((state / 'host.json').read_text())
    else:
        script = script.replace('/usr/local/share/denbox/render', os.environ['FAKE_RENDER'])
        # Its temporary files stay in the container.
        status = subprocess.run(['bash', '-c', script, *rest], env=dict(os.environ, TMPDIR=str(state))).returncode
elif args[0] == 'compose' and 'up' in args:
    directory = pathlib.Path(args[args.index('--project-directory') + 1])
    event['files'] = {str(p.relative_to(directory)): oct(p.stat().st_mode & 0o777) for p in directory.rglob('*')}
    event['bootstrap'] = json.loads((directory / 'bootstrap.json').read_text())
    event['env'] = (directory / '.env').read_text().splitlines()
    event['compose'] = (directory / 'compose.yaml').read_text()
    event['token_file'] = (directory / 'git_token').read_text().strip() == os.environ['FAKE_SECRET']
    event['secrets'] = {p.name: p.read_text() for p in (directory / 'secrets').iterdir()}
with open(state / 'calls', 'a') as log:
    log.write(json.dumps(event) + '\n')
sys.exit(status)
'''

SYSTEMCTL = r'''
import json, os, pathlib, sys
state = pathlib.Path(os.environ['FAKE_STATE'])
event = {'cli': 'systemctl', 'args': sys.argv[1:], 'token_in_env': False}
if 'restart' in sys.argv:
    units = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'containers/systemd'
    event['units'] = {p.name: p.read_text() for p in units.iterdir()}
with open(state / 'calls', 'a') as log:
    log.write(json.dumps(event) + '\n')
'''


class Installer(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.root)])
        for directory in ('bin', 'state', 'temporary', 'config'):
            (self.root / directory).mkdir()
        for name, program in (('docker', CLI), ('podman', CLI), ('systemctl', SYSTEMCTL)):
            path = self.root / 'bin' / name
            path.write_text('#!' + sys.executable + '\n' + program)
            path.chmod(0o755)
        self.dir = self.root / 'box'
        self.declare()
        self.env = dict(os.environ, PATH=f'{self.root}/bin:{os.environ["PATH"]}', FAKE_STATE=str(self.root / 'state'),
                        FAKE_SECRET=TOKEN, FAKE_KEY=KEY, FAKE_RENDER=str(ROOT / 'deploy/render'),
                        TMPDIR=str(self.root / 'temporary'), XDG_CONFIG_HOME=str(self.root / 'config'))
        for name in list(self.env):
            if name.startswith('DENBOX_'):
                del self.env[name]

    def declare(self, **changes):
        """Makes the environment's box ask for the defaults with changes."""
        (self.root / 'state/host.json').write_text(json.dumps(dict(DEFAULT, **changes)))

    def calls(self):
        log = self.root / 'state/calls'
        events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        for event in events:
            for secret in (TOKEN, KEY):
                self.assertNotIn(secret, json.dumps(event['args']), 'a secret is in a command line')
            self.assertFalse(event['token_in_env'], 'a secret is in the environment of the container CLI')
        return events

    def up(self):
        return [e for e in self.calls() if e['args'][0] == 'compose' and 'up' in e['args']]

    def started(self):
        """Every start of a box: compose up or a restart of the user service."""
        return [e for e in self.calls() if (e['args'][0] == 'compose' and 'up' in e['args']) or 'restart' in e['args']]

    def unattended(self, *args, **env):
        """Runs the installer without a terminal; returns its exit code and output."""
        result = subprocess.run(['bash', str(ROOT / 'install.sh'), *args], env=dict(self.env, **env),
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                start_new_session=True, timeout=60)
        self.assertEqual(list((self.root / 'temporary').iterdir()), [], 'temporary files survived')
        return result.returncode, result.stdout + result.stderr

    def install(self, *args, **env):
        """An unattended install of the box main into self.dir that must succeed."""
        code, output = self.unattended('--repository', REPOSITORY, '--box', 'main', '--dir', str(self.dir), *args, **env)
        self.assertEqual(code, 0, output)
        return output

    def interactive(self, answers, *args, **env):
        """Runs the installer on a terminal, answering each prompt that
        contains a key of answers; returns its exit code and output."""
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execvpe('bash', ['bash', str(ROOT / 'install.sh'), *args], dict(self.env, **env))
        output, answered, status = b'', set(), None
        deadline = time.monotonic() + 60
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        output += os.read(fd, 65536)
                    except OSError:
                        pass
                for prompt, answer in answers.items():
                    if prompt.encode() in output and prompt not in answered:
                        os.write(fd, answer.encode() + b'\n')
                        answered.add(prompt)
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    break
            else:
                os.kill(pid, signal.SIGKILL)
                self.fail('the installer timed out: ' + output.decode(errors='replace'))
            self.assertTrue(termios.tcgetattr(fd)[3] & termios.ECHO, 'echo not restored')
        finally:
            os.close(fd)
        self.assertEqual(list((self.root / 'temporary').iterdir()), [], 'temporary files survived')
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace')

    def test_asks_for_what_is_missing_the_token_and_the_request(self):
        code, output = self.interactive({
            'Environment repository URL': REPOSITORY, 'Branch [main]': '', 'Box name': 'main',
            'Git token': TOKEN, 'Start the box with this?': 'y'})
        self.assertEqual(code, 0, output)
        self.assertNotIn(TOKEN, output)
        self.assertIn('The box main asks this host for:', output)
        self.assertIn('port 3773 as 127.0.0.1:3773 (t3)', output)
        self.assertIn('docker compose logs -f box', output)
        [up] = self.up()
        self.assertEqual(up['bootstrap'], {'version': 2, 'repository': REPOSITORY, 'ref': 'main', 'box': 'main'})
        self.assertTrue(up['token_file'])
        self.assertEqual(up['files'], {'compose.yaml': '0o644', 'bootstrap.json': '0o600', 'git_token': '0o600',
                                       '.env': '0o600', 'accepted': '0o600', 'secrets': '0o700'})
        self.assertIn('"127.0.0.1:3773:3773"', up['compose'])
        self.assertIn('--force-recreate', up['args'])
        self.assertEqual((self.root / 'denbox-main').stat().st_mode & 0o777, 0o700)
        # Tried without the token first, then with it, then evaluated with it
        # over the box's Nix volume.
        self.assertEqual([e['token_handed'] for e in self.calls() if 'token_handed' in e], [False, True, True])
        [evaluation] = [e for e in self.calls() if 'evaluated' in e]
        self.assertEqual(evaluation['evaluated'], up['bootstrap'])
        self.assertEqual(evaluation['mounts'], ['denbox-main-nix:/nix'])
        self.assertEqual(sorted(p.name for p in (self.root / 'state').glob('volume-*')),
                         ['volume-denbox-main-home', 'volume-denbox-main-nix'])

    def test_a_request_not_accepted_starts_nothing(self):
        code, output = self.interactive({
            'Environment repository URL': REPOSITORY, 'Branch [main]': '', 'Box name': 'main',
            'Start the box with this?': 'n'}, FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('nothing was started', output)
        self.assertEqual(self.started(), [])
        self.assertFalse((self.root / 'denbox-main').exists())

    def test_unattended_without_acceptance_stops(self):
        code, output = self.unattended('--repository', REPOSITORY, '--box', 'main', '--dir', str(self.dir),
                                       FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('The box main asks this host for:', output)
        self.assertIn('--accept (DENBOX_ACCEPT=1)', output)
        self.assertEqual(self.started(), [])
        self.assertFalse(self.dir.exists())

    def test_an_unchanged_request_is_not_asked_again(self):
        self.install('--name', 'test-one', FAKE_PUBLIC='1', DENBOX_ACCEPT='1', DENBOX_IMAGE='example.com/denbox:1')
        self.assertEqual((self.dir / 'git_token').read_text(), '')
        output = self.install(FAKE_PUBLIC='1')
        self.assertIn('accepted before', output)
        first, second = self.up()
        self.assertEqual(first['env'], second['env'])
        self.assertEqual(second['env'], ['DENBOX_NAME=test-one', 'DENBOX_IMAGE=example.com/denbox:1',
                                         f'DENBOX_REPOSITORY={REPOSITORY}', 'DENBOX_REF=main', 'DENBOX_BOX=main',
                                         'DENBOX_RUNTIME=docker'])
        calls = [e['args'][:2] for e in self.calls()]
        self.assertEqual(calls.count(['pull', 'example.com/denbox:1']), 2)
        self.assertEqual(calls.count(['volume', 'create']), 2, 'volumes are created once')
        self.assertNotIn(['volume', 'rm'], calls)

    def test_a_changed_request_asks_again_and_shows_what_changed(self):
        self.install('--accept', FAKE_PUBLIC='1')
        self.declare(capabilities=['NET_ADMIN'], memory='8g')
        code, output = self.unattended('--dir', str(self.dir), FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('+ ! capability NET_ADMIN', output)
        self.assertIn('-   memory 4g, 2 CPUs, 2048 processes', output)
        self.assertIn('+   memory 8g, 2 CPUs, 2048 processes', output)
        self.assertEqual(len(self.up()), 1, 'a changed request started the box unattended')
        self.assertNotIn('NET_ADMIN', (self.dir / 'accepted').read_text())
        code, output = self.interactive({'Start the box with this?': 'y'}, '--dir', str(self.dir), FAKE_PUBLIC='1')
        self.assertEqual(code, 0, output)
        self.assertIn('+ ! capability NET_ADMIN', output)
        self.assertIn('"NET_ADMIN"', self.up()[-1]['compose'])
        self.assertIn('NET_ADMIN', (self.dir / 'accepted').read_text())

    def test_declared_secrets_are_asked_without_echo_stored_and_kept(self):
        self.declare(secrets=dict(API_KEY, **LOGIN))
        code, output = self.interactive({
            'Environment repository URL': REPOSITORY, 'Branch [main]': '', 'Box name': 'main',
            'Start the box with this?': 'y', 'Secret api_key': KEY, 'Secret login (may be empty)': ''},
            FAKE_PUBLIC='1')
        self.assertEqual(code, 0, output)
        self.assertNotIn(KEY, output)
        self.assertIn('secret api_key at /run/secrets/denbox_api_key: Key of the example API', output)
        [up] = self.up()
        self.assertEqual(up['secrets'], {'api_key': KEY + '\n', 'login': ''})
        self.assertEqual(up['files']['secrets/api_key'], '0o600')
        self.assertIn('{source: "denbox_api_key", target: "/run/secrets/denbox_api_key"}', up['compose'])
        self.assertIn('file: "./secrets/api_key"', up['compose'])
        code, output = self.unattended('--dir', str(self.root / 'denbox-main'), FAKE_PUBLIC='1')
        self.assertEqual(code, 0, output)
        self.assertEqual(self.up()[-1]['secrets'], {'api_key': KEY + '\n', 'login': ''})

    def test_secrets_from_a_file_or_a_variable_and_none_without_a_terminal(self):
        self.declare(secrets=dict(API_KEY, **LOGIN))
        code, output = self.unattended('--repository', REPOSITORY, '--box', 'main', '--dir', str(self.dir),
                                       '--accept', FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('give DENBOX_SECRET_API_KEY or --secret-file api_key=FILE', output)
        self.assertEqual(self.started(), [])
        key_file = self.root / 'key'
        key_file.write_text(KEY + '\n')
        self.install('--accept', '--secret-file', f'api_key={key_file}', FAKE_PUBLIC='1')
        self.assertEqual(self.up()[-1]['secrets'], {'api_key': KEY + '\n', 'login': ''})
        self.install(FAKE_PUBLIC='1', DENBOX_SECRET_LOGIN=KEY)
        self.assertEqual(self.up()[-1]['secrets'], {'api_key': KEY + '\n', 'login': KEY + '\n'})
        code, output = self.unattended('--dir', str(self.dir), FAKE_PUBLIC='1', DENBOX_SECRET_OTHER='x')
        self.assertNotEqual(code, 0)
        self.assertIn('The box declares no secret other', output)

    def test_podman_starts_quadlet_units_as_a_user_service(self):
        self.declare(secrets=API_KEY)
        self.install('--runtime', 'podman', '--name', 'test-two', '--accept', FAKE_PUBLIC='1', DENBOX_SECRET_API_KEY=KEY)
        self.install(FAKE_PUBLIC='1')
        calls = self.calls()
        self.assertFalse(any(e['cli'] == 'docker' for e in calls), 'docker was called')
        systemctl = [e['args'] for e in calls if e['cli'] == 'systemctl']
        self.assertEqual(systemctl, [['--user', 'daemon-reload'], ['--user', 'restart', 'denbox-test-two.service']] * 2)
        [*_, start] = [e for e in calls if 'units' in e]
        self.assertEqual(sorted(start['units']), ['denbox-test-two-home.volume', 'denbox-test-two-nix.volume',
                                                   'denbox-test-two.container'])
        container = start['units']['denbox-test-two.container']
        directory = self.dir.resolve()
        self.assertIn(f'Volume={directory}/bootstrap.json:/run/secrets/denbox_bootstrap:ro,Z', container)
        self.assertIn(f'Volume={directory}/secrets/api_key:/run/secrets/denbox_api_key:ro,Z', container)
        self.assertEqual((directory / 'secrets/api_key').read_text(), KEY + '\n')
        self.assertEqual(sorted(p.name for p in (directory / 'quadlet').iterdir()), sorted(start['units']))
        self.assertFalse((directory / 'compose.yaml').exists())
        self.assertIn('DENBOX_RUNTIME=podman', (directory / '.env').read_text().splitlines())

    def test_update_reuses_the_saved_token(self):
        self.install('--accept', DENBOX_GIT_TOKEN=TOKEN)
        self.install()
        self.assertTrue(all(e['token_file'] for e in self.up()))

    def test_without_a_terminal_a_private_repository_needs_the_token_up_front(self):
        code, output = self.unattended('--repository', REPOSITORY, '--box', 'main', '--dir', str(self.dir), '--accept')
        self.assertNotEqual(code, 0)
        self.assertIn('DENBOX_GIT_TOKEN', output)
        self.assertFalse(self.dir.exists())
        self.assertEqual(self.started(), [])

    def test_a_missing_branch_stops_before_anything_is_written(self):
        code, output = self.unattended('--repository', REPOSITORY, '--box', 'main', '--ref', 'nope',
                                       '--dir', str(self.dir), '--accept', FAKE_NO_BRANCH='1')
        self.assertNotEqual(code, 0)
        self.assertIn('no branch nope', output)
        self.assertFalse(self.dir.exists())

    def test_a_declaration_render_refuses_starts_nothing(self):
        self.declare(capabilities=['CAP_NET_ADMIN'])
        code, output = self.unattended('--repository', REPOSITORY, '--box', 'main', '--dir', str(self.dir),
                                       '--accept', FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('capabilities ["CAP_NET_ADMIN"] are not names such as NET_ADMIN', output)
        self.assertEqual(self.started(), [])


if __name__ == '__main__':
    unittest.main()
