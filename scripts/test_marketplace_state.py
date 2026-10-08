"""Small offline regression checks; unittest, temporary files, no network."""
import os
from pathlib import Path
import tempfile
import unittest

import marketplace_state as state


class MarketplaceStateTests(unittest.TestCase):
    def test_content_version_and_runtime_markers(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'SKILL.md').write_text('real skill\n', encoding='utf-8')
            first = state.content_version(root)
            (root / '.in_use').mkdir()
            (root / '.in_use' / str(os.getpid())).touch()
            self.assertEqual(first, state.content_version(root))
            (root / 'SKILL.md').write_text('updated skill\n', encoding='utf-8')
            self.assertNotEqual(first, state.content_version(root))

    def test_cleanup_preserves_referenced_live_and_foreign(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cache = root / 'cache' / state.MARKETPLACE
            paths = [cache / 'skill-test' / name for name in ['current', 'old', 'live']]
            for path in paths:
                path.mkdir(parents=True)
                (path / 'SKILL.md').write_text('content', encoding='utf-8')
            (paths[2] / '.in_use').mkdir()
            (paths[2] / '.in_use' / str(os.getpid())).touch()
            foreign = root / 'cache' / 'other-marketplace' / 'old'
            foreign.mkdir(parents=True)
            removed, deferred = state.prune_versions(cache, {paths[0].resolve()})
            self.assertEqual(removed, [str(paths[1])])
            self.assertEqual(deferred, [str(paths[2])])
            self.assertTrue(paths[0].exists())
            self.assertTrue(paths[2].exists())
            self.assertTrue(foreign.exists())

    def test_missing_or_linked_content_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                state.file_map(root / 'missing')
            if os.name != 'nt':
                (root / 'link').symlink_to(root / 'missing')
                with self.assertRaises(ValueError):
                    state.file_map(root)


if __name__ == '__main__':
    unittest.main()
