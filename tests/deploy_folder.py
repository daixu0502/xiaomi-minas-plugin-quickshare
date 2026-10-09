"""Targeted NAS upgrade; preserves local boot integration and state. Root only."""
import fcntl
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from contextlib import ExitStack
from pathlib import Path

FILES = ('files/folder_archive.py', 'files/quickshare_lib.py', 'files/quickshare_server.py',
         'ui/app.js', 'ui/index.html', 'ui/style.css', 'ui/quickshare.cgi')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main(user):
    assert os.geteuid() == 0 and re.fullmatch(r'u[0-9]+', user)
    assert os.path.ismount('/nas/pool0')
    home = Path('/home') / user / 'plugin/quickshare'
    src = (home / 'src').resolve(strict=True)
    assert src == Path('/nas/pool0') / user / 'plugin/pluginsrc/quickshare'
    payload = Path(__file__).resolve().parents[1] / 'payload'
    info_path = home / 'INFO'
    info = json.loads(info_path.read_bytes())
    assert info['version'] in ('1.1.23', '1.1.24')
    control = home / 'scripts/control'
    port = int((home / 'var/server.port').read_text())
    env = dict(os.environ, PLUG_USER=user, PLUG_HOME_DIR=str(home), PLUG_SRC_DIR=str(src))
    account = pwd.getpwnam(user)
    registry = Path('/data/plugin') / (user + '.list')
    registry_lock = '/data/plugin/.' + user + '.quickshare.lock'
    originals = {}
    for relative in FILES:
        target = src / relative
        assert not target.is_symlink() and target.parent.resolve() in (src / 'ui', src / 'files')
        originals[target] = (target.read_bytes(), target.stat()) if target.exists() else (None, None)
    originals[info_path] = (info_path.read_bytes(), info_path.stat())
    state = {p: digest((home / 'var' / p).read_bytes()) for p in ('shares.json', 'server.secret', 'server.port')}

    def atomic(target, data, metadata=None):
        fd, name = tempfile.mkstemp(prefix='.folder-release-', dir=target.parent)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(data); output.flush(); os.fsync(output.fileno())
                os.fchmod(output.fileno(), metadata.st_mode & 0o777 if metadata else 0o644)
                os.fchown(output.fileno(), metadata.st_uid if metadata else account.pw_uid,
                          metadata.st_gid if metadata else account.pw_gid)
            os.replace(name, target)
        finally:
            if os.path.exists(name): os.unlink(name)

    def ctl(action):
        subprocess.run([str(control), action], env=env, check=True, timeout=40, capture_output=True)

    def update_info(new_info):
        with open(registry_lock, 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = json.loads(registry.read_bytes())
            data['quickshare']['info'] = {k:v for k,v in new_info.items() if k != 'abstract'}
            atomic(registry, (json.dumps(data, ensure_ascii=False, indent=2)+'\n').encode(), registry.stat())

    with ExitStack() as stack:
        for name in ('/data/plugin/.local-plugin-installer.lock', '/data/plugin/.'+user+'.plugins.lock'):
            lock = stack.enter_context(open(name, 'a')); fcntl.flock(lock, fcntl.LOCK_EX)
        connections = subprocess.check_output(['ss', '-ntH', 'state', 'established'], text=True)
        assert not any(re.search(r':'+str(port)+r'\s', line) for line in connections.splitlines()), 'Active share transfers; retry later'
        was_running = subprocess.run([str(control), 'status'], env=env, capture_output=True).returncode == 0
        baseline = json.loads(registry.read_bytes()); baseline.pop('quickshare')
        try:
            ctl('stop')
            for relative in FILES:
                target = src / relative
                atomic(target, (payload / relative).read_bytes(), originals[target][1])
            updated = dict(info, version='1.1.24', timestamp=int(time.time()),
                           changelog='新增文件夹流式 ZIP 分享，保留目录结构及密码、有效期、次数限制')
            source_files = sorted(p for p in src.rglob('*') if p.is_file() and not p.is_symlink())
            updated['abstract'] = digest(''.join(digest(p.read_bytes())+'\n' for p in source_files).encode())
            updated['size'] = sum(p.stat().st_blocks * 512 for p in source_files)
            atomic(info_path, (json.dumps(updated, ensure_ascii=False, indent=2)+'\n').encode(), originals[info_path][1])
            update_info(updated)
            verify_env = dict(env, PLUG_NAME='quickshare', PLUG_TMP_DIR=str((home/'tmp').resolve()), PLUG_STATUS='unverified')
            subprocess.run(['/usr/bin/plugin.sh', 'verify'], env=verify_env, check=True, timeout=30, capture_output=True)
            if was_running:
                ctl('start')
                with urllib.request.urlopen('http://127.0.0.1:'+str(port)+'/health', timeout=8) as response:
                    assert json.load(response)['ok']
            assert all(digest((home/'var'/p).read_bytes()) == value for p,value in state.items()), 'State changed during upgrade'
            for relative in FILES:
                assert (src/relative).read_bytes() == (payload/relative).read_bytes()
            after = json.loads(registry.read_bytes())
            assert after.pop('quickshare')['info']['version'] == '1.1.24'
            assert after == baseline, 'Other plugin registry changed'
            print('PASS deployed 1.1.24; source verification, health, state and other plugins unchanged', flush=True)
        except BaseException:
            ctl('stop')
            for target, (data, metadata) in originals.items():
                if data is None:
                    if target.exists(): target.unlink()
                else: atomic(target, data, metadata)
            update_info(info)
            if was_running: ctl('start')
            print('Rolled back plugin files; user data was not overwritten', flush=True)
            raise


if __name__ == '__main__':
    main(sys.argv[1])
