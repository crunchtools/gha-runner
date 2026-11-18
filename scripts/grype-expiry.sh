#!/bin/bash
# Fail once any `EXPIRES YYYY-MM-DD` date in .grype.yaml has passed.
#
# grype's ignore rules have no expiry field, so an ignore's expiry lives in a
# comment beside it, and this is what makes the comment bind: CI runs it on
# every change and daily, so a stale ignore turns main red instead of quietly
# hiding a vulnerability for good.
#
# Usage: grype-expiry.sh [file] [today]   (today: YYYY-MM-DD, default UTC now)
set -euo pipefail

file=${1:-.grype.yaml}
today=${2:-$(date -u +%F)}
[ -f "$file" ] || { echo "no $file: nothing to expire"; exit 0; }

expired=0
found=0
while IFS=: read -r line date; do
  found=$((found + 1))
  if [[ "$date" < "$today" ]]; then
    echo "::error file=$file,line=$line::grype ignores expired on $date; fix or re-justify them"
    expired=1
  else
    echo "$file:$line expires $date"
  fi
done < <(grep -noE 'EXPIRES [0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" | sed -E 's/:EXPIRES /:/')

if grep -qE '^\s*-\s*vulnerability:' "$file" && [ "$found" -eq 0 ]; then
  echo "::error file=$file::$file ignores vulnerabilities with no EXPIRES date"
  exit 1
fi
exit "$expired"
