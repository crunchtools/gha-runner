#!/bin/bash
# Tests for deploy/exedore/gha-runner-vm-disk: the script copied into a
# temporary tree with its env file and cache directory pointed there, and a stub
# podman first on PATH that logs every call, one per line. The point is the
# bootc-image-builder run: its working store must be bound at /store from the
# build's work directory, not left as an anonymous /var volume.
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)/deploy/exedore/gha-runner-vm-disk
failures=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
PIN=quay.io/crunchtools/gha-runner@sha256:$(printf 'a%.0s' {1..64})

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }

setup() {
  case=$1
  t=$(mktemp -d -p "$root")
  mkdir -p "$t/bin"
  printf 'GHA_VM_IMAGE=%s\nGHA_VM_BIB=quay.io/centos-bootc/bootc-image-builder:latest\n' "$PIN" > "$t/env"
  sed -e "s#/srv/gha-runner/config/gha-runner-vm.env#$t/env#" -e "s#^DIR=.*#DIR=$t/vm#" "$src" > "$t/disk"
  chmod +x "$t/disk"
  # run creates <output>/qcow2/disk.qcow2, <output> being the host side of -v X:/output.
  cat > "$t/bin/podman" <<'STUB'
#!/bin/bash
echo "$*" >> "$CALLS"
if [ "$1" = run ]; then
  while [ $# -gt 0 ]; do
    case $1 in -v) case $2 in *:/output) out=${2%:/output}; mkdir -p "$out/qcow2"; : > "$out/qcow2/disk.qcow2";; esac;; esac
    shift
  done
fi
exit 0
STUB
  chmod +x "$t/bin/podman"
  : > "$t/calls"
}
run() { CALLS="$t/calls" PATH="$t/bin:$PATH" "$t/disk" >/dev/null 2>&1; }

setup "a fresh build binds the work store at /store"
run || fail "exit non-zero"
grep -Eq "^run .* -v $t/vm/build\.[^/ ]+/store:/store( |$)" "$t/calls" || fail "no -v <work>/store:/store on podman run"
[ "$(cat "$t/vm/base.image")" = "$PIN" ] || fail "pin not written to base.image"
[ -f "$t/vm/base.qcow2" ] || fail "base.qcow2 missing"
compgen -G "$t/vm/build.*" >/dev/null && fail "build directory left behind"

setup "a current disk does not build"
mkdir -p "$t/vm"
echo "$PIN" > "$t/vm/base.image"
run || fail "exit non-zero"
grep -q '^run ' "$t/calls" && fail "podman run called"
[ -f "$t/vm/base.qcow2" ] && fail "disk touched"

[ "$failures" -eq 0 ] && echo PASS || { echo "$failures failure(s)" >&2; exit 1; }
