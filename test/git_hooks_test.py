"""Exercise hook installation and Git's actual staged/pre-push behavior."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GitHooksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sprucegoose-hooks-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        shutil.copytree(ROOT / ".githooks", self.repo / ".githooks")
        (self.repo / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/install-git-hooks", self.repo / "scripts/install-git-hooks")
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        self.run_cmd("git", "init", "-q", check=True)

    def run_cmd(self, *args, check=False):
        return subprocess.run(args, cwd=self.repo, env=self.env, capture_output=True,
                              text=True, check=check, timeout=10)

    def install(self):
        return self.run_cmd("bash", "scripts/install-git-hooks")

    def test_install_is_idempotent(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.run_cmd("git", "config", "--local", "core.hooksPath").stdout.strip(), ".githooks")

    def test_existing_hook_configuration_is_preserved(self):
        self.run_cmd("git", "config", "core.hooksPath", "custom-hooks", check=True)
        self.assertEqual(self.install().returncode, 2)
        self.assertEqual(self.run_cmd("git", "config", "core.hooksPath").stdout.strip(), "custom-hooks")

    def test_default_user_hook_is_preserved(self):
        hook = self.repo / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 7\n")
        self.assertEqual(self.install().returncode, 2)
        self.assertEqual(hook.read_text(), "#!/bin/sh\nexit 7\n")

    def test_precommit_checks_index_even_if_worktree_was_corrected(self):
        self.assertEqual(self.install().returncode, 0)
        file = self.repo / "sample.txt"
        file.write_text("bad trailing space \n")
        self.run_cmd("git", "add", "sample.txt", check=True)
        file.write_text("fixed in worktree\n")
        result = self.run_cmd("git", "-c", "user.name=Fixture", "-c",
                              "user.email=fixture@example.invalid", "commit", "-m", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("trailing whitespace", result.stdout + result.stderr)

    def test_prepush_propagates_failed_checks(self):
        check = self.repo / "scripts/check-local"
        check.write_text("#!/bin/sh\nexit 17\n")
        check.chmod(0o755)
        result = self.run_cmd("bash", ".githooks/pre-push")
        self.assertEqual(result.returncode, 17)


if __name__ == "__main__":
    unittest.main()
