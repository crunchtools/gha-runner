#!/usr/bin/env python3
"""Fail once any grype ignore rule is past its expiry, or has none.

grype's ignore rules have no expiry field, so a rule's expiry is an
`EXPIRES YYYY-MM-DD` comment, and this is what makes the comment bind: CI runs
it on every change and daily, so a stale ignore turns main red instead of
quietly hiding a vulnerability for good.

The file is parsed as YAML, so every entry under `ignore:` counts, whatever it
matches on (`vulnerability`, `package`, `fix-state`) and however it is written
(block or flow style). Each entry is governed by the nearest EXPIRES at or above
its first line, so one header date can cover the entries under it. An entry
with no EXPIRES above it, or under one whose date is malformed or not a real
calendar date, fails: the number of entries must equal the number of dated ones.

grype also auto-loads `.grype.yml` and `.grype/config.yaml`; ignores there would
escape review here, so their existence fails too (and they are checked).

Usage: grype_expiry.py [repo root] [today as YYYY-MM-DD, default UTC now]
Exit: 0 all dated and current, 1 a finding, 2 the check could not run.
"""

import datetime
import re
import sys
from pathlib import Path

import yaml

PRIMARY = ".grype.yaml"
CANDIDATES = (PRIMARY, ".grype.yml", ".grype/config.yaml", ".grype/config.yml")
DIRECTIVE = re.compile(r"(?<![A-Za-z])EXPIRES(?![A-Za-z])")
DATE = re.compile(r"EXPIRES (\d{4}-\d{2}-\d{2})(?!\d)")


def calendar_date(text: str) -> datetime.date | None:
    try:
        day = datetime.date.fromisoformat(text)
    except ValueError:
        return None
    return day if day.isoformat() == text else None


def directives(text: str) -> list[tuple[int, datetime.date | None]]:
    """(line, date) for every EXPIRES comment; date is None when malformed."""
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        if DIRECTIVE.search(line):
            match = DATE.search(line)
            found.append((number, calendar_date(match[1]) if match else None))
    return found


def entry_lines(text: str) -> list[int]:
    """The first line of each entry under the top-level `ignore:` key."""
    root = yaml.compose(text)
    if root is None:
        return []
    if not isinstance(root, yaml.MappingNode):
        raise ValueError("the top level is not a mapping")
    for key, value in root.value:
        if key.value != "ignore":
            continue
        if isinstance(value, yaml.ScalarNode) and value.value in ("", "~", "null"):
            return []
        if not isinstance(value, yaml.SequenceNode):
            raise ValueError("`ignore` is not a list")
        return [item.start_mark.line + 1 for item in value.value]
    return []


def check(path: Path, name: str, today: datetime.date) -> list[str]:
    text = path.read_text()
    dates = directives(text)
    errors = []
    for line in entry_lines(text):
        governing = [day for at, day in dates if at <= line]
        if not governing:
            errors.append(f"{name}:{line}: this grype ignore has no EXPIRES date above it")
        elif governing[-1] is None:
            errors.append(f"{name}:{line}: the EXPIRES governing this ignore has no valid YYYY-MM-DD date")
        elif governing[-1] < today:
            errors.append(f"{name}:{line}: this grype ignore expired on {governing[-1]}; fix or re-justify it")
        else:
            print(f"{name}:{line} expires {governing[-1]}")
    return errors


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    today = calendar_date(argv[2]) if len(argv) > 2 else datetime.datetime.now(datetime.UTC).date()
    if today is None:
        print(f"::error::today must be a calendar date as YYYY-MM-DD, not {argv[2]!r}", file=sys.stderr)
        return 2
    errors = []
    for name in CANDIDATES:
        path = root / name
        if not path.exists():
            continue
        if name != PRIMARY:
            errors.append(f"{name}: grype auto-loads this file too; keep every ignore in {PRIMARY}")
        try:
            errors += check(path, name, today)
        except OSError as error:
            print(f"::error::cannot read {name}: {error}", file=sys.stderr)
            return 2
        except (yaml.YAMLError, ValueError) as error:
            errors.append(f"{name}: not a grype config grype-expiry can read: {error}")
    for error in errors:
        print(f"::error::{error}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
