#!/bin/bash
# Tests for grype-expiry.sh, with fixture files and a fixed `today`.
set -euo pipefail
cd "$(dirname "$0")"
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
fail=0

expect() {  # expect <exit code> <name> <today> <file content>
  printf '%s' "$4" > "$dir/g.yaml"
  set +e
  ./grype-expiry.sh "$dir/g.yaml" "$3" >/dev/null 2>&1
  got=$?
  set -e
  if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2: exit $got, want $1"; fail=1; fi
}

one=$'# EXPIRES 2026-12-18\nignore:\n  - vulnerability: A\n  - vulnerability: B\n'
expect 0 "future date"            2026-11-18 "$one"
expect 0 "on the expiry day"      2026-12-18 "$one"
expect 1 "day after expiry"       2026-12-19 "$one"
expect 1 "ignore with no date"    2026-11-18 $'ignore:\n  - vulnerability: A\n'
expect 1 "second entry undated"   2026-11-18 $'ignore:\n  - vulnerability: A\n  # EXPIRES 2026-12-18\n  - vulnerability: B\n'
expect 1 "later date governs, past" 2026-12-02 $'# EXPIRES 2027-01-01\nignore:\n  - vulnerability: A\n  # EXPIRES 2026-12-01\n  - vulnerability: B\n'
expect 1 "not a calendar date"    2026-11-18 $'# EXPIRES 2099-99-99\nignore:\n  - vulnerability: A\n'
expect 1 "malformed later EXPIRES" 2026-11-18 $'# EXPIRES 2027-01-01\nignore:\n  - vulnerability: A\n  # EXPIRES soon\n  - vulnerability: B\n'
expect 1 "EXPIRES with long year"  2026-11-18 $'# EXPIRES 2026-12-188\nignore:\n  - vulnerability: A\n'
expect 0 "no ignores at all"      2026-11-18 $'# nothing ignored\n'
expect 0 "no file"                2026-11-18 ''
expect 2 "today not a date"       not-a-date "$one"
expect 2 "today not canonical"    2026-1-5   "$one"
rm -f "$dir/g.yaml"
set +e; ./grype-expiry.sh "$dir/absent.yaml" 2026-11-18 >/dev/null; got=$?; set -e
[ "$got" = 0 ] && echo "ok   absent file" || { echo "FAIL absent file: exit $got"; fail=1; }
if [ "$(id -u)" != 0 ]; then
  printf '%s' "$one" > "$dir/locked.yaml" && chmod 000 "$dir/locked.yaml"
  set +e; ./grype-expiry.sh "$dir/locked.yaml" 2026-11-18 >/dev/null 2>&1; got=$?; set -e
  [ "$got" = 2 ] && echo "ok   unreadable file" || { echo "FAIL unreadable file: exit $got, want 2"; fail=1; }
else
  echo "skip unreadable file (root reads it anyway)"
fi
exit "$fail"
