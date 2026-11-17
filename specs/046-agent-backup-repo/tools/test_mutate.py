#!/usr/bin/env python3
"""Check the mutation runner's verdicts without launching bats or Docker."""
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]


class FakeProcess:
    pid = 99999999

    def __init__(self, tap, timeout=False):
        self.tap = tap.encode()
        self.timeout = timeout
        self.returncode = 1 if "not ok " in tap else 0

    def communicate(self, timeout=None):
        if self.timeout and timeout is not None:
            self.timeout = False
            raise __import__("subprocess").TimeoutExpired("fake-bats", timeout)
        return self.tap, None


class VerdictTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("mutation_runner_test", HERE / "mutate.py")
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)
        self.tmp = tempfile.TemporaryDirectory(prefix="br046-runner-test-")
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name)
        self.runner.OUT = str(root / "results")
        self.runner.MUT = str(root / "copies")
        self.runner.BASE = str(root / "base")
        pathlib.Path(self.runner.OUT).mkdir()
        self.ids = []
        for rel in self.runner.FILES.values():
            self.ids.extend(re.findall(r'^@test "(T[A-Z]\d{2}):', (REPO / rel).read_text(), re.M))
        self.assertEqual(len(self.ids), 124)

    def tap(self, passing=None, skipped=False, ids=None, plan=None):
        ids = self.ids if ids is None else ids
        passing = set(ids if passing is None else passing)
        lines = ["1..%d" % (len(ids) if plan is None else plan)]
        for number, test in enumerate(ids, 1):
            lines.append("%s %d %s: fixture%s" % (
                "ok" if test in passing else "not ok", number, test,
                " # skip missing dependency" if skipped else ""))
        return "\n".join(lines) + "\n"

    def copy(self, source, destination, tests_from=None):
        dest = pathlib.Path(destination)
        for rel in self.runner.FILES.values():
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((REPO / rel).read_text())

    def patches(self, tap, timeout=False):
        stack = __import__("contextlib").ExitStack()
        stack.enter_context(mock.patch.object(self.runner, "copy_tree", side_effect=self.copy))
        stack.enter_context(mock.patch.object(self.runner, "apply_subs"))
        stack.enter_context(mock.patch.object(self.runner.subprocess, "Popen",
            side_effect=lambda *a, **k: FakeProcess(tap, timeout)))
        stack.enter_context(mock.patch.object(self.runner.os, "killpg"))
        return stack

    def test_control_failure_returns_nonzero(self):
        tap = self.tap(passing=set(self.ids) - {"TD01"})
        with self.patches(tap), mock.patch.object(sys, "argv", ["mutate.py", "--control"]):
            self.assertNotEqual(self.runner.main(), 0)

    def test_control_skips_return_nonzero(self):
        with self.patches(self.tap(skipped=True)), mock.patch.object(sys, "argv", ["mutate.py", "--control"]):
            self.assertNotEqual(self.runner.main(), 0)

    def test_complete_green_control_returns_zero(self):
        with self.patches(self.tap()), mock.patch.object(sys, "argv", ["mutate.py", "--control"]):
            self.assertEqual(self.runner.main(), 0)

    def test_timeout_is_never_a_caught_mutation(self):
        with self.patches(self.tap(passing=set(), ids=["TD01"]), timeout=True):
            row = self.runner.run_row("M1", "fixture", [], ["TD01"], 1)
        self.assertNotEqual(row["verdict"], "cazada")

    def test_m0_missing_results_cannot_pass(self):
        ids = self.runner.M0_EXPECT_PASS
        with self.patches(self.tap(ids=ids, plan=124)):
            row = self.runner.run_row("M0", "fixture", [], [], 1)
        self.assertNotEqual(row["verdict"], "ok")

    def test_complete_m0_preserves_expected_passes(self):
        with self.patches(self.tap(passing=self.runner.M0_EXPECT_PASS)):
            row = self.runner.run_row("M0", "fixture", [], [], 1)
        self.assertEqual(row["verdict"], "ok")

    def test_completed_expected_failure_is_caught(self):
        with self.patches(self.tap(passing=set(), ids=["TD01"])):
            row = self.runner.run_row("M1", "fixture", [], ["TD01"], 1)
        self.assertEqual(row["verdict"], "cazada")

    def test_m0_test_overlay_excludes_ignored_files(self):
        root = pathlib.Path(self.tmp.name)
        base, final, dest = (root / name for name in ("base-source", "final-source", "overlay"))
        for path in (base, final):
            path.mkdir()
            subprocess.run(["git", "init", "-q", str(path)], check=True)
        (base / "README.md").write_text("base\n")
        (final / ".gitignore").write_text("tests/ignored.txt\n")
        (final / "tests").mkdir()
        (final / "tests/kept.txt").write_text("test fixture\n")
        (final / "tests/ignored.txt").write_text("local residue\n")
        self.runner.copy_tree(str(base), str(dest), tests_from=str(final))
        self.assertFalse((dest / "tests/ignored.txt").exists())
        self.assertEqual((dest / "tests/kept.txt").read_text(), "test fixture\n")

    def test_unknown_selection_returns_nonzero(self):
        with mock.patch.object(sys, "argv", ["mutate.py", "--only", "M168"]):
            self.assertNotEqual(self.runner.main(), 0)

    def test_mixed_unknown_selection_runs_nothing(self):
        row = {"verdict": "cazada", "bash": {
            "5": {"fell": ["TD01"], "secs": 0},
            "3.2": {"fell": ["TD01"], "secs": 0}}}
        with mock.patch.object(sys, "argv", ["mutate.py", "--only", "M1,M168"]), \
                mock.patch.object(self.runner, "run_row", return_value=row) as run, \
                mock.patch.object(self.runner, "write_results"):
            self.assertNotEqual(self.runner.main(), 0)
            self.assertFalse(run.called)


if __name__ == "__main__":
    unittest.main()
