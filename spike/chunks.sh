#!/bin/sh
# a1058 / sdlc#103 item 6: ai's result crosses to write as p0..p3, at most
# 112,500 bytes each, 450,000 in all. `produce` writes the outputs, `consume`
# reassembles SDLC_AI_0..3 and checks them, in this job and in a nested run.
set -u
NESTED=docker.io/library/docker@sha256:cd58b396e427d1ee8cddcc3f3b7e8d8c2ba45755c5dd5b821b6e615e1ccf4586
CAP=450000
CHUNK=112500
fails=0
result() { echo "RESULT $1 $2${3:+ ($3)}"; [ "$2" = pass ] || [ "$2" = info ] || fails=$((fails + 1)); }

# The reference splitter: refuses loudly over the cap and on empty, never truncates.
split() {
  n=$(wc -c < "$1")
  if [ "$n" -gt "$CAP" ]; then echo "::error::ai result is $n bytes encoded, over $CAP: not truncated"; return 1; fi
  if [ "$n" -eq 0 ]; then echo "::error::ai result is empty"; return 1; fi
  for i in 0 1 2 3; do echo "p$i=$(dd if="$1" bs=$CHUNK skip=$i count=1 2>/dev/null)"; done
}
join() {
  all="${SDLC_AI_0:-}${SDLC_AI_1:-}${SDLC_AI_2:-}${SDLC_AI_3:-}"
  if [ -z "$all" ]; then echo "::error::write: ai result missing or empty"; return 1; fi
  printf %s "$all"
}

case "${1:-}" in
produce)
  t=$(mktemp -d)
  head -c 337500 /dev/urandom | base64 -w0 > "$t/r"
  head -c 337501 /dev/urandom | base64 -w0 > "$t/big"; head -c "$((CAP + 1))" "$t/big" > "$t/over"
  : > "$t/empty"
  echo "encoded: $(wc -c < "$t/r") / $(wc -c < "$t/over")"
  split "$t/r" > "$t/out" && result chunk-450000 pass || result chunk-450000 fail
  if split "$t/over" > /dev/null; then result chunk-450001-refused fail "split accepted it"; else result chunk-450001-refused pass; fi
  if split "$t/empty" > /dev/null; then result chunk-empty-refused fail; else result chunk-empty-refused pass; fi
  cat "$t/out" >> "$GITHUB_OUTPUT"
  echo "sha=$(sha256sum < "$t/r" | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
  awk '{ print "  " substr($0, 1, 3) " " length($0) - 3 " bytes" }' "$t/out"
  ;;
consume)
  want=$SPIKE_SHA
  for i in 0 1 2 3; do eval "echo \"SDLC_AI_$i: \${#SDLC_AI_$i} bytes\""; done
  got=$(join | sha256sum | cut -d' ' -f1)
  [ "$got" = "$want" ] && result chunks-reassembled pass || result chunks-reassembled fail "$got"
  got=$(docker run --rm -e SDLC_AI_0 -e SDLC_AI_1 -e SDLC_AI_2 -e SDLC_AI_3 "$NESTED" \
        sh -c 'printf %s "$SDLC_AI_0$SDLC_AI_1$SDLC_AI_2$SDLC_AI_3" | sha256sum' 2>&1 | cut -d' ' -f1)
  [ "$got" = "$want" ] && result chunks-nested-env pass || result chunks-nested-env fail "$got"
  if (SDLC_AI_0="" SDLC_AI_1="" SDLC_AI_2="" SDLC_AI_3="" join > /dev/null); then
    result write-refuses-empty fail; else result write-refuses-empty pass; fi
  # Why the split exists: one 450,000-byte variable cannot reach a process.
  big=$(join)
  if BIG=$big docker run --rm -e BIG "$NESTED" true 2>/dev/null; then
    result one-var-450000 info "accepted"; else result one-var-450000 info "refused, as MAX_ARG_STRLEN predicts"; fi
  ;;
*) echo "usage: chunks.sh produce|consume"; exit 2 ;;
esac
echo "chunks.sh $1: $fails failure(s)"
exit "$fails"
