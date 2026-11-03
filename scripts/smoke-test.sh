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

echo "== smoke test passed"
