#!/bin/bash
# One ephemeral GitHub Actions runner: register, take exactly one job,
# de-register, exit. The systemd unit restarts us, so each job gets a fresh
# container and no job inherits another's workspace.
#
# The only credential here is a REGISTRATION TOKEN: good for registering a
# runner on one repository, and expired within the hour. The GitHub App private
# key that minted it stays in the separate container that ran
# mint-registration-token.sh and never enters this one, because this one is
# where repository code executes.
set -euo pipefail

# A DIRECTORY is mounted, not the file, so this can actually unlink the token
# below. A podman secret cannot be removed from inside the container -- the
# mount is read-only -- and the first version of this script "removed" it with
# `rm -f ... || true`, which failed silently and left the comment lying.
TOKEN_FILE=${GHA_REG_TOKEN_FILE:-/run/gha/regtoken}
REPO=${GHA_REPO:?GHA_REPO must be owner/repo}
LABELS=${GHA_LABELS:?GHA_LABELS must be set}

[ -r "$TOKEN_FILE" ] || { echo "RUNNER CANNOT START: no registration token" >&2; exit 2; }

export XDG_RUNTIME_DIR=/home/podman/.runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# The nested container storage is a persistent volume -- that is the point, it
# holds the layer cache -- so it also keeps CONTAINERS a previous job left when
# it failed before its own cleanup. The next job then dies on "the container
# name is already in use", which looks like a flake and is not one. Remove
# containers, keep images: the images are the cache.
podman rm -af >/dev/null 2>&1 || true

cd /home/podman/actions-runner

# --disableupdate because the version is pinned by digest in the image. A
# self-updating runner would defeat that pin and try to write into a layer.
./config.sh --unattended --ephemeral --disableupdate --replace \
  --url "https://github.com/$REPO" \
  --token "$(cat "$TOKEN_FILE")" \
  --name "${GHA_RUNNER_NAME:-$(hostname)-$$}" \
  --labels "$LABELS" \
  --work /home/podman/_work

# Registered; the token has done its one job. Drop it before the repository's
# code gets a shell -- and fail if it is still there, because the whole point of
# minting it in a separate container is that a job cannot reach a credential.
rm -f "$TOKEN_FILE"
[ -e "$TOKEN_FILE" ] && { echo "RUNNER CANNOT START: token still present" >&2; exit 2; }

exec ./run.sh
