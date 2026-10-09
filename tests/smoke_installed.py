"""Run as the plugin user on NAS. Temporary files/record are removed in finally."""
import http.client
import io
import json
import os
import pwd
import subprocess
import tempfile
import zipfile
from pathlib import Path

user = pwd.getpwuid(os.geteuid()).pw_name
assert user.startswith('u') and user[1:].isdigit()
home = Path('/home') / user / 'plugin/quickshare'
port = int((home / 'var/server.port').read_text())
cgi = str(home / 'src/ui/quickshare.cgi')


def api(action, data):
    body = json.dumps(data).encode()
    env = dict(os.environ, REQUEST_METHOD='POST', CONTENT_TYPE='application/json',
               CONTENT_LENGTH=str(len(body)), QUERY_STRING='action=' + action)
    result = subprocess.run([cgi], input=body, env=env, capture_output=True, check=True)
    assert not result.stderr, result.stderr
    parsed = json.loads(result.stdout.decode().replace('\r\n', '\n').split('\n\n', 1)[1])
    assert parsed['ok'], parsed
    return parsed


def get(path):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        conn.request('GET', path)
        response = conn.getresponse()
        return response.status, response.read()
    finally:
        conn.close()


before = {s['id']: s for s in api('list', {})['shares']}
assert api('status', {})['pluginVersion'] == '1.1.24'
with tempfile.TemporaryDirectory(prefix='quickshare-folder-check-', dir=Path('/nas/pool0') / user / 'data') as directory:
    folder = Path(directory)
    (folder / 'empty').mkdir()
    name = '\u6d4b\u8bd5.txt'
    (folder / name).write_text('folder share verified')
    share = None
    try:
        result = api('create', {'kind': 'folder', 'path': 'data/' + folder.name,
                                'password': '', 'expiresIn': 300, 'maxUses': 1})
        share = result['share']
        token = share['url'].rsplit('/', 1)[1]
        assert get('/s/' + token)[0] == 200
        status, body = get('/d/' + token)
        assert status == 200
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            assert archive.read(folder.name + '/' + name) == b'folder share verified'
            assert folder.name + '/empty/' in archive.namelist()
            assert archive.testzip() is None
        assert get('/d/' + token)[0] == 404
    finally:
        if share:
            api('delete', {'id': share['id']})
after = {s['id']: s for s in api('list', {})['shares']}
assert before == after
print('PASS live CGI, ZIP download, empty directory, Chinese name, count limit; test files/record removed; existing shares unchanged')
