"""Tests of install.sh with a fake docker, on a real terminal where it asks.

    python3 -m unittest discover -s deploy/tests

The fake docker logs every call and plays the image: its git reads the
repository anonymously when FAKE_PUBLIC is set, and otherwise only with the
token TOKEN handed over on standard input.
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

DOCKER = r'''
import json, os, pathlib, sys
args = sys.argv[1:]
state = pathlib.Path(os.environ['FAKE_STATE'])
event = {'args': args, 'token_in_env': any(os.environ['FAKE_SECRET'] in v for k, v in os.environ.items() if k != 'FAKE_SECRET')}
status = 0
if args[:2] == ['volume', 'inspect']:
    status = 0 if (state / ('volume-' + args[2])).exists() else 1
elif args[:2] == ['volume', 'create']:
    (state / ('volume-' + args[2])).touch()
elif args[0] == 'volume':
    status = 99
elif args[0] == 'run' and 'cat' in args:
    print('name: denbox-${DENBOX_NAME}\nservices: {}')
elif args[0] == 'run':
    handed = sys.stdin.read().strip()
    event['token_handed'] = handed == os.environ['FAKE_SECRET']
    if os.environ.get('FAKE_NO_BRANCH'): status = 2
    elif os.environ.get('FAKE_PUBLIC') or event['token_handed']: status = 0
    else: status = 128
elif args[0] == 'compose' and 'up' in args:
    directory = pathlib.Path(args[args.index('--project-directory') + 1])
    event['files'] = {p.name: oct(p.stat().st_mode & 0o777) for p in directory.iterdir()}
    event['bootstrap'] = json.loads((directory / 'bootstrap.json').read_text())
    event['env'] = (directory / '.env').read_text().splitlines()
    event['token_file'] = (directory / 'git_token').read_text().strip() == os.environ['FAKE_SECRET']
with open(state / 'calls', 'a') as log:
    log.write(json.dumps(event) + '\n')
sys.exit(status)
'''


class Installer(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.root)])
        (self.root / 'bin').mkdir()
        (self.root / 'state').mkdir()
        (self.root / 'temporary').mkdir()
        docker = self.root / 'bin/docker'
        docker.write_text('#!' + sys.executable + '\n' + DOCKER)
        docker.chmod(0o755)
        self.dir = self.root / 'box'
        self.env = dict(os.environ, PATH=f'{self.root}/bin:{os.environ["PATH"]}', FAKE_STATE=str(self.root / 'state'),
                        FAKE_SECRET=TOKEN, TMPDIR=str(self.root / 'temporary'))
        for name in list(self.env):
            if name.startswith('DENBOX_'):
                del self.env[name]

    def calls(self):
        log = self.root / 'state/calls'
        events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        for event in events:
            self.assertNotIn(TOKEN, json.dumps(event['args']), 'the token is in a command line')
            self.assertFalse(event['token_in_env'], 'the token is in the environment of docker')
        return events

    def up(self):
        return [e for e in self.calls() if e['args'][0] == 'compose' and 'up' in e['args']]

    def unattended(self, *args, **env):
        """Runs the installer without a terminal; returns its exit code and output."""
        result = subprocess.run(['bash', str(ROOT / 'install.sh'), *args], env=dict(self.env, **env),
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                start_new_session=True, timeout=30)
        self.assertEqual(list((self.root / 'temporary').iterdir()), [], 'temporary files survived')
        return result.returncode, result.stdout + result.stderr

    def interactive(self, answers, **env):
        """Runs the installer on a terminal, answering each prompt that
        contains a key of answers; returns its exit code and output."""
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execvpe('bash', ['bash', str(ROOT / 'install.sh')], dict(self.env, **env))
        output, answered, status = b'', set(), None
        deadline = time.monotonic() + 30
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

    def test_asks_for_what_is_missing_and_the_token_of_a_private_repository(self):
        code, output = self.interactive({
            'Environment repository URL': 'https://git.example.com/me/environment.git',
            'Branch [main]': '', 'Box name': 'main', 'Git token': TOKEN})
        self.assertEqual(code, 0, output)
        self.assertNotIn(TOKEN, output)
        self.assertIn('docker compose logs -f box', output)
        [up] = self.up()
        self.assertEqual(up['bootstrap'], {'version': 2, 'repository': 'https://git.example.com/me/environment.git',
                                           'ref': 'main', 'box': 'main'})
        self.assertTrue(up['token_file'])
        self.assertEqual(up['files'], {'compose.yaml': '0o644', 'bootstrap.json': '0o600',
                                       'git_token': '0o600', '.env': '0o600'})
        self.assertIn('DENBOX_NAME=main', up['env'])
        self.assertIn('--force-recreate', up['args'])
        self.assertEqual((self.root / 'denbox-main').stat().st_mode & 0o777, 0o700)
        # Tried without the token first, then with it.
        self.assertEqual([e['token_handed'] for e in self.calls() if 'token_handed' in e], [False, True])
        self.assertEqual(sorted(p.name for p in (self.root / 'state').glob('volume-*')),
                         ['volume-denbox-main-home', 'volume-denbox-main-nix'])

    def test_unattended_public_install_then_update_keeps_settings_and_volumes(self):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       '--name', 'test-one', '--dir', str(self.dir),
                                       FAKE_PUBLIC='1', DENBOX_T3_PORT='49001', DENBOX_IMAGE='example.com/denbox:1')
        self.assertEqual(code, 0, output)
        self.assertEqual((self.dir / 'git_token').read_text(), '')
        code, output = self.unattended('--dir', str(self.dir), FAKE_PUBLIC='1')
        self.assertEqual(code, 0, output)
        first, second = self.up()
        self.assertEqual(first['env'], second['env'])
        self.assertIn('DENBOX_T3_PORT=49001', second['env'])
        self.assertIn('DENBOX_IMAGE=example.com/denbox:1', second['env'])
        self.assertEqual(second['bootstrap']['box'], 'main')
        calls = [e['args'][:2] for e in self.calls()]
        self.assertEqual(calls.count(['pull', 'example.com/denbox:1']), 2)
        self.assertEqual(calls.count(['volume', 'create']), 2, 'volumes are created once')
        self.assertNotIn(['volume', 'rm'], calls)

    def test_update_reuses_the_saved_token(self):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       '--dir', str(self.dir), DENBOX_GIT_TOKEN=TOKEN)
        self.assertEqual(code, 0, output)
        code, output = self.unattended('--dir', str(self.dir))
        self.assertEqual(code, 0, output)
        self.assertTrue(all(e['token_file'] for e in self.up()))

    def test_without_a_terminal_a_private_repository_needs_the_token_up_front(self):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       '--dir', str(self.dir))
        self.assertNotEqual(code, 0)
        self.assertIn('DENBOX_GIT_TOKEN', output)
        self.assertFalse(self.dir.exists())
        self.assertEqual(self.up(), [])

    def test_a_missing_branch_stops_before_anything_is_written(self):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       '--ref', 'nope', '--dir', str(self.dir), FAKE_NO_BRANCH='1')
        self.assertNotEqual(code, 0)
        self.assertIn('no branch nope', output)
        self.assertFalse(self.dir.exists())


if __name__ == '__main__':
    unittest.main()
