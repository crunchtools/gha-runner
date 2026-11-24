#!/bin/sh
# The runner VM's one job: the Containerfile installs this as
# /usr/libexec/runner-start.sh and gha-runner.service runs it.
#
# The just-in-time config arrives as a systemd credential (SMBIOS type 11 from
# qemu), so nothing secret is on the disk image, and it already names the
# runner, its group and labels: no config.sh, no registration token. It goes to
# the runner as ACTIONS_RUNNER_INPUT_JITCONFIG, not --jitconfig: the listener
# masks it in its logs and removes it from the environment its jobs inherit,
# and it stays off the command line.
set -eu
jit=$(cat "$CREDENTIALS_DIRECTORY/gha.jitconfig")
[ -n "$jit" ] || { echo "gha.jitconfig credential is empty" >&2; exit 1; }
rm -rf /var/lib/actions-runner
cp -a /usr/lib/actions-runner /var/lib/actions-runner
cd /var/lib/actions-runner
ACTIONS_RUNNER_INPUT_JITCONFIG=$jit exec ./run.sh
