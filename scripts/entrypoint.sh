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
# Where runners register: an organization (GHA_ORG), so one deployment can
# serve every repository the org's runner group allows, or a single repository
# (GHA_REPO, owner/repo). GHA_ORG wins when both are set.
if [ -n "${GHA_ORG:-}" ]; then
  SCOPE_URL="https://github.com/$GHA_ORG"
else
  SCOPE_URL="https://github.com/${GHA_REPO:?set GHA_ORG, or GHA_REPO as owner/repo}"
fi
LABELS=${GHA_LABELS:?GHA_LABELS must be set}

# Two ways to be a runner, and the first needs no credential on this host.
#
# PERSISTED: a runner that has registered once keeps long-lived, self-refreshing
# credentials. Mount them and `run.sh --once` takes exactly one job and exits,
# which gives the same fresh-container-per-job property as --ephemeral without
# a GitHub App private key living on the box. This is the default because it is
# both simpler and holds less.
#
# TOKEN: a registration token, for the first bootstrap or to re-register. The
# token is minted in a separate container so the App key never gets here.
# Trivy -- and anything else that INSPECTS an image rather than running one --
# reaches a container engine over a socket, and finds none in here otherwise:
#
#   unable to find the specified image "trentina:scan" in
#   ["docker" "containerd" "podman" "remote"]
#   podman error: no podman socket found:
#   stat /home/podman/.runtime/podman/podman.sock
#
# That is the path it looks in, so serve it there. The socket grants exactly
# what a job in this container already has -- podman as this user -- so it adds
# no reach; it only lets a tool ask about an image instead of running one.
start_podman_api() {
  mkdir -p "$XDG_RUNTIME_DIR/podman"
  podman system service --time=0 \
    "unix://$XDG_RUNTIME_DIR/podman/podman.sock" >/dev/null 2>&1 &
  waited=0
  while [ ! -S "$XDG_RUNTIME_DIR/podman/podman.sock" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ] \
    || echo "WARNING: podman socket absent; image scanners will fail" >&2
}

STATE=${GHA_RUNNER_STATE:-/home/podman/state}

if [ -f "$STATE/.runner" ] && [ -f "$STATE/.credentials" ]; then
  cp -f "$STATE/.runner" "$STATE/.credentials" /home/podman/actions-runner/
  [ -f "$STATE/.credentials_rsaparams" ] \
    && cp -f "$STATE/.credentials_rsaparams" /home/podman/actions-runner/
  export XDG_RUNTIME_DIR=/home/podman/.runtime
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  podman rm -af >/dev/null 2>&1 || true
  start_podman_api
  cd /home/podman/actions-runner
  # NOT --once. With reused credentials the runner keeps one identity, and
  # restarting it per job made every restart collide with the session the
  # previous one still held server-side:
  #
  #   A session for this runner already exists.
  #   Runner listener exit with terminated error, stop the service
  #
  # So it stays up and takes jobs continuously. Workspace hygiene comes from
  # the job-completed hook instead, which wipes _work between jobs.
  export ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh
  exec ./run.sh
fi

[ -r "$TOKEN_FILE" ] || { echo "RUNNER CANNOT START: no registration token and no persisted runner state" >&2; exit 2; }

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
#
# --ephemeral ONLY when there is nowhere to persist credentials. GitHub deletes
# an ephemeral runner server-side after one job, which would invalidate the
# credentials we just saved on the next start. With a state directory we
# register normally and get the same one-job-per-container property from
# `run.sh --once` above -- the container is still thrown away either way.
EPHEMERAL=--ephemeral
if [ -d "$STATE" ] && [ -w "$STATE" ]; then EPHEMERAL=; fi

./config.sh --unattended $EPHEMERAL --disableupdate --replace \
  --url "$SCOPE_URL" \
  --token "$(cat "$TOKEN_FILE")" \
  --name "${GHA_RUNNER_NAME:-gha}-$(hostname)" \
  --labels "$LABELS" \
  ${GHA_ORG:+--runnergroup "${GHA_RUNNER_GROUP:-Default}"} \
  --work /home/podman/_work

# Keep what the registration earned, so every later start needs no credential.
if [ -d "$STATE" ] && [ -w "$STATE" ]; then
  cp -f .runner .credentials "$STATE/" 2>/dev/null || true
  [ -f .credentials_rsaparams ] && cp -f .credentials_rsaparams "$STATE/" 2>/dev/null || true
fi

# Registered; the token has done its one job. Drop it before the repository's
# code gets a shell -- and fail if it is still there, because the whole point of
# minting it in a separate container is that a job cannot reach a credential.
rm -f "$TOKEN_FILE"
[ -e "$TOKEN_FILE" ] && { echo "RUNNER CANNOT START: token still present" >&2; exit 2; }

# Bootstrap: register, persist, exit. Deliberately does NOT start listening,
# because a bootstrap container that holds a session makes the next start fail
# with "A session for this runner already exists" -- one identity cannot be
# connected twice.
if [ "${GHA_CONFIGURE_ONLY:-0}" = "1" ]; then
  echo "configured and persisted; not listening (GHA_CONFIGURE_ONLY=1)"
  exit 0
fi

start_podman_api
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh
exec ./run.sh
