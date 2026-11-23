#!/bin/bash
# Create every host path the runner bind-mounts into a job container.
#
# For `container:` and `services:` the runner always passes, whatever the
# workflow does:
#
#   -v _work:/__w  -v externals:/__e:ro  -v _work/_temp:/__w/_temp
#   -v _work/_actions:/__w/_actions  -v _work/_tool:/__w/_tool
#   -v _work/_temp/_github_home:/github/home
#   -v _work/_temp/_github_workflow:/github/workflow
#
# Docker creates a missing bind source; podman refuses (a1058):
#
#   Error: statfs /home/podman/_work/_actions: no such file or directory
#
# The runner makes _actions and _tool only when a job downloads a `uses:`
# action, so a workflow with none could never start a `container:` job. Called
# by the entrypoint before the runner starts, and by job-completed.sh after it
# wipes the workspace (a persisted runner takes more than one job).
set -eu
WORK=${1:-/home/podman/_work}
mkdir -p "$WORK/_temp/_github_home" "$WORK/_temp/_github_workflow" \
  "$WORK/_actions" "$WORK/_tool"
