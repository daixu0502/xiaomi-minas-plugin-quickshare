import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'payload/files'))
from quickshare_lib import Store, ShareError


class PerformanceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.store=Store(self.root/'var','u1');self.store.pool_root=self.root
        (self.root/'data').mkdir()

    def test_paging_does_not_hide_entries_after_first_thousand(self):
        for i in range(1005):(self.root/'data'/('%04d.txt'%i)).touch()
        names=[];offset=0
        while True:
            result=self.store.browse('data',offset,200);names += [r['name'] for r in result['entries']]
            if not result['hasMore']:break
            offset=result['nextOffset']
        self.assertEqual(len(names),1005);self.assertEqual(len(set(names)),1005);self.assertEqual(names,sorted(names))

    def test_folder_filter_and_link_boundaries(self):
        (self.root/'data/folder').mkdir();(self.root/'data/file').touch();(self.root/'data/link').symlink_to('/etc')
        self.assertEqual([r['name'] for r in self.store.browse('data',dirs_only=True)['entries']],['folder'])
        for offset,limit in [(True,200),(-1,200),(0,0),(0,1001)]:
            with self.assertRaises(ShareError):self.store.browse('data',offset,limit)

    def test_token_index_refreshes_after_mutation(self):
        self.store._save_unlocked({'settings':{},'shares':[{'token':'one','active':True}]})
        with patch.object(self.store,'_load_unlocked',wraps=self.store._load_unlocked) as load:
            self.assertTrue(self.store.find_token('one')['active']);self.store.find_token('one');self.assertEqual(load.call_count,1)
            self.store.mutate(lambda data:data['shares'].clear())
            self.assertIsNone(self.store.find_token('one'))


if __name__=='__main__':unittest.main()
