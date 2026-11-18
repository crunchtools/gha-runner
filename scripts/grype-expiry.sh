#!/bin/bash
# Fail once any .grype.yaml ignore is past its expiry.
#
# grype's ignore rules have no expiry field, so an ignore's expiry is an
# `EXPIRES YYYY-MM-DD` comment, and this is what makes the comment bind: CI
# runs it on every change and daily, so a stale ignore turns main red instead
# of quietly hiding a vulnerability for good.
#
# Each `- vulnerability:` entry is governed by the nearest EXPIRES above it, so
# one header date can cover the entries under it and a later date can govern
# the entries after it. An entry with no EXPIRES above it, or one under a date
# that is not a real calendar date, fails.
#
# Usage: grype-expiry.sh [file] [today]   (today: YYYY-MM-DD, default UTC now)
set -euo pipefail

file=${1:-.grype.yaml}
today=${2:-$(date -u +%F)}
[ "$(date -u -d "$today" +%F 2>/dev/null)" = "$today" ] \
  || { echo "::error::today must be a calendar date as YYYY-MM-DD, not '$today'" >&2; exit 2; }
[ -f "$file" ] || { echo "no $file: nothing to expire"; exit 0; }
[ -r "$file" ] || { echo "::error::cannot read $file" >&2; exit 2; }

# One line per ignore entry: "<line> <governing date or ->".
# Any EXPIRES directive takes effect, well-formed or not: a malformed one makes
# the entries under it fail rather than leaving an earlier date in force.
entries=$(awk '
  /(^|[^A-Za-z])EXPIRES([^A-Za-z]|$)/ {
    if (match($0, /EXPIRES [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]([^0-9]|$)/))
      date = substr($0, RSTART + 8, 10)
    else
      date = "malformed"
  }
  /^[[:space:]]*-[[:space:]]*vulnerability:/ { print NR, (date == "" ? "-" : date) }
' "$file")

status=0
while read -r line date; do
  [ -n "$line" ] || continue
  if [ "$date" = - ]; then
    echo "::error file=$file,line=$line::this grype ignore has no EXPIRES date above it"
    status=1
  elif [ "$(date -u -d "$date" +%F 2>/dev/null)" != "$date" ]; then
    echo "::error file=$file,line=$line::EXPIRES $date is not a calendar date"
    status=1
  elif [[ "$date" < "$today" ]]; then
    echo "::error file=$file,line=$line::this grype ignore expired on $date; fix or re-justify it"
    status=1
  else
    echo "$file:$line expires $date"
  fi
done <<< "$entries"
exit "$status"
