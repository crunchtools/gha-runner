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
  sed -e "s#^ENV=.*#ENV=$t/env#" -e "s#^LOCK=.*#LOCK=$t/lock#" \
    -e "s#/root/.backups#$t/backups#g" "$src" > "$t/promote"
  chmod +x "$t/promote"
  # systemctl: is-active answers with $t/state (inactive unless a case sets
  # it), `start` bumps the ExecMainStart timestamp that `show` reports.
  cat > "$t/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >> "$t/calls"
case \$1 in
  is-active) s=\$(cat "$t/state" 2>/dev/null || echo inactive); echo "\$s"; [ "\$s" = active ] ;;
  show) cat "$t/started" 2>/dev/null || echo 0 ;;
  start) echo \$((\$(cat "$t/started" 2>/dev/null || echo 0) + 1)) > "$t/started" ;;
esac
STUB
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

for busy in activating deactivating reloading; do
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

setup "systemctl is-active says nothing"
printf '#!/bin/bash\nexit 1\n' > "$t/bin/systemctl"
run "$NEW" && fail "accepted"
grep -q "@$OLD" "$t/env" || fail "pin changed"

setup "refuses while another promote holds the lock"
status=0
{ flock 9; run "$NEW" || status=$?; } 9>"$t/lock"
[ "$status" -eq 75 ] || fail "exit $status, not 75"
grep -q "@$OLD" "$t/env" || fail "pin changed"
grep -q "^start" "$t/calls" && fail "build started"

setup "two promotes in one second keep both backups"
run "$NEW" || fail "first exit non-zero"
run "$OLD" || fail "second exit non-zero"
[ "$(find "$t/backups" -name 'gha-runner-vm.env.*' | wc -l)" -eq 2 ] || fail "a backup was overwritten"

setup "the message says the build started"
out=$(PATH="$t/bin:$PATH" "$t/promote" "$NEW" 2>&1) || fail "exit non-zero"
[[ $out == "promoted "*"build started"* ]] || fail "said: $out"

setup "a start still queued after 30 polls says so"
# The job never starts: `start` leaves the timestamp alone, and sleep returns at once.
sed -i 's#^  start) .*#  start) ;;#' "$t/bin/systemctl"
printf '#!/bin/bash\necho "sleep $*" >> %q\n' "$t/calls" > "$t/bin/sleep"
chmod +x "$t/bin/sleep"
out=$(PATH="$t/bin:$PATH" "$t/promote" "$NEW" 2>&1) || fail "exit non-zero"
[[ $out == "pinned "*"queued, not started yet"* ]] || fail "said: $out"
[ "$(grep -c '^sleep ' "$t/calls")" -eq 30 ] || fail "did not poll 30 times"
grep -qx "GHA_VM_IMAGE=quay.io/crunchtools/gha-runner@$NEW" "$t/env" || fail "pin not written"

setup "no arguments"
run && fail "accepted"
[ -s "$t/calls" ] && fail "systemctl called"

setup "a missing env file"
rm "$t/env"
run "$NEW" && fail "accepted"
grep -q "^start" "$t/calls" && fail "build started"

[ "$failures" -eq 0 ] && echo PASS || { echo "$failures failure(s)" >&2; exit 1; }
