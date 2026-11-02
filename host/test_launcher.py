"""The launcher must import the same way tests do.

``python host/console.py`` puts ``host/`` on sys.path, while ``python -m unittest``
runs from the repo root where ``host`` is the package. Mixing the two broke the
launcher with ``ModuleNotFoundError: No module named 'host'`` even though every
test passed, so this runs the real entry point.
"""

import os
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LAUNCHERS = ("host/console.py", "scripts/gui_burst_bench.py")


class LauncherTest(unittest.TestCase):
    def test_launchers_can_import_their_modules(self):
        for launcher in LAUNCHERS:
            with self.subTest(launcher=launcher):
                result = subprocess.run(
                    [sys.executable, launcher, "--help"],
                    cwd=str(REPO),
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
