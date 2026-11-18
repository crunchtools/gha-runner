#!/bin/bash
# The constitution's nested test, as CI runs it.
#
# A successful image BUILD proves almost nothing here: the one property that
# makes this image usable is that a job can build AND run containers inside it,
# and the build half works on bases where the run half does not. That is
# exactly how UBI 10 was eliminated. So both are asserted, every time, before
# the image is published.
#
# Usage: smoke-test.sh <image>
set -euo pipefail

IMAGE=${1:?usage: smoke-test.sh <image>}
ENGINE=${ENGINE:-docker}

run_in_image() {
  "$ENGINE" run --rm \
    --device /dev/fuse \
    --security-opt label=disable \
    --security-opt seccomp=unconfined \
    --entrypoint /bin/bash "$IMAGE" -c "$1"
}

echo "== the runner binary is the pinned version"
run_in_image 'cd actions-runner && ./config.sh --version'

echo "== docker is shimmed to podman"
run_in_image 'docker --version | grep -qi podman && echo "docker -> podman: ok"'

# The hook runs after every job as the same uid a job's steps run as, so a hook
# that uid can replace is a command one job leaves for the next. Assert the
# image as the runner will have it rather than trusting the Containerfile to
# have kept saying `/usr/local/bin`: ownership and mode, the entrypoint and the
# hook path the entrypoint actually exports, and the two operations that have
# to fail. `write refused` covers mode; `unlink refused` covers the directory,
# which is the half a chmod does not reach.
echo "== the entrypoint and the job hook are out of the job user's reach"
run_in_image 'set -e
for f in entrypoint.sh job-completed.sh mint-registration-token.sh; do
  stat -c "%n %U %a" "/usr/local/bin/$f"
  [ "$(stat -c %u /usr/local/bin/$f)" = 0 ] || { echo "NOT root-owned: $f" >&2; exit 1; }
  [ -w "/usr/local/bin/$f" ] && { echo "writable by $(id -u): $f" >&2; exit 1; }
done
echo x > /usr/local/bin/job-completed.sh 2>/dev/null \
  && { echo "job user rewrote the hook" >&2; exit 1; } || echo "write refused: ok"
rm -f /usr/local/bin/job-completed.sh 2>/dev/null \
  && { echo "job user unlinked the hook" >&2; exit 1; } || echo "unlink refused: ok"
grep -q "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh" \
  /usr/local/bin/entrypoint.sh || { echo "entrypoint exports another hook path" >&2; exit 1; }'

"$ENGINE" image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE" \
  | grep -q '/usr/local/bin/entrypoint.sh' \
  || { echo "image entrypoint is not the installed one" >&2; exit 1; }
echo "image entrypoint: ok"

echo "== nested BUILD"
run_in_image 'podman build -q -t smoke:build -f - /tmp <<CF
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest
RUN echo nested-build-works > /proof
CF
'

echo "== nested RUN -- the half that eliminated UBI 10 as a base"
run_in_image 'podman build -q -t smoke:run -f - /tmp >/dev/null <<CF
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest
RUN echo nested-run-works > /proof
CF
podman run --rm smoke:run cat /proof'

echo "== a job container and a service container, as the runner starts them"
# The runner's own sequence for \`container:\` and \`services:\` (actions/runner
# ContainerOperationProvider): one network, a service reachable by its alias,
# and a job container with /var/run/docker.sock mounted, kept alive by tail.
# Run with the entrypoint's podman API up, since that is what the socket serves.
"$ENGINE" run --rm \
  --device /dev/fuse \
  --device /dev/net/tun \
  --security-opt label=disable \
  --security-opt seccomp=unconfined \
  --entrypoint /bin/bash "$IMAGE" -c '
set -euo pipefail
export XDG_RUNTIME_DIR=/home/podman/.runtime
mkdir -p "$XDG_RUNTIME_DIR/podman" && chmod 700 "$XDG_RUNTIME_DIR"
podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" >/dev/null 2>&1 &
for _ in $(seq 50); do [ -S /var/run/docker.sock ] && break; sleep 0.1; done
test -S /var/run/docker.sock
img=registry.access.redhat.com/ubi10/ubi-minimal:latest
docker pull -q "$img" >/dev/null
docker version --format "{{.Server.APIVersion}}" >/dev/null
docker network create smoke_net >/dev/null
docker create --name smoke_svc --network smoke_net --network-alias svc \
  --entrypoint tail "$img" -f /dev/null >/dev/null
docker start smoke_svc >/dev/null
docker create --name smoke_job --network smoke_net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp:/__w --workdir /__w \
  --entrypoint tail "$img" -f /dev/null >/dev/null
docker start smoke_job >/dev/null
docker exec smoke_job sh -c "test -S /var/run/docker.sock && getent hosts svc >/dev/null"
docker rm -f smoke_job smoke_svc >/dev/null
docker network rm smoke_net >/dev/null
echo "job container and service: ok"'

echo "== smoke test passed"
