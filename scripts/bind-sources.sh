#!/bin/bash
# Runs at the start of every job, via ACTIONS_RUNNER_HOOK_JOB_STARTED.
#
# For `container:` and `services:` the runner always passes
# `-v _work/_actions:/__w/_actions -v _work/_tool:/__w/_tool` (among others),
# whatever the workflow does. Docker creates a missing bind source; podman
# refuses (a1058):
#
#   Error: statfs /home/podman/_work/_actions: no such file or directory
#
# Neither directory can be made earlier than the job. Runner v2.338.2's
# ActionManager.PrepareActionsAsync deletes _work/_actions at the start of every
# job (ActionManager.cs:93), `uses:` or not, and `_tool` only exists once a job
# installs a tool. The job-started hook is queued as a pre-job step after
# PrepareActionsAsync and before "Initialize containers" (JobExtension.cs:301,
# 304-312, 328), so it is the one point that is after the delete and before the
# create. The runner makes _temp and its children itself.
set -eu
WORK=${1:-/home/podman/_work}
mkdir -p "$WORK/_actions" "$WORK/_tool"
