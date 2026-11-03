#!/bin/bash
# Runs after every job, via ACTIONS_RUNNER_HOOK_JOB_COMPLETED.
#
# A persistent runner reuses its container, so without this each job inherits
# the previous one's checkout and any container it left behind. --ephemeral
# gave that for free by throwing the whole container away; this is what buys
# it back.
#
# Images are deliberately KEPT: they are the layer cache, which is the entire
# reason this runner exists. Containers and the workspace are not.
set -u
podman rm -af >/dev/null 2>&1 || true
rm -rf "${RUNNER_WORKSPACE:-/home/podman/_work}"/* 2>/dev/null || true
exit 0
