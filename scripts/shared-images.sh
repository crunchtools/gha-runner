#!/bin/bash
# Opt-in: a shared, read-only image store for every job on this runner.
#
# With GHA_SHARED_IMAGES naming a directory that exists -- a warmed store the
# unit mounts read-only, e.g. /var/lib/shared-images -- write a storage drop-in
# for the podman user so podman reads that store as an additional image store.
# A job then runs its images without a pull and keeps its own writable storage.
#
# fuse-overlayfs and force_mask = "shared" are what Exedore measured working
# (a273c): the store's files are 0700 and owned by an id this runner's user
# namespace does not map, so native overlay cannot read them and a copy-up into
# them fails. fuse-overlayfs is also slower for the runner's own builds, which
# is why this is opt-in per runner class: unset, or pointing at nothing, no
# file is written and podman keeps the image's native overlay.
#
# A drop-in, not storage.conf: podman reads the user's storage.conf.d last of
# all, after the image's /etc/containers/storage.rootless.conf.d/30-gha-runner.conf,
# so these keys win and every other one keeps the image's value.
set -euo pipefail

store=${GHA_SHARED_IMAGES:-}
[ -n "$store" ] || exit 0
if [ ! -d "$store" ]; then
  echo "WARNING: GHA_SHARED_IMAGES=$store is not a directory; no shared image store" >&2
  exit 0
fi

conf=${XDG_CONFIG_HOME:-$HOME/.config}/containers/storage.conf.d/50-shared-images.conf
mkdir -p "$(dirname "$conf")"
# Exactly what Exedore verified.
cat > "$conf" <<CONF
# Written by shared-images.sh because GHA_SHARED_IMAGES is set.
[storage]
driver = "overlay"

[storage.options]
additionalimagestores = ["$store"]

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
force_mask = "shared"
CONF
echo "shared image store: $store (read-only, fuse-overlayfs)"
