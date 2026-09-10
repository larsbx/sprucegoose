"""No network, real Mix, database, or service is used by these regressions."""

import datetime as dt
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
AUDIT = runpy.run_path(str(ROOT / "scripts/audit_dependencies.py"))
ID = "EEF-CVE-2026-32686"
CLEAN = AUDIT["CLEAN"] + "\n"
REPORT = (
    "Advisories:\n"
    f"  decimal 3.1.1 - {ID} (LOW)\n"
    "    aka: CVE-2026-32686\n"
    "    Unbounded exponent parsing\n"
    "    https://example.invalid/advisory\n\n"
    + AUDIT["COMPLETE"] + "\n"
)


class ReportTest(unittest.TestCase):
    def test_clean_and_accepted_shape(self):
        self.assertEqual(AUDIT["parse_report"](CLEAN, 0), [])
        self.assertEqual(AUDIT["parse_report"](REPORT, 1)[0][0], ID)
        colored = REPORT.replace("Advisories:", "\x1b[1mAdvisories:\x1b[0m")
        self.assertEqual(AUDIT["parse_report"](colored, 1), AUDIT["parse_report"](REPORT, 1))

    def test_incomplete_failed_and_mixed_reports_refuse(self):
        cases = [
            ("", 0), ("", 1), (CLEAN, 1), (REPORT, 0), (REPORT, 42),
            ("ERROR: feed unreachable\n", 42),
            (REPORT.replace(AUDIT["COMPLETE"], ""), 1),
            (REPORT + "ERROR: network failure\n", 1),
            (REPORT.replace("\n\nFound", "\nERROR: network failure\n\nFound"), 1),
            (REPORT.replace("    Unbounded exponent parsing\n", ""), 1),
            (REPORT.replace("    aka: CVE-2026-32686", "    aka: bad alias"), 1),
            ("Advisories:\n\n" + AUDIT["COMPLETE"], 1),
            ("Retired:\n  old 1.0.0 - retired\nFound retired packages\n", 1),
            (REPORT.replace("Advisories:", "Ignored advisories:"), 0),
            (REPORT.replace("Advisories:", "Policy-accepted advisories:"), 0),
            (REPORT.replace("Advisories:", "Unknown:"), 1),
            (CLEAN + "\x00", 0),
        ]
        for output, status in cases:
            with self.subTest(output=output, status=status):
                with self.assertRaises(AUDIT["AuditError"]):
                    AUDIT["parse_report"](output, status)

    def test_allowlist_calendar_owner_rationale_and_duplicates(self):
        today = dt.date(2026, 10, 8)
        row = f"{ID} 2026-10-08 lars reviewed rationale\n"
        self.assertIn(ID, AUDIT["parse_allowlist"](row, today))
        for value in [
            row + row, row.replace("2026-10-08", "2026-10-07"),
            row.replace("2026-10-08", "2026-02-30"),
            row.replace("2026-10-08", "20261008"),
            f"{ID} 2026-10-08\n", f"{ID} 2026-10-08 lars\n",
            f"{ID} 2026-10-08 # rationale\n",
        ]:
            with self.subTest(value=value):
                with self.assertRaises(AUDIT["AuditError"]):
                    AUDIT["parse_allowlist"](value, today)


class ScriptTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="sprucegoose-gate-test-")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.repo = self.work / "repo"
        self.repo.mkdir()
        (self.repo / "scripts").mkdir()
        for name in ["audit-dependencies", "audit_dependencies.py", "ci-governed-release"]:
            shutil.copy2(ROOT / "scripts" / name, self.repo / "scripts" / name)
        (self.repo / "mix.lock").write_text("%{}\n")
        self.allowlist = self.repo / ".hex-audit-allowlist"
        self.allowlist.write_text(f"{ID} 2999-10-08 lars fixture only\n")
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.trace = self.work / "trace.jsonl"
        stub = self.bin / "mix"
        stub.write_text(
            "#!" + shutil.which("python3") + "\n"
            "import os,sys,json\n"
            "from pathlib import Path\n"
            "args=sys.argv[1:]\n"
            "with open(os.environ['TRACE'], 'a') as f:\n"
            " f.write(json.dumps({'args':args,'env':{k:v for k,v in os.environ.items() "
            "if k.startswith('SPRUCE_GOOSE_TEST_DATABASE')}})+'\\n')\n"
            "if args==['hex.info']:\n"
            " print('Hex:    '+os.environ.get('TEST_HEX_VERSION','2.5.1'))\n"
            " sys.exit(0)\n"
            "if args==['hex.audit']:\n"
            " print(os.environ['TEST_AUDIT_OUTPUT'],end='')\n"
            " if os.environ.get('MUTATE_LOCK'): Path('mix.lock').write_text('changed')\n"
            " sys.exit(int(os.environ['TEST_AUDIT_STATUS']))\n"
            "if args and args[0]=='test': sys.exit(int(os.environ.get('TEST_MIX_TEST_STATUS','23')))\n"
            "sys.exit(0)\n"
        )
        stub.chmod(0o755)
        builder = self.repo / "scripts" / "build-governed-release"
        builder.write_text(
            "#!/bin/sh\n"
            "printf 'builder-task=%s\\n' \"$SPRUCE_GOOSE_TASK\" > \"$BUILDER_TRACE\"\n"
            "exit 31\n"
        )
        builder.chmod(0o755)
        for args in [
            ["init", "-q"], ["add", "."],
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "commit", "-qm", "fixture"],
        ]:
            subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)
        self.env = os.environ.copy()
        self.env.pop("SPRUCE_GOOSE_TASK", None)
        for key in list(self.env):
            if key.startswith(("SPRUCE_GOOSE_TEST_", "CI_", "HEX_AUDIT_")):
                del self.env[key]
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env["PATH"], TRACE=str(self.trace),
            TEST_AUDIT_OUTPUT=REPORT, TEST_AUDIT_STATUS="1",
            BUILDER_TRACE=str(self.work / "builder-trace"),
        )

    def invoke(self, script="audit-dependencies", args=(), **env):
        return subprocess.run(
            ["bash", str(self.repo / "scripts" / script), *args], cwd=self.repo,
            env={**self.env, **env}, capture_output=True, text=True, timeout=20,
        )

    def commands(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def test_clean_and_accepted_exit_zero(self):
        for output, status in [(CLEAN, "0"), (REPORT, "1")]:
            result = self.invoke(TEST_AUDIT_OUTPUT=output, TEST_AUDIT_STATUS=status)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("mix-lock-sha256=", result.stdout)
            self.assertIn("dependency-audit=PASS", result.stdout)

    def test_unlisted_and_mixed_findings_refuse(self):
        other = REPORT.replace(ID, "EEF-CVE-2099-99999")
        mixed = REPORT.replace("\n\nFound", "\n\n" + other.split("\n", 1)[1].split("\n\nFound")[0] + "\n\nFound")
        for output in [other, mixed]:
            result = self.invoke(TEST_AUDIT_OUTPUT=output)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("dependency-audit=PASS", result.stdout)

    def test_id_matching_is_literal(self):
        self.allowlist.write_text(f"EEF.CVE.2026.32686 2999-10-08 lars fixture only\n")
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_failure_status_cannot_become_pass(self):
        for output, status in [("ERROR: feed unreachable\n", "42"), (CLEAN, "1"), (REPORT, "42")]:
            result = self.invoke(TEST_AUDIT_OUTPUT=output, TEST_AUDIT_STATUS=status)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("dependency-audit=PASS", result.stdout)

    def test_unknown_hex_and_changed_inputs_refuse(self):
        self.assertNotEqual(self.invoke(TEST_HEX_VERSION="2.6.0").returncode, 0)
        result = self.invoke(MUTATE_LOCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during audit", result.stderr)

    def test_missing_mix_refuses(self):
        (self.bin / "mix").write_text("#!/bin/sh\nexit 127\n")
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_failed_audit_stops_before_compile_database_or_build(self):
        result = self.invoke(
            "ci-governed-release", TEST_AUDIT_OUTPUT="ERROR: feed unreachable\n",
            TEST_AUDIT_STATUS="42",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            [row["args"] for row in self.commands()],
            [["deps.get"], ["hex.info"], ["hex.audit"]],
        )

    def test_empty_overrides_are_unset_and_failed_tests_cleanup_isolated_db(self):
        overrides = {
            "SPRUCE_GOOSE_TEST_DATABASE_" + key: ""
            for key in ["USERNAME", "PASSWORD", "HOSTNAME", "PORT"]
        }
        result = self.invoke("ci-governed-release", CI_PIPELINE_NUMBER="123", **overrides)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        rows = self.commands()
        db_rows = [row for row in rows if row["args"][0] in ["ecto.create", "ash.migrate", "test", "ecto.drop"]]
        self.assertEqual([row["args"][0] for row in db_rows], ["ecto.create", "ash.migrate", "test", "ecto.drop"])
        for row in db_rows:
            self.assertEqual(row["env"], {"SPRUCE_GOOSE_TEST_DATABASE": "spruce_goose_ci_123"})

    def test_nonempty_overrides_survive_and_database_name_is_pipeline_owned(self):
        overrides = {
            "SPRUCE_GOOSE_TEST_DATABASE_USERNAME": "isolated",
            "SPRUCE_GOOSE_TEST_DATABASE_PASSWORD": " fixture-only ",
            "SPRUCE_GOOSE_TEST_DATABASE_HOSTNAME": "127.0.0.1",
            "SPRUCE_GOOSE_TEST_DATABASE_PORT": "55432",
            "SPRUCE_GOOSE_TEST_DATABASE": "must_not_be_used",
        }
        result = self.invoke("ci-governed-release", CI_PIPELINE_NUMBER="456", **overrides)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        expected = {**overrides, "SPRUCE_GOOSE_TEST_DATABASE": "spruce_goose_ci_456"}
        for row in self.commands():
            if row["args"][0] in ["ecto.create", "ash.migrate", "test", "ecto.drop"]:
                self.assertEqual(row["env"], expected)

    def test_invalid_pipeline_number_refuses_before_database_commands(self):
        result = self.invoke("ci-governed-release", CI_PIPELINE_NUMBER="../production")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(row["args"][0].startswith("ecto.") for row in self.commands()))

    def test_build_cannot_reuse_the_old_hardcoded_task(self):
        result = self.invoke("ci-governed-release", TEST_MIX_TEST_STATUS="0")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("must identify the governing task", result.stderr)
        self.assertFalse((self.work / "builder-trace").exists())

    def test_check_mode_runs_both_suites_and_cleanup_without_build_task(self):
        result = self.invoke("ci-governed-release", args=("--check",), TEST_MIX_TEST_STATUS="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ci-check=PASS", result.stdout)
        commands = [row["args"] for row in self.commands()]
        self.assertIn(["test"], commands)
        self.assertIn(["test", "--only", "separate_sessions", "--seed", "0", "--max-cases", "1"], commands)
        self.assertEqual(commands[-1], ["ecto.drop", "--force", "--quiet"])
        self.assertFalse((self.work / "builder-trace").exists())
        evidence = self.repo / "ci-evidence"
        self.assertEqual((evidence / "workspace-before.sha256").read_bytes(),
                         (evidence / "workspace-after.sha256").read_bytes())

    def test_check_mode_failure_stays_failure_and_cleans_database(self):
        result = self.invoke("ci-governed-release", args=("--check",))
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertNotIn("ci-check=PASS", result.stdout)
        self.assertEqual(self.commands()[-1]["args"], ["ecto.drop", "--force", "--quiet"])
        self.assertFalse((self.work / "builder-trace").exists())

    def test_unknown_mode_refuses_before_mix_or_evidence(self):
        for args in [("--skip-tests",), ("--check", "--release")]:
            result = self.invoke("ci-governed-release", args=args)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(self.trace.exists())
            self.assertFalse((self.repo / "ci-evidence").exists())

    def test_supplied_task_reaches_builder_unchanged(self):
        task = "tsk-20990101T000000Z-12345678"
        result = self.invoke(
            "ci-governed-release", TEST_MIX_TEST_STATUS="0", SPRUCE_GOOSE_TASK=task,
        )
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertEqual((self.work / "builder-trace").read_text(), f"builder-task={task}\n")


if __name__ == "__main__":
    unittest.main()
