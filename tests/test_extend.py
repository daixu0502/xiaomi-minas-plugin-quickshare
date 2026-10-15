import copy
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'payload/files'))
from quickshare_lib import Store, ShareError, MAX_EXPIRES


class ExtendTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.store=Store(self.root/'state','u123');self.store.pool_root=self.root/'pool'
        (self.store.pool_root/'data').mkdir(parents=True)
        (self.store.pool_root/'data/example.txt').write_text('synthetic')
        self.record=self.store.create('download','data/example.txt','fixture-password',3600,3)

    def tearDown(self):self.tmp.cleanup()

    def test_active_extends_from_previous_deadline_and_preserves_all_other_fields(self):
        original=copy.deepcopy(self.record)
        with patch('quickshare_lib.time.time',return_value=original['created_at']+60):
            updated=self.store.extend(original['id'],86400,original['expires_at'])
        self.assertEqual(updated['expires_at'],original['expires_at']+86400)
        updated.pop('expires_at');original.pop('expires_at');self.assertEqual(updated,original)

    def test_expired_extends_from_now_and_refreshes_cached_token(self):
        self.store.mutate(lambda d:d['shares'][0].update(expires_at=100))
        other=Store(self.store.state_dir,'u123')
        self.assertEqual(other.find_token(self.record['token'])['expires_at'],100)
        with patch('quickshare_lib.time.time',return_value=1000):
            self.store.extend(self.record['id'],3600,100)
            updated=other.find_token(self.record['token'])
            self.assertEqual(updated['expires_at'],4600)
            self.assertEqual(Store.status(updated),'active')

    def test_revoked_and_exhausted_are_not_reactivated(self):
        for field,value in (('active',False),('uses',3)):
            with self.subTest(field=field):
                self.store.mutate(lambda d:d['shares'].__setitem__(0,dict(self.record,**{field:value})))
                before=self.store.state_file.read_bytes()
                with self.assertRaises(ShareError):self.store.extend(self.record['id'],3600,self.record['expires_at'])
                self.assertEqual(self.store.state_file.read_bytes(),before)

    def test_repeat_request_does_not_extend_twice(self):
        self.store.extend(self.record['id'],3600,self.record['expires_at'])
        with self.assertRaisesRegex(ShareError,'未重复延期'):
            self.store.extend(self.record['id'],3600,self.record['expires_at'])
        self.assertEqual(self.store.list()[0]['expires_at'],self.record['expires_at']+3600)

    def test_concurrent_updates_apply_only_once(self):
        def extend(_):
            try:self.store.extend(self.record['id'],3600,self.record['expires_at']);return True
            except ShareError:return False
        with ThreadPoolExecutor(max_workers=2) as workers:self.assertEqual(sorted(workers.map(extend,range(2))),[False,True])
        self.assertEqual(self.store.list()[0]['expires_at'],self.record['expires_at']+3600)

    def test_missing_cross_user_and_invalid_values_do_not_write(self):
        before=self.store.state_file.read_bytes()
        for seconds in (None,True,0,299,MAX_EXPIRES+1,3600.5,'3600'):
            with self.assertRaises(ShareError):self.store.extend(self.record['id'],seconds,self.record['expires_at'])
        for expected in (None,True,0,'3600'):
            with self.assertRaises(ShareError):self.store.extend(self.record['id'],3600,expected)
        for ident in (None,'','missing'):
            with self.assertRaises(ShareError):self.store.extend(ident,3600,self.record['expires_at'])
        other=Store(self.root/'other-user-state','u456')
        with self.assertRaises(ShareError):other.extend(self.record['id'],3600,self.record['expires_at'])
        self.assertEqual(self.store.state_file.read_bytes(),before)

    def test_folder_and_upload_records_can_extend_without_changing_kind(self):
        for kind in ('folder','upload'):
            record=self.store.create(kind,'data','',3600,0)
            result=self.store.extend(record['id'],MAX_EXPIRES,record['expires_at'])
            self.assertEqual(result['kind'],kind)
            self.assertEqual(result['expires_at'],record['expires_at']+MAX_EXPIRES)


if __name__=='__main__':unittest.main()
