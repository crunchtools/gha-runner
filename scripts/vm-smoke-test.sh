#!/bin/bash
# The runner VM image's gate, as CI runs it against the pushed digest.
#
# Booting the VM needs KVM, which GitHub's runners do not offer, so this checks
# what a container run of the image can: bootc's own lint, that the runner and
# the docker CLI start (the runner needs libicu and openssl from dnf), and that
# the boot units are enabled. The start script's guards are exercised too: no
# credential means no job, never a runner started without its config.
#
# Usage: vm-smoke-test.sh <image>
set -euo pipefail

IMAGE=${1:?usage: vm-smoke-test.sh <image>}

run_in_image() {
  podman run --rm --entrypoint /bin/bash "$IMAGE" -c "$1"
}

echo "== bootc container lint"
podman run --rm "$IMAGE" bootc container lint

echo "== the runner binary is the pinned version"
run_in_image '/usr/lib/actions-runner/bin/Runner.Listener --version' | grep -q '2.338.2'

echo "== the docker CLI runs"
run_in_image 'docker --version'

echo "== the tools jobs run without installing: git (checkout), gh, skopeo, python3"
run_in_image 'git --version && gh --version && skopeo --version && python3 --version'
echo "== the boot units are enabled"
run_in_image "systemctl is-enabled gha-runner.service podman.socket 'var-lib-shared\\x2dimages.mount'"

echo "== storage lists the shared image store"
run_in_image 'grep -q "/var/lib/shared-images" /etc/containers/storage.conf'

echo "== Red Hat registries require sigstore signatures with Rekor"
# The base's own policy (/usr/share, no /etc override) enforces this; the
# retired Fedora image had to install it. Fail if either side drifts.
run_in_image 'test ! -e /etc/containers/policy.json && jq -e '"'"'[.transports.docker["registry.redhat.io","registry.access.redhat.com"][0] | .type == "sigstoreSigned" and (.rekorPublicKeyPath | length > 0)] | all'"'"' /usr/share/containers/policy.json'

echo "== job containers run unlabelled (the runner does not relabel the workspace)"
run_in_image 'grep -qx "label = false" /etc/containers/containers.conf.d/50-gha-nolabel.conf'

echo "== no credential, no runner"
if run_in_image 'CREDENTIALS_DIRECTORY=$(mktemp -d) /usr/libexec/runner-start.sh' 2>/dev/null; then
  echo "runner-start.sh succeeded without a credential" >&2
  exit 1
fi
if run_in_image 'd=$(mktemp -d); : > "$d/gha.jitconfig"; CREDENTIALS_DIRECTORY=$d /usr/libexec/runner-start.sh' 2>/dev/null; then
  echo "runner-start.sh succeeded with an empty gha.jitconfig" >&2
  exit 1
fi

echo "PASS"
