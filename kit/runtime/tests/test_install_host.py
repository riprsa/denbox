"""Tests of install-host.sh with fakes of the machine, on a real terminal where it asks.

    python3 -m unittest discover -s kit/runtime/tests

DENBOX_HOST_ROOT puts every file the installer writes under a temporary
directory. One fake plays id, getent, useradd, chown, systemctl, apt-get,
curl, git and nix and logs every call; it is the only nix, on PATH and
where Nix's release installer puts it. Its git reads the repository
anonymously when FAKE_PUBLIC is set, and otherwise only when the seed's
askpass answers with the token TOKEN. Its nix evaluates every box to the user
FAKE_USER with the home FAKE_HOME.
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

ROOT = Path(__file__).resolve().parents[3]
TOKEN = 'fixture-secret-token'
COMMANDS = ['id', 'getent', 'useradd', 'chown', 'systemctl', 'apt-get', 'curl', 'git', 'nix']

FAKE = r'''
import io, json, os, pathlib, shutil, subprocess, sys, tarfile
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
state = pathlib.Path(os.environ['FAKE_STATE'])
root = pathlib.Path(os.environ['DENBOX_HOST_ROOT'])
secret = os.environ['FAKE_SECRET']
event = {'command': name, 'args': args,
         'token_in_env': any(secret in v for k, v in os.environ.items() if k != 'FAKE_SECRET')}
status = 0

def passwd():
    path = state / 'passwd'
    return path.read_text().splitlines() if path.exists() else []

def readable():
    if os.environ.get('FAKE_NO_BRANCH'): return 2
    if os.environ.get('FAKE_PUBLIC'): return 0
    answer = subprocess.run([os.environ['GIT_ASKPASS'], 'Password for https://git.example.com'],
                            capture_output=True, text=True).stdout.strip()
    event['token_handed'] = answer == secret
    return 0 if answer == secret else 128

if name == 'id':
    print(0)
elif name == 'getent':
    lines = passwd() if args[0] == 'passwd' else (state / 'group').read_text().splitlines()
    index = 0 if args[0] == 'passwd' else 2
    found = [l for l in lines if len(args) == 1 or l.split(':')[index] == args[1]]
    print('\n'.join(found)) if found else None
    status = 0 if found else 2
elif name == 'useradd':
    user, home = args[-1], args[args.index('--home-dir') + 1]
    uid = 1000 + len(passwd())
    with open(state / 'passwd', 'a') as f: f.write(f'{user}:x:{uid}:{uid}::{home}:/bin/bash\n')
    with open(state / 'group', 'a') as f: f.write(f'{user}:x:{uid}:\n')
    (root / home.lstrip('/')).mkdir(parents=True)
elif name == 'systemctl':
    status = 0 if args[0] != 'is-active' or os.environ.get('FAKE_DAEMON') else 3
elif name == 'curl':
    pathlib.Path(args[args.index('-o') + 1]).write_text('not the release')
elif name == 'git':
    if args[0] == 'init':
        pathlib.Path(args[-1]).mkdir()
    elif 'ls-remote' in args or 'fetch' in args:
        status = readable()
    elif 'archive' in args:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as archive:
            data = b'{}'
            info = tarfile.TarInfo('flake.nix'); info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        sys.stdout.buffer.write(buffer.getvalue())
elif name == 'nix':
    if args[0] == 'build':
        link = root / args[args.index('--out-link') + 1].removeprefix(str(root)).lstrip('/')
        seed = state / 'seed'
        if not seed.exists():
            (seed / 'libexec/denbox').mkdir(parents=True)
            shutil.copy(os.environ['FAKE_ASKPASS'], seed / 'libexec/denbox/askpass')
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink(): link.unlink()
        link.symlink_to(seed)
    elif args[0] == 'eval':
        print(os.environ.get('FAKE_USER', 'box') + ' ' + os.environ.get('FAKE_HOME', '/home/box'), end='')
with open(state / 'calls', 'a') as log:
    log.write(json.dumps(event) + '\n')
sys.exit(status)
'''


class HostInstaller(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.base)])
        self.root = self.base / 'root'
        for directory in ['bin', 'state', 'temporary', 'root/run/systemd/system']:
            (self.base / directory).mkdir(parents=True)
        fake = self.base / 'fake'
        fake.write_text('#!' + sys.executable + '\n' + FAKE)
        fake.chmod(0o755)
        for command in COMMANDS:
            (self.base / 'bin' / command).symlink_to(fake)
        self.nix = self.root / 'nix/var/nix/profiles/default/bin/nix'
        self.nix.parent.mkdir(parents=True)
        self.nix.symlink_to(fake)
        self.state = self.base / 'state'
        (self.state / 'passwd').write_text('root:x:0:0::/root:/bin/bash\n')
        (self.state / 'group').write_text('root:x:0:\n')
        # The fakes are the only Nix the installer finds on PATH.
        path = ':'.join(d for d in os.environ['PATH'].split(':') if not (Path(d) / 'nix').exists())
        self.env = dict(os.environ, PATH=f'{self.base}/bin:{path}', FAKE_STATE=str(self.state),
                        FAKE_SECRET=TOKEN, FAKE_ASKPASS=str(ROOT / 'kit/runtime/askpass'), FAKE_DAEMON='1',
                        DENBOX_HOST_ROOT=str(self.root), TMPDIR=str(self.base / 'temporary'))
        for name in list(self.env):
            if name.startswith('DENBOX_') and name != 'DENBOX_HOST_ROOT':
                del self.env[name]

    def calls(self, command=None):
        log = self.state / 'calls'
        events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        for event in events:
            self.assertNotIn(TOKEN, json.dumps(event['args']), 'the token is in a command line')
            self.assertFalse(event['token_in_env'], 'the token is in the environment of a command')
        return [e['args'] for e in events if command in (None, e['command'])]

    def unattended(self, *args, **env):
        """Runs the installer without a terminal; returns its exit code and output."""
        result = subprocess.run(['bash', str(ROOT / 'install-host.sh'), *args], env=dict(self.env, **env),
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                start_new_session=True, timeout=30)
        self.assertEqual(list((self.base / 'temporary').iterdir()), [], 'temporary files survived')
        return result.returncode, result.stdout + result.stderr

    def interactive(self, answers, **env):
        """Runs the installer on a terminal, answering each prompt that
        contains a key of answers; returns its exit code and output."""
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe('bash', ['bash', str(ROOT / 'install-host.sh')], dict(self.env, **env))
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
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace')

    def unit(self, name='main'):
        return (self.root / f'etc/systemd/system/denbox-{name}.service').read_text()

    def install(self, *args, **env):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git',
                                       '--box', 'main', *args, **env)
        self.assertEqual(code, 0, output)
        return output

    def test_installs_the_box_as_the_user_it_names(self):
        output = self.install('--seed', 'path:/srv/denbox', DENBOX_GIT_TOKEN=TOKEN, DENBOX_SYNC_INTERVAL='60')
        self.assertIn('journalctl -u denbox-main.service', output)
        self.assertIn("su - box -c 'denbox shell'", output)
        self.assertEqual(self.calls('useradd'), [['--create-home', '--home-dir', '/home/box', '--user-group',
                                                  '--shell', '/bin/bash', 'box']])
        self.assertIn(['build', '--out-link', f'{self.root}/nix/var/nix/gcroots/denbox-seed', 'path:/srv/denbox#runtime'],
                      self.calls('nix'))
        directory = self.root / 'var/lib/denbox/main'
        self.assertEqual(json.loads((directory / 'bootstrap.json').read_text()),
                         {'version': 2, 'repository': 'https://git.example.com/me/environment.git',
                          'ref': 'main', 'box': 'main', 'sync_interval': 60})
        self.assertEqual((directory / 'git_token').read_text().strip(), TOKEN)
        self.assertEqual({p.name: oct(p.stat().st_mode & 0o777) for p in [directory, *directory.iterdir()]},
                         {'main': '0o750', 'bootstrap.json': '0o640', 'git_token': '0o640', 'settings': '0o600'})
        self.assertEqual(directory.parent.stat().st_mode & 0o777, 0o755)
        self.assertIn(['root:box', str(directory), str(directory / 'bootstrap.json'), str(directory / 'git_token')],
                      self.calls('chown'))
        unit = self.unit()
        for line in ['User=box', 'Group=box', 'RuntimeDirectory=denbox-box', 'Environment=DENBOX_RUN=/run/denbox-box',
                     'Environment=DENBOX_BOOTSTRAP=/var/lib/denbox/main/bootstrap.json',
                     'Environment=DENBOX_GIT_TOKEN=/var/lib/denbox/main/git_token',
                     'Environment=PATH=/home/box/.nix-profile/bin:/nix/var/nix/gcroots/denbox-seed/bin:'
                     '/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin',
                     'ExecStart=/usr/bin/env denbox supervise', 'Restart=always']:
            self.assertIn(line + '\n', unit)
        self.assertNotIn(TOKEN, unit)
        # Outside the store and the home, only these, none of them under /usr.
        written = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_file()
                         and p.relative_to(self.root).parts[0] not in ('nix', 'home'))
        self.assertEqual(written, ['etc/nix/nix.conf', 'etc/systemd/system/denbox-main.service',
                                   'var/lib/denbox/main/bootstrap.json', 'var/lib/denbox/main/git_token',
                                   'var/lib/denbox/main/settings'])
        self.assertEqual(self.calls('systemctl')[-3:], [['daemon-reload'], ['enable', '--quiet', 'denbox-main.service'],
                                                        ['restart', 'denbox-main.service']])

    def test_run_again_updates_the_unit_and_keeps_the_home_and_the_token(self):
        self.install(DENBOX_GIT_TOKEN=TOKEN)
        marker = self.root / 'home/box/marker'
        marker.write_text('kept')
        (self.root / 'etc/systemd/system/denbox-main.service').write_text('old\n')
        code, output = self.unattended('--name', 'main')
        self.assertEqual(code, 0, output)
        self.assertEqual(marker.read_text(), 'kept')
        self.assertIn('User=box\n', self.unit())
        self.assertEqual(len(self.calls('useradd')), 1, 'the user is created once')
        self.assertFalse(any(str(self.root / 'home/box') in args for args in self.calls('chown')), 'the home was chowned')
        restart = ['restart', 'denbox-main.service']
        self.assertEqual([a for a in self.calls('systemctl') if a == restart], [restart] * 2)
        self.assertIn(['build', '--out-link', f'{self.root}/nix/var/nix/gcroots/denbox-seed',
                       'github:riprsa/denbox#runtime'], self.calls('nix'))

    def test_the_daemon_trusts_the_binary_cache_once_and_only_trusts_it(self):
        conf = self.root / 'etc/nix/nix.conf'
        conf.parent.mkdir(parents=True)
        conf.write_text('build-users-group = nixbld')
        self.install(FAKE_PUBLIC='1')
        self.install(FAKE_PUBLIC='1')
        self.assertEqual(conf.read_text().splitlines(), [
            'build-users-group = nixbld',
            'extra-trusted-substituters = https://denbox.cachix.org',
            'extra-trusted-public-keys = denbox.cachix.org-1:0wTpaHGYAg3yirdzhxYjNPnzPjVjBiNoMHaK4Hptx9I='])
        self.assertEqual([a for a in self.calls('systemctl') if a[0] == 'restart' and 'nix-daemon.service' in a],
                         [['restart', 'nix-daemon.service']], 'the daemon restarts only when nix.conf changed')

    def test_asks_for_what_is_missing_and_the_token_of_a_private_repository(self):
        code, output = self.interactive({
            'Environment repository URL': 'https://git.example.com/me/environment.git',
            'Branch [main]': '', 'Box name': 'main', 'Git token': TOKEN})
        self.assertEqual(code, 0, output)
        self.assertNotIn(TOKEN, output)
        self.assertEqual((self.root / 'var/lib/denbox/main/git_token').read_text().strip(), TOKEN)
        # Tried without the token first, then with it, then fetched with it.
        handed = [json.loads(l).get('token_handed') for l in (self.state / 'calls').read_text().splitlines()]
        self.assertEqual([h for h in handed if h is not None], [False, True, True])
        self.calls()

    def test_a_root_box_runs_as_root_in_its_home(self):
        self.install(FAKE_PUBLIC='1', FAKE_USER='root', FAKE_HOME='/root')
        self.assertEqual(self.calls('useradd'), [])
        self.assertIn('User=root\n', self.unit())
        self.assertIn('RuntimeDirectory=denbox\n', self.unit())

    def test_an_existing_user_with_another_home_stops_before_anything_is_written(self):
        with open(self.state / 'passwd', 'a') as f:
            f.write('box:x:1000:1000::/srv/box:/bin/bash\n')
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('Set home.homeDirectory', output)
        self.assertFalse((self.root / 'var/lib/denbox').exists())

    def test_a_user_runs_one_box(self):
        self.install(FAKE_PUBLIC='1')
        code, output = self.unattended('--repository', 'https://git.example.com/me/other.git', '--box', 'other',
                                       FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('runs the box of denbox-main.service already', output)
        self.assertFalse((self.root / 'etc/systemd/system/denbox-other.service').exists())

    def test_a_missing_branch_stops_before_the_user_is_created(self):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       '--ref', 'nope', FAKE_NO_BRANCH='1')
        self.assertNotEqual(code, 0)
        self.assertIn('no branch nope', output)
        self.assertEqual(self.calls('useradd'), [])

    def test_run_again_with_another_box_switches_to_it(self):
        self.install(FAKE_PUBLIC='1', DENBOX_SYNC_INTERVAL='60')
        code, output = self.unattended('--name', 'main', '--box', 'other', FAKE_PUBLIC='1')
        self.assertEqual(code, 0, output)
        code, output = self.unattended('--name', 'main', FAKE_PUBLIC='1')
        self.assertEqual(code, 0, output)
        self.assertEqual(json.loads((self.root / 'var/lib/denbox/main/bootstrap.json').read_text()),
                         {'version': 2, 'repository': 'https://git.example.com/me/environment.git',
                          'ref': 'main', 'box': 'other', 'sync_interval': 60})
        self.assertIn('User=box\n', self.unit())
        self.assertEqual(len(self.calls('useradd')), 1)

    def test_switching_to_a_box_of_another_user_stops_before_anything_is_written(self):
        self.install(FAKE_PUBLIC='1')
        code, output = self.unattended('--name', 'main', '--box', 'other', FAKE_PUBLIC='1',
                                       FAKE_USER='someone', FAKE_HOME='/home/someone')
        self.assertNotEqual(code, 0)
        self.assertIn('denbox-main.service runs as box and boxes.other as someone', output)
        self.assertEqual(json.loads((self.root / 'var/lib/denbox/main/bootstrap.json').read_text())['box'], 'main')
        self.assertEqual(len(self.calls('useradd')), 1)

    def test_an_existing_user_whose_group_lists_it_runs_the_box_in_its_home(self):
        with open(self.state / 'passwd', 'a') as f:
            f.write('deck:x:1000:1000::/home/deck:/bin/bash\n')
        with open(self.state / 'group', 'a') as f:
            f.write('deck:x:1000:deck\n')
        (self.root / 'home/deck').mkdir(parents=True)
        self.install(FAKE_PUBLIC='1', FAKE_USER='deck', FAKE_HOME='/home/deck')
        self.assertEqual(self.calls('useradd'), [])
        self.assertIn('User=deck\nGroup=deck\n', self.unit())

    def test_uses_a_nix_on_the_path_where_the_release_installer_puts_none(self):
        self.nix.unlink()
        self.install(FAKE_PUBLIC='1')
        self.assertEqual(self.calls('curl'), [])
        self.assertIn(f'/nix/var/nix/gcroots/denbox-seed/bin:{self.base}/bin:/usr/local/bin:', self.unit())

    def test_installs_nix_only_as_the_pinned_release(self):
        self.nix.unlink()
        (self.base / 'bin/nix').unlink()
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       FAKE_PUBLIC='1')
        self.assertNotEqual(code, 0)
        self.assertIn('does not match its checksum', output)
        [curl] = self.calls('curl')
        self.assertTrue(curl[1].startswith('https://releases.nixos.org/nix/nix-2.34.1/'), curl)

    def test_refuses_a_nix_without_its_daemon(self):
        code, output = self.unattended('--repository', 'https://git.example.com/me/environment.git', '--box', 'main',
                                       FAKE_PUBLIC='1', FAKE_DAEMON='')
        self.assertNotEqual(code, 0)
        self.assertIn('multi-user Nix', output)


if __name__ == '__main__':
    unittest.main()
