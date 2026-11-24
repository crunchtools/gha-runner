#!/bin/bash
# Tests for deploy/exedore/gha-runner-vm-promote: the script copied into a
# temporary tree with its env file and backup directory pointed there, and a
# stub systemctl first on PATH that logs every call.
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)/deploy/exedore/gha-runner-vm-promote
failures=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
OLD=sha256:$(printf 'a%.0s' {1..64})
NEW=sha256:$(printf 'b%.0s' {1..64})

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }

setup() {
  case=$1
  t=$(mktemp -d -p "$root")
  mkdir -p "$t/bin" "$t/backups"
  printf 'GHA_ORG=crunchtools\nGHA_VM_IMAGE=quay.io/crunchtools/gha-runner@%s\n' "$OLD" > "$t/env"
  sed -e "s#^ENV=.*#ENV=$t/env#" -e "s#/root/.backups#$t/backups#g" "$src" > "$t/promote"
  chmod +x "$t/promote"
  # is-active answers with $t/state (inactive unless a case sets it).
  # shellcheck disable=SC2016 # the stub's own $-expressions run when it does
  printf '#!/bin/bash\necho "$*" >> %q\n[ "$1" = is-active ] && { s=$(cat %q 2>/dev/null || echo inactive); echo "$s"; [ "$s" = active ]; }\nexit 0\n' \
    "$t/calls" "$t/state" > "$t/bin/systemctl"
  chmod +x "$t/bin/systemctl"
  : > "$t/calls"
}
run() { PATH="$t/bin:$PATH" "$t/promote" "$@" >/dev/null 2>&1; }

setup "a digest promotes"
run "$NEW" || fail "exit non-zero"
grep -qx "GHA_VM_IMAGE=quay.io/crunchtools/gha-runner@$NEW" "$t/env" || fail "pin not written"
grep -qx "GHA_ORG=crunchtools" "$t/env" || fail "other settings changed"
ls "$t/backups"/gha-runner-vm.env.* >/dev/null 2>&1 || fail "no backup"
grep -q "GHA_VM_IMAGE=quay.io/crunchtools/gha-runner@$OLD" "$t/backups"/gha-runner-vm.env.* || fail "backup is not the old file"
grep -qx "start --no-block gha-runner-vm-disk" "$t/calls" || fail "disk rebuild not started"

setup "a finished earlier build does not block"
echo active > "$t/state"
run "$NEW" || fail "exit non-zero"
grep -qx "start --no-block gha-runner-vm-disk" "$t/calls" || fail "disk rebuild not started"

for busy in activating deactivating; do
  setup "refuses while the disk service is $busy"
  echo "$busy" > "$t/state"
  status=0; run "$NEW" || status=$?
  [ "$status" -eq 75 ] || fail "exit $status, not 75"
  grep -q "@$OLD" "$t/env" || fail "pin changed"
  ls "$t/backups"/gha-runner-vm.env.* >/dev/null 2>&1 && fail "backup written"
  grep -q "^start" "$t/calls" && fail "build started"
done

for bad in "" "sha256:abc" "sha256:$(printf 'G%.0s' {1..64})" "$NEW; rm -rf /" "quay.io/x@$NEW" "$NEW extra"; do
  setup "refuses '$bad'"
  # shellcheck disable=SC2086 # "$NEW extra" must arrive as two arguments
  if [ "$bad" = "$NEW extra" ]; then run $bad && fail "accepted"; else run "$bad" && fail "accepted"; fi
  grep -q "@$OLD" "$t/env" || fail "pin changed"
  [ -s "$t/calls" ] && fail "systemctl called"
done

setup "no arguments"
run && fail "accepted"
[ -s "$t/calls" ] && fail "systemctl called"

setup "a missing env file"
rm "$t/env"
run "$NEW" && fail "accepted"
grep -q "^start" "$t/calls" && fail "build started"

[ "$failures" -eq 0 ] && echo PASS || { echo "$failures failure(s)" >&2; exit 1; }
