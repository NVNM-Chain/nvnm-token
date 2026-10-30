import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DependencyLockTest(unittest.TestCase):
    def test_invalid_locks_fail_before_git_checks(self):
        good = json.loads((ROOT / 'foundry.lock').read_text())
        wrong_revision = json.loads(json.dumps(good))
        wrong_revision['lib/forge-std']['tag']['rev'] = 'not-a-commit'
        extra = dict(good, unexpected={})
        for lock in ('{invalid', '{}', json.dumps(wrong_revision), json.dumps(extra), None):
            with self.subTest(lock=lock), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'script').mkdir()
                shutil.copy2(ROOT / 'script/check-deps.sh', root / 'script/check-deps.sh')
                if lock is not None:
                    (root / 'foundry.lock').write_text(lock)
                result = subprocess.run(['bash', str(root / 'script/check-deps.sh')], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('PASS:', result.stdout)
                self.assertNotIn('Verifying submodule revisions', result.stdout)


if __name__ == '__main__':
    unittest.main()
