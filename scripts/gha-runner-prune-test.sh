#!/bin/bash
# Tests for deploy/exedore/gha-runner-prune (a315): a stub podman first on
# PATH, a temporary store, list and HOME, and the script run as the cached
# unit runs it.
#
# The stub answers from `images`, one image per line: `<id> <ref> <old>`,
# where old=1 means created before the prune age. `inspect` finds a ref's ID,
# `images --filter until=` lists the old rows the way podman does (ID with its
# sha256: prefix), and every call is logged to `calls`. A ref in `fail-rmi`
# refuses removal.
set -euo pipefail

prune=$(cd "$(dirname "$0")/.." && pwd)/deploy/exedore/gha-runner-prune
failures=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }
expect() { local what=$1; shift; "$@" || fail "$what"; }

# setup <case name> -- a fresh temporary tree. Images: one old and listed, a
# second tag of it, one old and unlisted, one new, and an old untagged layer.
setup() {
  case=$1
  t=$(mktemp -d -p "$root")
  mkdir -p "$t/bin" "$t/store"
  touch "$t/calls" "$t/fail-rmi"
  cat > "$t/images" <<'ROWS'
aaa quay.io/crunchtools/sdlc:latest 1
aaa localhost/sdlc-alias:kept 1
bbb quay.io/x/stale:old 1
ccc quay.io/x/fresh:new 0
ddd <none>:<none> 1
ROWS
  printf '# a comment\n\nquay.io/crunchtools/sdlc:latest\n  # indented\n' > "$t/list"
  cat > "$t/bin/podman" <<STUB
#!/bin/bash
echo "\$*" >> "$t/calls"
case "\$1 \${2:-}" in
  "image inspect")
    ref=\${*: -1}
    awk -v r="\$ref" '\$2 == r { print \$1; found=1; exit } END { exit !found }' "$t/images" || exit 125 ;;
  "images "*)
    awk '\$3 == 1 { print "sha256:" \$1, \$2 }' "$t/images" ;;
  "rmi "*)
    grep -qxF "\$2" "$t/fail-rmi" && exit 1
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$t/bin/podman"
}

run() {
  PATH="$t/bin:$PATH" HOME="$t" PRUNE_STORE="$t/store" bash "$prune" "$@" > "$t/out" 2> "$t/err"
}

removed() { grep -qx "rmi $1" "$t/calls"; }

setup "keep list, age and untagged"
expect "the script succeeds" run "$t/list"
expect "an old unlisted image is removed" removed quay.io/x/stale:old
expect "an old listed image is kept" bash -c '! grep -qx "rmi quay.io/crunchtools/sdlc:latest" "$0"' "$t/calls"
expect "another tag of a listed image is kept" bash -c '! grep -qx "rmi localhost/sdlc-alias:kept" "$0"' "$t/calls"
expect "a new image is kept" bash -c '! grep -q "rmi quay.io/x/fresh:new" "$0"' "$t/calls"
expect "untagged layers are left to image prune" bash -c '! grep -q "rmi <none>" "$0"' "$t/calls"
expect "the age reaches podman" grep -q -- "--filter until=168h" "$t/calls"
expect "dangling images and build cache are pruned" grep -qx "image prune -f --build-cache" "$t/calls"
expect "build containers are pruned" grep -qx "system prune -f --build" "$t/calls"
expect "reports what it removed" grep -q "removed 1 tagged image" "$t/out"

setup "PRUNE_AGE"
PRUNE_AGE=72h expect "the script succeeds" run "$t/list"
expect "the override reaches podman" grep -q -- "--filter until=72h" "$t/calls"

setup "missing list"
expect "the script succeeds" run "$t/no-such-list"
expect "it warns" grep -q "missing or empty" "$t/err"
expect "nothing is kept beyond age, so the listed image goes too" removed quay.io/crunchtools/sdlc:latest
expect "it still prunes" grep -qx "image prune -f --build-cache" "$t/calls"

setup "a removal fails"
echo quay.io/x/stale:old > "$t/fail-rmi"
expect "the script still succeeds" run "$t/list"
expect "it says which" grep -q "could not remove quay.io/x/stale:old" "$t/err"
expect "it still prunes" grep -qx "system prune -f --build" "$t/calls"

if [ "$failures" -gt 0 ]; then
  echo "gha-runner-prune: $failures check(s) failed" >&2
  exit 1
fi
echo "gha-runner-prune: all checks passed"
