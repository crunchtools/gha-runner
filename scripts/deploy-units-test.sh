#!/bin/bash
# The Exedore runner units, and gha-images-warm, run an image pinned by digest
# (a315). After the libssl outage, a merged :main pulled with --pull=newer is
# exactly what must never reach the pool again, so this fails if any of them
# names :main or --pull=newer, refers to the runner image by anything but
# @sha256, or pins a different digest from the others (or a unit's mint and
# runner differ). A new image arrives only by promotion:
# deploy/exedore/README.md "Promoting a new image".
#
# The checker runs on deliberately broken copies first, so a regex that went
# blind would fail here rather than pass everything.
set -euo pipefail

units_dir=$(cd "$(dirname "$0")/.." && pwd)/deploy/exedore
failures=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }

# check <unit>... -- prints why and returns 1 when the set is not pinned.
check() {
  local bad=0 unit refs body
  local -A digests=()
  for unit in "$@"; do
    # Directives only: a comment may say why :main is gone.
    body=$(grep -v '^[[:space:]]*#' "$unit")
    if grep -n 'gha-runner:main' <<<"$body"; then
      echo "$unit: names :main" >&2; bad=1
    fi
    if grep -n -- '--pull=newer' <<<"$body"; then
      echo "$unit: uses --pull=newer" >&2; bad=1
    fi
    refs=$(grep -o 'quay\.io/crunchtools/gha-runner[^[:space:]\\]*' <<<"$body" || true)
    if [ -z "$refs" ]; then
      echo "$unit: no runner image reference" >&2; bad=1
    fi
    while read -r ref; do
      [ -n "$ref" ] || continue
      if [[ "$ref" =~ ^quay\.io/crunchtools/gha-runner@(sha256:[0-9a-f]{64})$ ]]; then
        digests[${BASH_REMATCH[1]}]=1
      else
        echo "$unit: not pinned by digest: $ref" >&2; bad=1
      fi
    done <<<"$refs"
  done
  if [ "${#digests[@]}" -gt 1 ]; then
    echo "they pin different digests: ${!digests[*]}" >&2; bad=1
  fi
  return "$bad"
}

# The two runner templates, and gha-images-warm, which runs the same image to
# write the shared store and is promoted with them.
units=("$units_dir"/gha-runner-cached@.service "$units_dir"/gha-runner-uncached@.service
       "$units_dir"/gha-images-warm)
# Empty when the cached unit is not pinned at all: the self-checks below mutate
# its digest, so they are skipped and the unit check says what is wrong.
pinned=$(grep -o 'gha-runner@sha256:[0-9a-f]*' "${units[0]}" | head -1 || true)
pinned=${pinned#gha-runner@}

# refused <case> <sed expression> -- a copy of the cached unit, edited, must fail.
refused() {
  case=$1
  local t
  t=$(mktemp -p "$root")
  sed "$2" "${units[0]}" > "$t"
  if check "$t" >/dev/null 2>&1; then
    fail "the checker accepted it"
  else
    echo "refused as expected: $case"
  fi
}
if [ -n "$pinned" ]; then
  refused ":main" "s|gha-runner@$pinned|gha-runner:main|"
  refused "--pull=newer" "s|--pull=missing|--pull=newer|"
  refused "a floating tag" "s|gha-runner@$pinned|gha-runner:latest|"
  refused "a short digest" "s|gha-runner@$pinned|gha-runner@sha256:abc|"
  refused "mint and runner disagree" "0,/gha-runner@$pinned/s||gha-runner@sha256:$(printf '0%.0s' {1..64})|"
else
  echo "self-checks skipped: ${units[0]##*/} pins no digest to mutate" >&2
fi

case="deploy/exedore units"
if check "${units[@]}"; then
  echo "pinned: both units and gha-images-warm run gha-runner@$pinned"
else
  fail "a unit is not pinned (see above)"
fi

if [ "$failures" -gt 0 ]; then
  echo "deploy units: $failures check(s) failed" >&2
  exit 1
fi
echo "deploy units: all checks passed"
