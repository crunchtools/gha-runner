#!/bin/bash
# Opt-in: a shared, read-only image store for every job on this runner.
#
# With GHA_SHARED_IMAGES naming a directory that exists -- a warmed store the
# unit mounts read-only, e.g. /var/lib/shared-images -- write the podman user's
# storage.conf so podman reads that store as an additional image store. A job
# then runs its images without a pull and keeps its own writable storage.
#
# fuse-overlayfs and force_mask = "shared" are what Exedore measured working
# (a273c): the store's files are 0700 and owned by an id this runner's user
# namespace does not map, so native overlay cannot read them and a copy-up into
# them fails. fuse-overlayfs is also slower for the runner's own builds, which
# is why this is opt-in per runner class: unset, or pointing at nothing, no
# file is written and podman keeps the image's storage exactly as before.
set -euo pipefail

store=${GHA_SHARED_IMAGES:-}
[ -n "$store" ] || exit 0
if [ ! -d "$store" ]; then
  echo "WARNING: GHA_SHARED_IMAGES=$store is not a directory; no shared image store" >&2
  exit 0
fi

conf=${XDG_CONFIG_HOME:-$HOME/.config}/containers/storage.conf
base=/etc/containers/storage.conf
mkdir -p "$(dirname "$conf")"
# A user storage.conf replaces the system one for this user, so start from the
# base image's own and change only what the store needs (constitution: the base
# is not re-declared here). graphroot and runroot are dropped: rootless podman
# must keep its own defaults under $HOME, which is where the layer cache lives.
# The store goes first in additionalimagestores; force_mask goes in, and
# mount_program too in case a future base drops it.
{
  echo "# Written by shared-images.sh from $base because GHA_SHARED_IMAGES is set."
  sed -e '/^[[:space:]]*\(graphroot\|runroot\|force_mask\)[[:space:]]*=/d' \
      -e "s|^\([[:space:]]*additionalimagestores[[:space:]]*=[[:space:]]*\[\)|\1\n\"$store\",|" \
      -e '/^\[storage\.options\.overlay\]/a force_mask = "shared"' \
      "$base"
} > "$conf"
grep -q "^\"$store\"," "$conf" \
  || { echo "shared-images.sh: $base has no additionalimagestores to extend" >&2; exit 1; }
grep -q '^force_mask = "shared"' "$conf" \
  || { echo "shared-images.sh: $base has no [storage.options.overlay] table" >&2; exit 1; }
grep -q '^[[:space:]]*mount_program[[:space:]]*=' "$conf" \
  || sed -i '/^\[storage\.options\.overlay\]/a mount_program = "/usr/bin/fuse-overlayfs"' "$conf"
echo "shared image store: $store (read-only, fuse-overlayfs)"
