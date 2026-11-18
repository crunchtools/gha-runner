"""Tests for grype_expiry.py, with fixture repos and a fixed `today`."""

import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import grype_expiry  # beside this file, which is first on sys.path when run as a script

TODAY = "2026-11-18"
DATED = "# EXPIRES 2026-12-18\nignore:\n  - vulnerability: A\n  - vulnerability: B\n"


class GrypeExpiry(unittest.TestCase):
    def run_on(self, files: dict[str, str], today: str = TODAY) -> int:
        with tempfile.TemporaryDirectory() as root:
            for name, text in files.items():
                path = Path(root, name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            return grype_expiry.main(["grype_expiry.py", root, today])

    def test_dates(self) -> None:
        self.assertEqual(self.run_on({".grype.yaml": DATED}), 0)
        self.assertEqual(self.run_on({".grype.yaml": DATED}, "2026-12-18"), 0)
        self.assertEqual(self.run_on({".grype.yaml": DATED}, "2026-12-19"), 1)

    def test_every_entry_needs_a_date(self) -> None:
        self.assertEqual(self.run_on({".grype.yaml": "ignore:\n  - vulnerability: A\n"}), 1)
        late = "ignore:\n  - vulnerability: A\n  # EXPIRES 2026-12-18\n  - vulnerability: B\n"
        self.assertEqual(self.run_on({".grype.yaml": late}), 1)

    def test_the_nearest_date_governs(self) -> None:
        two = "# EXPIRES 2027-01-01\nignore:\n  - vulnerability: A\n  # EXPIRES 2026-12-01\n  - vulnerability: B\n"
        self.assertEqual(self.run_on({".grype.yaml": two}, "2026-12-02"), 1)

    def test_malformed_dates_fail(self) -> None:
        for directive in ("EXPIRES soon", "EXPIRES 2099-99-99", "EXPIRES 2026-12-188", "EXPIRES 2026-12-18oops"):
            text = f"# EXPIRES 2027-01-01\nignore:\n  - vulnerability: A\n  # {directive}\n  - vulnerability: B\n"
            self.assertEqual(self.run_on({".grype.yaml": text}), 1, directive)

    def test_entries_that_name_no_vulnerability_count(self) -> None:
        for entry in (
            "  - package:\n      name: x\n    vulnerability: A\n",
            "  - fix-state: unknown\n",
            "  - package: {name: x}\n",
        ):
            self.assertEqual(self.run_on({".grype.yaml": "ignore:\n" + entry}), 1, entry)
            self.assertEqual(self.run_on({".grype.yaml": "# EXPIRES 2026-12-18\nignore:\n" + entry}), 0, entry)

    def test_only_comments_are_directives(self) -> None:
        for value in ('"EXPIRES 2027-01-01"', '"x # EXPIRES 2027-01-01"', "EXPIRES-2027-01-01"):
            text = f"note: {value}\nignore:\n  - vulnerability: A\n"
            self.assertEqual(self.run_on({".grype.yaml": text}), 1, value)
        trailing = "ignore:\n  - vulnerability: A  # EXPIRES 2026-12-18 (reason)\n"
        self.assertEqual(self.run_on({".grype.yaml": trailing}), 0)

    def test_flow_style(self) -> None:
        flow = "ignore: [{vulnerability: A}, {fix-state: unknown}]\n"
        self.assertEqual(self.run_on({".grype.yaml": flow}), 1)
        self.assertEqual(self.run_on({".grype.yaml": "# EXPIRES 2026-12-18\n" + flow}), 0)

    def test_nothing_to_expire(self) -> None:
        self.assertEqual(self.run_on({}), 0)
        self.assertEqual(self.run_on({".grype.yaml": "# nothing ignored\n"}), 0)
        for empty in ("ignore: []\n", "ignore:\n", "ignore: ~\n", "ignore: null\n", "ignore: Null\n", "ignore: NULL\n"):
            self.assertEqual(self.run_on({".grype.yaml": empty}), 0, empty)
        for quoted in ('ignore: "null"\n', "ignore: '~'\n", 'ignore: ""\n'):  # strings, not null
            self.assertEqual(self.run_on({".grype.yaml": quoted}), 1, quoted)

    def test_other_configs_grype_loads_fail(self) -> None:
        for name in (".grype.yml", ".grype/config.yaml", ".grype/config.yml"):
            self.assertEqual(self.run_on({".grype.yaml": DATED, name: DATED}), 1, name)

    def test_unreadable_or_odd_input(self) -> None:
        self.assertEqual(self.run_on({".grype.yaml": "ignore: {vulnerability: A}\n"}), 1)
        self.assertEqual(self.run_on({".grype.yaml": "ignore: [\n"}), 1)
        self.assertEqual(self.run_on({".grype.yaml": "ignore\n"}), 1)
        self.assertEqual(self.run_on({".grype.yaml": "ignore: []\nignore:\n  - vulnerability: A\n"}), 1)
        self.assertEqual(self.run_on({".grype.yaml": "- vulnerability: A\n"}), 1)
        aliased = (
            "# EXPIRES 2026-12-18\nbase: &x {vulnerability: A}\nignore:\n  - vulnerability: B\n"
            "  # EXPIRES 2026-01-01\n  - *x\n"
        )
        self.assertEqual(self.run_on({".grype.yaml": aliased}), 1)
        self.assertEqual(self.run_on({".grype.yaml": DATED}, "not-a-date"), 2)
        self.assertEqual(self.run_on({".grype.yaml": DATED}, "2026-1-5"), 2)
        self.assertEqual(self._read_fails(), 2)
        if os.geteuid() != 0:
            with tempfile.TemporaryDirectory() as root:
                path = Path(root, ".grype.yaml")
                path.write_text(DATED)
                path.chmod(0)
                self.assertEqual(grype_expiry.main(["grype_expiry.py", root, TODAY]), 2)

    def _read_fails(self) -> int:
        with tempfile.TemporaryDirectory() as root:
            Path(root, ".grype.yaml").write_text(DATED)
            with mock.patch.object(Path, "read_text", side_effect=PermissionError("denied")):
                return grype_expiry.main(["grype_expiry.py", root, TODAY])

    def test_findings_name_the_entry_line(self) -> None:
        text = "# EXPIRES 2026-12-18\nignore:\n  - vulnerability: A\n  # EXPIRES 2026-01-01\n  - package: {name: x}\n"
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.run_on({".grype.yaml": text}), 1)
        self.assertIn(".grype.yaml:3 expires 2026-12-18", out.getvalue())
        self.assertIn("::error::.grype.yaml:5: this grype ignore expired on 2026-01-01", out.getvalue())
        undated = io.StringIO()
        with contextlib.redirect_stdout(undated):
            self.run_on({".grype.yaml": "x: 1\nignore:\n  - fix-state: unknown\n"})
        self.assertIn(".grype.yaml:3: this grype ignore has no EXPIRES date above it", undated.getvalue())

    def test_this_repos_file(self) -> None:
        repo = Path(__file__).parent.parent
        self.assertEqual(grype_expiry.main(["grype_expiry.py", str(repo), TODAY]), 0)


if __name__ == "__main__":
    unittest.main()
