#!/bin/bash
# Print a GitHub Actions runner registration token for GHA_ORG (an
# organization) or, when that is unset, GHA_REPO (owner/repo).
#
# This runs in its own short-lived container that holds the App private key.
# The runner container -- the one a repository job executes in -- never sees
# that key: it gets only the token this prints, which registers runners and
# expires in an hour. A job that reads the key could instead
# mint installation tokens for as long as the key lives.
set -euo pipefail

if [ -n "${GHA_ORG:-}" ]; then
  SCOPE="orgs/$GHA_ORG"
else
  SCOPE="repos/${GHA_REPO:?set GHA_ORG, or GHA_REPO as owner/repo}"
fi
APP_ID=${GHA_APP_ID:?GHA_APP_ID must be set}
KEY=${GHA_APP_KEY_FILE:-/run/secrets/gha-app.pem}
API=https://api.github.com

[ -r "$KEY" ] || { echo "CANNOT MINT: app key not readable" >&2; exit 2; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A GitHub App JWT: 9 minutes, backdated a minute for clock skew. Ten is the
# documented maximum and a request at exactly ten is rejected.
app_jwt() {
  local now header payload unsigned sig
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)
  unsigned="$header.$payload"
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$KEY" | b64url)
  printf '%s.%s' "$unsigned" "$sig"
}

api_post() {  # $1 authorization header value, $2 path
  curl -sS -X POST -H "Authorization: $1" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$API/$2"
}

jwt=$(app_jwt)
install_id=$(curl -sS -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" "$API/$SCOPE/installation" \
  | jq -r '.id // empty')
[ -n "$install_id" ] || { echo "CANNOT MINT: app is not installed on $SCOPE" >&2; exit 2; }

inst_token=$(api_post "Bearer $jwt" "app/installations/$install_id/access_tokens" | jq -r '.token // empty')
[ -n "$inst_token" ] || { echo "CANNOT MINT: no installation token" >&2; exit 2; }

# Org-scoped when GHA_ORG is set: it could register a runner into any of the
# org's runner groups. No job ever sees it. The entrypoint consumes it in
# config.sh, unlinks the file and refuses to start if the file survives, all
# before run.sh accepts a job.
reg_token=$(api_post "token $inst_token" "$SCOPE/actions/runners/registration-token" | jq -r '.token // empty')
[ -n "$reg_token" ] || { echo "CANNOT MINT: no registration token" >&2; exit 2; }

printf '%s' "$reg_token"
