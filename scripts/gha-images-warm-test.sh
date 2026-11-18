#!/bin/bash
# Tests for deploy/exedore/gha-images-warm (#34): a stub podman first on PATH,
# a temporary store, list and HOME, and the script run as the unit runs it.
#
# The stub answers the nested podman the script drives through `store`: it
# drops everything up to the store's last global option, logs the command
# left (images, rmi, pull) to store-calls, and answers from two files --
# `dangling`, the store's dangling IDs (rmi removes one), and `fail-pulls`,
# images whose pull fails. `podman unshare` runs its command for real, so the
# chmod is checked on disk.
set -euo pipefail

warm=$(cd "$(dirname "$0")/.." && pwd)/deploy/exedore/gha-images-warm
failures=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }
expect() { local what=$1; shift; "$@" || fail "$what"; }

# setup <case name> -- a fresh temporary tree, with the list holding two images.
setup() {
  case=$1
  t=$(mktemp -d -p "$root")
  mkdir -p "$t/bin" "$t/store" "$t/home"
  touch "$t/dangling" "$t/fail-pulls" "$t/store-calls"
  printf '# a comment\n\nquay.io/x/one:latest\n   # indented comment\nquay.io/x/two:main\n' > "$t/list"
  cat > "$t/bin/podman" <<'STUB'
#!/bin/bash
set -euo pipefail
case $1 in
  unshare) shift; exec "$@" ;;
  run) ;;
  *) echo "stub podman: unexpected $*" >&2; exit 99 ;;
esac
while [ $# -gt 0 ] && [ "$1" != overlay.force_mask=shared ]; do shift; done
[ $# -gt 1 ] || { echo "stub podman: no store command" >&2; exit 99; }
shift
echo "$*" >> "$STUB/store-calls"
case $1 in
  images) cat "$STUB/dangling" ;;
  rmi) grep -vx "$2" "$STUB/dangling" > "$STUB/dangling.new" || true
       mv "$STUB/dangling.new" "$STUB/dangling" ;;
  pull) if grep -qx "${!#}" "$STUB/fail-pulls"; then exit 125; fi
        echo "sha256:pulled" ;;
  *) echo "stub podman: unexpected store $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$t/bin/podman"
}

# run_warm -- run the script; sets rc, and leaves stdout and stderr in files.
run_warm() {
  rc=0
  PATH="$t/bin:$PATH" STUB="$t" HOME="$t/home" \
    GHA_IMAGES_STORE="$t/store" GHA_IMAGES_LIST="$t/list" \
    bash "$warm" > "$t/out" 2> "$t/err" || rc=$?
}

called() { grep -qx -- "$1" "$t/store-calls"; }
not_called() { ! grep -q -- "$1" "$t/store-calls"; }
said() { grep -qx -- "$2" "$t/$1"; }

setup "empty list"
printf '# nothing\n\n   \n' > "$t/list"
run_warm
expect "exits 1" [ "$rc" -eq 1 ]
expect "says the list is empty" grep -q 'lists no images' "$t/err"
expect "runs no podman" [ ! -s "$t/store-calls" ]

setup "all pulls succeed, nothing pending"
run_warm
expect "exits 0, got $rc" [ "$rc" -eq 0 ]
expect "pulls the first image" called "pull -q quay.io/x/one:latest"
expect "pulls the second image" called "pull -q quay.io/x/two:main"
expect "skips comments and blanks" [ "$(grep -c '^pull' "$t/store-calls")" -eq 2 ]
expect "reports each warm" said out "warm quay.io/x/two:main"
expect "no prune without a pending file" not_called rmi
expect "lists dangling exactly once, after the pulls" \
  [ "$(grep -n '^images' "$t/store-calls" | cut -d: -f1)" = 3 ]

setup "prune pending IDs"
printf 'sha256:still\nsha256:retagged\nsha256:last\n' > "$t/home/prune-next-run"
printf 'sha256:still\nsha256:last\nsha256:new\n' > "$t/dangling"
run_warm
expect "exits 0, got $rc" [ "$rc" -eq 0 ]
expect "removes a pending ID still dangling" called "rmi sha256:still"
expect "removes the last pending ID" called "rmi sha256:last"
expect "keeps a pending ID that is tagged again" not_called "rmi sha256:retagged"
expect "never removes an ID that just went dangling" not_called "rmi sha256:new"
expect "reports the prune" said out "pruned sha256:still"
expect "prunes before pulling" [ "$(grep -n '^pull' "$t/store-calls" | head -1 | cut -d: -f1)" -gt 3 ]
expect "the next run's pending list is what is dangling now" \
  [ "$(cat "$t/home/prune-next-run")" = "sha256:new" ]

setup "a pull fails"
echo quay.io/x/one:latest > "$t/fail-pulls"
echo sha256:old > "$t/dangling"
chmod 0700 "$t/store"
run_warm
expect "exits 1, got $rc" [ "$rc" -eq 1 ]
expect "reports the failure" said err "FAILED quay.io/x/one:latest"
expect "still pulls the rest" said out "warm quay.io/x/two:main"
expect "still writes the pending list" [ "$(cat "$t/home/prune-next-run")" = "sha256:old" ]
expect "still opens the store" [ "$(stat -c %a "$t/store")" = 755 ]

setup "store permissions"
mkdir -p "$t/store/overlay-images" "$t/store/overlay/l"
echo '{}' > "$t/store/overlay-images/images.json"
touch "$t/store/overlay-images/images.lock"
chmod 0600 "$t/store/overlay-images/images.json" "$t/store/overlay-images/images.lock"
printf '#!/bin/sh\n' > "$t/store/overlay/l/tool" && chmod 0700 "$t/store/overlay/l/tool"
chmod 0700 "$t/store/overlay-images" "$t/store/overlay/l" "$t/store/overlay"
run_warm
expect "exits 0, got $rc" [ "$rc" -eq 0 ]
for d in overlay-images overlay overlay/l; do
  expect "directory $d is readable and searchable" [ "$(stat -c %a "$t/store/$d")" = 755 ]
done
expect "metadata is readable, not made executable" [ "$(stat -c %a "$t/store/overlay-images/images.json")" = 644 ]
expect "the lock file can be opened" [ "$(stat -c %a "$t/store/overlay-images/images.lock")" = 644 ]
expect "an executable stays executable for all" [ "$(stat -c %a "$t/store/overlay/l/tool")" = 755 ]
expect "reports the store's size" grep -q "$t/store" "$t/out"

if [ "$failures" -gt 0 ]; then
  echo "gha-images-warm: $failures check(s) failed" >&2
  exit 1
fi
echo "gha-images-warm: all checks passed"
