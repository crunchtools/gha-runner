#!/bin/sh
# One job. The just-in-time config arrives as a systemd credential (SMBIOS
# type 11 from qemu), so nothing secret is on the disk image, and it already
# names the runner, its group and labels: no config.sh, no registration token.
set -eu
rm -rf /var/lib/actions-runner
cp -a /usr/lib/actions-runner /var/lib/actions-runner
cd /var/lib/actions-runner
exec ./run.sh --jitconfig "$(cat "$CREDENTIALS_DIRECTORY/gha.jitconfig")"
