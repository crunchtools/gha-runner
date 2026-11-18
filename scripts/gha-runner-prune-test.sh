#!/bin/bash
# Tests for deploy/exedore/gha-runner-prune (a315): a stub podman first on
# PATH, a temporary store, list and HOME, and the script run as the cached
# unit runs it.
#
# The stub answers from `images`, one name per line:
# `<id> <repo> <tag> <digest> <old>`, where old=1 means created before the
# prune age and tag <none> is an image pulled by digest only. `exists` and
# `inspect` find a ref given as repo:tag or repo@digest, `images --filter
# until=` lists the old rows the way podman does (ID with its sha256: prefix),
# and every call is logged to `calls`. A ref in `fail-rmi` refuses removal.
set -euo pipefail

prune=$(cd "$(dirname "$0")/.." && pwd)/deploy/exedore/gha-runner-prune
failures=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }
expect() { local what=$1; shift; "$@" || fail "$what"; }

# setup <case name> -- a fresh temporary tree. Images: one old and listed, a
# second tag of it, one old and unlisted, one new, an old dangling layer, and
# two old images pulled by digest only (repo:<none>, not dangling): any one,
# and the runner image a unit passes in PRUNE_KEEP.
setup() {
  case=$1
  t=$(mktemp -d -p "$root")
  mkdir -p "$t/bin" "$t/store"
  touch "$t/calls" "$t/fail-rmi" "$t/store-broken" "$t/images-broken" "$t/inspect-broken"
  cat > "$t/images" <<'ROWS'
aaa quay.io/crunchtools/sdlc latest sha256:d1 1
aaa localhost/sdlc-alias kept sha256:d1 1
bbb quay.io/x/stale old sha256:d2 1
ccc quay.io/x/fresh new sha256:d3 0
ddd <none> <none> sha256:d4 1
eee docker.io/library/busybox <none> sha256:d5 1
fff quay.io/crunchtools/gha-runner <none> sha256:d6 1
ROWS
  printf '# a comment\n\nquay.io/crunchtools/sdlc:latest\n  # indented\n' > "$t/list"
  cat > "$t/bin/podman" <<STUB
#!/bin/bash
echo "\$*" >> "$t/calls"
case "\$1 \${2:-}" in
  "image exists")
    [ -s "$t/store-broken" ] && exit 125
    awk -v r="\$3" '\$2":"\$3 == r || \$2"@"\$4 == r { found=1 } END { exit !found }' "$t/images" ;;
  "image inspect")
    [ -s "$t/inspect-broken" ] && exit 125
    ref=\${*: -1}
    awk -v r="\$ref" '\$2":"\$3 == r || \$2"@"\$4 == r { print \$1; found=1; exit } END { exit !found }' "$t/images" || exit 125 ;;
  "images "*)
    [ -s "$t/images-broken" ] && exit 125
    awk '\$5 == 1 { print "sha256:" \$1, \$2, \$3, \$4 }' "$t/images" ;;
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
expect "an old image pulled by digest is removed by digest" removed docker.io/library/busybox@sha256:d5
expect "without PRUNE_KEEP an old runner image goes too" removed quay.io/crunchtools/gha-runner@sha256:d6
expect "no name is removed as repo:<none>" bash -c '! grep -q "rmi .*:<none>" "$0"' "$t/calls"
expect "the age reaches podman" grep -q -- "--filter until=168h" "$t/calls"
expect "dangling images and build cache are pruned" grep -qx "image prune -f --build-cache" "$t/calls"
expect "build containers are pruned" grep -qx "system prune -f --build" "$t/calls"
expect "reports what it removed" grep -q "removed 3 image name" "$t/out"

setup "PRUNE_KEEP spares the pinned runner image"
PRUNE_KEEP=quay.io/crunchtools/gha-runner@sha256:d6 expect "the script succeeds" run "$t/list"
expect "the runner image stays" bash -c '! grep -q "rmi quay.io/crunchtools/gha-runner" "$0"' "$t/calls"
expect "other digest-only images still go" removed docker.io/library/busybox@sha256:d5
expect "the list still applies" bash -c '! grep -qx "rmi quay.io/crunchtools/sdlc:latest" "$0"' "$t/calls"

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

nothing_pruned() { ! grep -q "^rmi \|prune" "$t/calls"; }
fails() { ! "$@"; }

setup "the store cannot answer for a listed image"
echo 1 > "$t/store-broken"
expect "the script fails" fails run "$t/list"
expect "it says why" grep -q "cannot read the store" "$t/err"
expect "nothing is removed or pruned" nothing_pruned

setup "a listed image exists but cannot be inspected"
echo 1 > "$t/inspect-broken"
expect "the script fails" fails run "$t/list"
expect "it says why" grep -q "cannot inspect quay.io/crunchtools/sdlc:latest" "$t/err"
expect "nothing is removed or pruned" nothing_pruned

setup "the keep list cannot be read"
chmod 000 "$t/list"
if [ -r "$t/list" ]; then
  echo "skipped [$case]: running as a user who can read mode 000"
else
  expect "the script fails" fails run "$t/list"
  expect "it says why" grep -q "cannot read $t/list" "$t/err"
  expect "nothing is removed or pruned" nothing_pruned
fi
chmod 644 "$t/list"

setup "a list of comments only"
printf '# nothing to keep\n\n' > "$t/list"
expect "the script succeeds" run "$t/list"
expect "the old images go" removed quay.io/crunchtools/sdlc:latest

setup "the image listing fails"
echo 1 > "$t/images-broken"
expect "the script fails" fails run "$t/list"
expect "it says why" grep -q "cannot list images" "$t/err"
expect "nothing is removed or pruned" nothing_pruned

# The handoff the units make: gha-runner-prune.service touches a file in its
# own root-owned runtime directory, and gha-runner-cached@.service's
# ExecStartPre prunes when that file is newer than the runner's stamp. Each
# command is taken from the unit file itself (continuation lines joined, $$ and
# %i expanded as systemd does) and run with /run/gha-runner-prune, the cache
# root and /usr/bin/podman pointed into the test tree.
units=$(dirname "$prune")
# unit_cmd <unit file> <text in the line> -- the command of that Exec line,
# without a `/bin/sh -c '...'` wrapper.
unit_cmd() {
  awk -v want="$2" '
    /^Exec/ { cmd = ""; inexec = 1 }
    inexec { line = $0; cont = sub(/\\$/, "", line); cmd = cmd line (cont ? " " : "")
             if (!cont) { inexec = 0; if (index(cmd, want)) { print cmd; exit } } }
  ' "$1" | sed -E "s/^Exec[A-Za-z]+=-?//; s/^\/bin\/sh -c '//; s/'[[:space:]]*\$//"
}
# from_unit <script> -- systemd's expansions, then the test tree's paths.
from_unit() {
  local s=$1
  s=${s//\$\$/\$}
  s=${s//%i/1}
  s=${s//\/run\/gha-runner-prune/$t\/run-prune}
  s=${s//\/var\/mnt\/onsite\/gha-runner-cache/$t\/cache}
  s=${s//\/usr\/bin\/podman/$t\/bin\/podman}
  printf '%s' "$s"
}
request=$(unit_cmd "$units/gha-runner-prune.service" gha-runner-prune/requested)
prestart=$(unit_cmd "$units/gha-runner-cached@.service" gha-runner-prune/requested)
digest=$(grep -o 'gha-runner@sha256:[0-9a-f]*' "$units/gha-runner-cached@.service" | head -1)

setup "units: root never writes where a runner can aim it"
expect "the service's command was found" test -n "$request"
expect "the request is a runtime directory systemd makes root's" \
  grep -qx 'RuntimeDirectory=gha-runner-prune' "$units/gha-runner-prune.service"
expect "runners can read it, not write it" \
  grep -qx 'RuntimeDirectoryMode=0755' "$units/gha-runner-prune.service"
expect "it survives the oneshot ending" \
  grep -qx 'RuntimeDirectoryPreserve=yes' "$units/gha-runner-prune.service"
expect "no command of the service touches the runner cache" \
  bash -c '! grep -E "^Exec" "$0" | grep -q gha-runner-cache' "$units/gha-runner-prune.service"
mkdir -p "$t/run-prune" "$t/cache/cached1/home"
ln -s "$t/victim" "$t/cache/cached1/home/prune-requested"
ln -s "$t/victim2" "$t/cache/cached1/home/prune-done"
expect "the request runs" sh -c "$(from_unit "$request")"
expect "the request is made" test -e "$t/run-prune/requested"
expect "a symlink a runner planted is not followed" test ! -e "$t/victim"
expect "nor its stamp" test ! -e "$t/victim2"

setup "units: the request reaches the runner's prune, once"
mkdir -p "$t/run-prune" "$t/cache/cached1/home"
expect "the pre-start command was found" test -n "$prestart"
expect "no request, no prune" sh -c "$(from_unit "$prestart")"
expect "and no container" test ! -s "$t/calls"
sh -c "$(from_unit "$request")"
expect "the pre-start runs" sh -c "$(from_unit "$prestart")"
expect "the runner stamps it" test -e "$t/cache/cached1/home/prune-done"
run_line=$(grep "^run " "$t/calls" || true)
expect "one prune container starts" test "$(grep -c "^run " "$t/calls")" = 1
for want in "--rm --replace --init --pull=missing --name gha-runner-cached1-prune" \
            "--network none" \
            "-e PRUNE_KEEP=quay.io/crunchtools/$digest" \
            "-v $t/cache/cached1/containers:/home/podman/.local/share/containers" \
            "-v /srv/gha-runner/bin/gha-runner-prune:/usr/local/libexec/gha-runner-prune:ro" \
            "-v /srv/gha-runner/config/shared-images.list:/run/shared-images.list:ro" \
            "--entrypoint /bin/bash"; do
  expect "the container gets: $want" grep -qF -- "$want" <<<"$run_line"
done
expect "it runs the script on the list" \
  grep -qE "@sha256:[0-9a-f]{64} /usr/local/libexec/gha-runner-prune /run/shared-images.list\$" <<<"$run_line"
expect "the store is mounted where the script looks" \
  grep -q 'PRUNE_STORE:-$HOME/.local/share/containers' "$prune"
expect "the unit can see the script" \
  grep -q '^BindReadOnlyPaths=.*/var/srv/gha-runner/bin' "$units/gha-runner-cached@.service"
: > "$t/calls"
expect "the same request does not prune again" sh -c "$(from_unit "$prestart")"
expect "so no container" test ! -s "$t/calls"
touch -d '1 minute ago' "$t/cache/cached1/home/prune-done"
expect "a newer request prunes again" sh -c "$(from_unit "$prestart")"
expect "with one container" test "$(grep -c "^run " "$t/calls")" = 1

if [ "$failures" -gt 0 ]; then
  echo "gha-runner-prune: $failures check(s) failed" >&2
  exit 1
fi
echo "gha-runner-prune: all checks passed"
