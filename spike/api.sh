#!/bin/sh
# a1058 / sdlc#103: the API-side mechanics, from a `container:` job (ubi-minimal, curl).
#   keepalive  item 8: PUT .../actions/workflows/<file>/enable with GITHUB_TOKEN (actions: write)
#   oidc       item 7/11: an OIDC token can be requested from a run: step in a container job
#   names      item 1: the check name a skipped job posts, evaluated or literal
set -u
fails=0
result() { echo "RESULT $1 $2${3:+ ($3)}"; [ "$2" = pass ] || [ "$2" = info ] || fails=$((fails + 1)); }
api() { curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }
R="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY"

case "${1:-}" in
keepalive)
  code=$(api -o /dev/null -w '%{http_code}' -X PUT "$R/actions/workflows/$SPIKE_WORKFLOW/enable")
  [ "$code" = 204 ] && result keepalive-enable pass 204 || result keepalive-enable fail "$code"
  api "$R/actions/workflows/$SPIKE_WORKFLOW" | grep -E '"(state|updated_at)"'
  ;;
oidc)
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    result oidc-env fail "ACTIONS_ID_TOKEN_REQUEST_URL not in the container step"
  else
    result oidc-env pass
    jwt=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=pypi" | tr -d ' \n' | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
    echo "::add-mask::$jwt"
    claims=$(printf %s "$jwt" | cut -d. -f2 | tr '_-' '/+')
    while [ $(( ${#claims} % 4 )) -ne 0 ]; do claims="$claims="; done
    claims=$(printf %s "$claims" | base64 -d 2>/dev/null)
    echo "$claims" | grep -oE '"(sub|ref|environment|job_workflow_ref|runner_environment)":"[^"]*"'
    case "$claims" in *'"aud":"pypi"'*) result oidc-token pass ;; *) result oidc-token fail ;; esac
  fi
  ;;
names)
  api "$R/commits/$GITHUB_SHA/check-runs?per_page=100" > /tmp/cr.json
  grep -oE '"name": *"sdlc / [^"]*"' /tmp/cr.json | sort -u
  if grep -qE '"name": *"sdlc / gate \(push\)"' /tmp/cr.json; then
    result skipped-name pass "evaluated: sdlc / gate (push)"
  elif grep -qF 'sdlc / gate (${{ github.event_name }})"' /tmp/cr.json; then
    result skipped-name pass "literal text, still never a required name"
  else
    result skipped-name fail "no check run for the skipped job"
  fi
  grep -qE '"name": *"sdlc / gate \(pull_request_target\)"' /tmp/cr.json && result skipped-not-required fail || result skipped-not-required pass
  ;;
*) echo "usage: api.sh keepalive|oidc|names"; exit 2 ;;
esac
echo "api.sh $1: $fails failure(s)"
exit "$fails"
