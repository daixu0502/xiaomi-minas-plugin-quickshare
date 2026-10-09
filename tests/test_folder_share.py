import http.client
import io
import os
import sys
import tempfile
import threading
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'payload/files'))
from quickshare_lib import Store, ShareError
from folder_archive import open_folder, inventory, write_zip
from quickshare_server import Server, Handler


class FolderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'state', 'u123')
        self.store.pool_root = self.root / 'pool/u123'
        self.folder = self.store.pool_root / 'data/资料'
        (self.folder / '子目录').mkdir(parents=True)
        (self.folder / '空目录').mkdir()
        (self.folder / '中文.txt').write_text('测试内容', encoding='utf-8')
        (self.folder / '子目录/large.bin').write_bytes(b'x' * (1024 * 1024 + 5))
        (self.folder / '.secret').write_text('hidden')
        (self.root / 'outside').write_text('must not be shared')
        (self.folder / 'link').symlink_to(self.root / 'outside')
        os.mkfifo(self.folder / 'pipe')
        self.server = Server(('127.0.0.1', 0), Handler, self.store, b'test-secret')
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def create(self, password='', max_uses=3, path='data/资料', kind='folder'):
        return self.store.create(kind, path, password, 3600, max_uses)

    def request(self, path, method='GET', body=None, headers=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_folder_download_and_count(self):
        record = self.create()
        token = record['token']
        self.assertEqual(self.request('/s/' + token)[0], 200)
        self.assertEqual(self.store.find_token(token)['uses'], 0)
        status, headers, data = self.request('/d/' + token)
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'application/zip')
        self.assertIn('.zip', headers['Content-Disposition'])
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {'资料/', '资料/中文.txt', '资料/子目录/', '资料/子目录/large.bin', '资料/空目录/'})
            self.assertEqual(archive.read('资料/中文.txt').decode(), '测试内容')
        self.assertEqual(self.store.find_token(token)['uses'], 1)
        self.assertFalse(list(self.root.rglob('*.zip')))

    def test_password(self):
        record = self.create(password='test1234')
        token = record['token']
        self.assertIn('需要访问密码'.encode(), self.request('/d/' + token)[2])
        self.assertEqual(self.store.find_token(token)['uses'], 0)
        self.assertIn('密码错误'.encode(), self.request('/auth/' + token, 'POST', 'password=wrong')[2])
        status, headers, _ = self.request('/auth/' + token, 'POST', 'password=test1234')
        self.assertEqual(status, 303)
        cookie = headers['Set-Cookie'].split(';')[0]
        self.assertEqual(self.request('/d/' + token, headers={'Cookie':cookie})[1]['Content-Type'], 'application/zip')

    def test_limits_expiry_revoke_delete(self):
        record = self.create(max_uses=1)
        self.assertEqual(self.request('/d/' + record['token'])[0], 200)
        self.assertEqual(self.request('/d/' + record['token'])[0], 404)
        for action in ('expire', 'revoke', 'delete'):
            record = self.create()
            if action == 'expire':
                self.store.mutate(lambda d: d['shares'][0].update(expires_at=1))
            elif action == 'revoke': self.store.revoke(record['id'])
            else: self.store.delete(record['id'])
            self.assertEqual(self.request('/d/' + record['token'])[0], 404)
        self.assertTrue(self.folder.is_dir())

    def test_busy_does_not_consume(self):
        record = self.create()
        self.server.archive_slots.acquire(); self.server.archive_slots.acquire()
        try: self.assertEqual(self.request('/d/' + record['token'])[0], 503)
        finally: self.server.archive_slots.release(); self.server.archive_slots.release()
        self.assertEqual(self.store.find_token(record['token'])['uses'], 0)

    def test_atomic_limit(self):
        record = self.create(max_uses=1)
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.request('/d/' + record['token'])[0], range(2)))
        self.assertEqual(sorted(results), [200, 404])

    def test_empty_folder(self):
        record = self.create(path='data/资料/空目录')
        with zipfile.ZipFile(io.BytesIO(self.request('/d/' + record['token'])[2])) as archive:
            self.assertEqual(archive.namelist(), ['空目录/'])

    def test_limits_before_headers(self):
        record = self.create()
        with patch('folder_archive.MAX_ENTRIES', 1):
            status, _, _ = self.request('/d/' + record['token'])
        self.assertEqual(status, 409)
        self.assertEqual(self.store.find_token(record['token'])['uses'], 0)
        with open_folder(self.store, record['path']) as fd, patch('folder_archive.MAX_DEPTH', 0):
            with self.assertRaises(ShareError): inventory(fd)

    def test_symlink_root_and_traversal_rejected(self):
        (self.store.pool_root / 'data/alias').symlink_to(self.folder, target_is_directory=True)
        with self.assertRaises(ShareError): self.create(path='data/alias')
        with self.assertRaises(ShareError): self.create(path='data/../资料')
        with self.assertRaises(ShareError):
            with open_folder(self.store, '/data/资料'): pass

    def test_replaced_root(self):
        record = self.create()
        self.folder.rename(self.folder.with_name('original'))
        self.folder.symlink_to(self.folder.with_name('original'), target_is_directory=True)
        self.assertEqual(self.request('/d/' + record['token'])[0], 409)
        self.assertEqual(self.store.find_token(record['token'])['uses'], 0)

    def test_file_changed_and_symlink_swap(self):
        for use_link in (False, True):
            file = self.folder / '中文.txt'
            with open_folder(self.store, 'data/资料') as fd:
                entries = inventory(fd)
                if use_link:
                    file.unlink(); file.symlink_to(self.root / 'outside')
                else: file.write_text('changed contents')
                output = io.BytesIO()
                with self.assertRaises((ShareError, OSError)): write_zip(output, fd, '资料', entries)
                self.assertNotIn(b'must not be shared', output.getvalue())
                with self.assertRaises(zipfile.BadZipFile): zipfile.ZipFile(io.BytesIO(output.getvalue()))

    def test_client_disconnect(self):
        class Broken:
            def write(self, data): raise BrokenPipeError()
        with open_folder(self.store, 'data/资料') as fd:
            with self.assertRaises(BrokenPipeError): write_zip(Broken(), fd, '资料', inventory(fd))

    def test_legacy_file_and_upload(self):
        record = self.create(kind='download', path='data/资料/中文.txt')
        self.assertEqual(self.request('/d/' + record['token'])[2].decode(), '测试内容')
        record = self.create(kind='upload')
        self.assertEqual(self.request('/d/' + record['token'])[0], 404)
        self.assertEqual(self.request('/upload/' + record['token'] + '?name=uploaded.txt', 'POST', b'ok')[0], 200)
        self.assertEqual((self.folder / 'uploaded.txt').read_bytes(), b'ok')


if __name__ == '__main__':
    unittest.main()
