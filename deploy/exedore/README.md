# Exedore runner pool (a264)

Six ephemeral runners in the org runner group `exedore` (visibility: all repos,
public allowed): `gha-runner-cached@1..4` (label `crunchtools-cached`) and
`gha-runner-uncached@1..2` (label `crunchtools-uncached`). Same image and
two-container mint as the retired gloval pair; the unit headers say what differs.

| Piece | Where |
|---|---|
| Units | `/etc/systemd/system/gha-runner-{cached,uncached}@.service`, `gha-runner.slice`, `gha.slice`, `gha-runner-egress.service`, `var-mnt-onsite-gha\x2drunner\x2dcache.mount` |
| Env (no secrets) | `/srv/gha-runner/config/gha-runner-{cached,uncached}.env` |
| Fence | `/etc/nftables/gha-runner-egress.nft` |
| Provisioning | `/srv/gha-runner/bin/gha-runner-instance` |
| Storage | `/var/mnt/onsite/gha-runner-cache` = 400G XFS loop image `/var/mnt/onsite/gha-runner-cache.img` |
| Pruning | `gha-runner-prune.timer` / `.service`, `/srv/gha-runner/bin/gha-runner-prune` |
| Shared image store | `/var/mnt/onsite/gha-runner-cache/shared-images`, owned by `ghimages` (uid 2090), warmed by `gha-images-warm.timer` from `/srv/gha-runner/config/shared-images.list` |
| App key | OpenBao `kv/exedore/gha-runner/gha-app.pem` (canonical), copied to `kv/exedore/gha-runner-<inst>/`, delivered by `srv-secrets@gha-runner-<inst>` |

One rootless user per instance (`ghrunner-cachedN` uid 2100+N,
`ghrunner-uncachedN` uid 2110+N), each with its own subuid range and its own
AppRole, so an escape from one instance reaches neither another's cache nor its key.

## Limits

- Slice: `CPUQuota=1600%`, `MemoryHigh=22G`, `MemoryMax=24G`; `gha.slice` has
  `CPUWeight=50`/`IOWeight=50` against the seats' `system.slice` at 100. That is
  the parent where the weight actually competes. Check it:
  `cat /sys/fs/cgroup/gha.slice/gha-runner.slice/{cpu.max,memory.max} /sys/fs/cgroup/gha.slice/cpu.weight`
  should print `1600000 100000`, `25769803776` and `50`.
- No per-job caps (no `SDLC_CPUS`/`SDLC_MEMORY`), by decision: the slice is the
  only limit. Under saturation the OOM killer acts inside the slice and kills a
  job, never a seat.
- Disk: the image's size is the cap. `df -h /var/mnt/onsite/gha-runner-cache`
  shows 400G no matter what the backup volume holds (200G until a315 filled
  it; the mount unit says how to grow it online). Uncached scratch lives on
  disk in the same filesystem and is wiped before and after every job. It is
  never tmpfs, because tmpfs is charged to the slice's memory. Cached stores
  are pruned daily, below.
- Network: runner users (uids 2100-2199) and `ghimages` (2090) cannot reach the host (loopback, so
  OpenBao, and every local address), the seats' bridge 10.88/16, WireGuard,
  or the LAN, multicast and broadcast included. The LAN resolver is the one
  exception, for DNS only. If DHCP changes the resolver, runners lose DNS and
  fail closed; update the two accept lines.

## Shared image store (a276)

`gha-images-warm.timer` runs hourly and 5 minutes after boot. It pulls the
images in `shared-images.list` into one read-only store inside the 400G
filesystem. The first warm took 255s. The store is ~4G, grows with the list,
and a run with nothing new takes about 30s. A version that loses its tag is
pruned one run later, so a job already using it keeps its layers. Jobs read
the store and never write it.

The store is written by a nested podman with fuse-overlayfs and
`force_mask=shared`. Files on disk stay owned by `ghimages` and readable by
everyone, and each file's real owner and mode live in the
`user.containers.override_stat` xattr. A runner reads them back only through
fuse-overlayfs with the same `force_mask` (image setting, opt-in per runner with
`GHA_SHARED_IMAGES`). A plain rootless store cannot be shared. Its files
belong to subuids that map to nothing in another user's namespace, so the
first copy-up fails.

Measured on 2026-11-18, the store is OFF on every runner. With it on, trentina's
`sdlc ci` on an uncached runner took 383s and then 375s, against 300s without it. The
image step went from 184s to about 270s, because builds run on fuse-overlayfs.
pbs stayed at 48s. Base pulls were never the bottleneck. The warm timer keeps
running so that turning the store on stays a three-line change.

A runner using the store needs `-e GHA_SHARED_IMAGES=/var/lib/shared-images` and two more unit lines, the bind and the mount:
`BindReadOnlyPaths=/var/mnt/onsite/gha-runner-cache/shared-images` and
`-v /var/mnt/onsite/gha-runner-cache/shared-images:/var/lib/shared-images:ro`.
Rootless podman joins the unit's private mount namespace, which hides the rest
of onsite.

To add an image, add a line to the list and run
`systemctl start gha-images-warm`. Read the outcome with
`journalctl -u gha-images-warm -n 20`.

## Pruning the cached stores (a315)

Unpruned, each cached store grew to 40-45G and filled the filesystem
(ENOSPC). `gha-runner-prune.timer` fires daily and leaves `prune-requested` in
each cached runner's home. The runner prunes in its own `ExecStartPre`, between
two jobs, so nothing is pruned under a running job. It removes tagged images
created more than 7 days ago (except those `shared-images.list` names), the
build layer cache, and leftover build containers. An idle runner prunes after
its next job. Force one now with `systemctl start gha-runner-prune`. Read the
result in the runner's journal:
`journalctl -u gha-runner-cached@1 -g gha-runner-prune`.

## Scale

- Within the provisioned set: `systemctl disable --now gha-runner-cached@4`, then
  `systemctl enable --now gha-runner-cached@4`. Each instance keeps its own cache.
- New instance (N up to 9): `/srv/gha-runner/bin/gha-runner-instance add cached 5 && systemctl enable --now gha-runner-cached@5`.
- Edits to the env files take effect at the next job, because every job is a
  fresh container. Restart a unit only while it is idle.
- A stopped runner leaves an offline registration behind. GitHub expires it,
  or delete it right away:
  `gh api orgs/crunchtools/actions/runner-groups/<exedore id>/runners`, then
  `gh api -X DELETE orgs/crunchtools/actions/runners/<id>`.

## Promoting a new image

Both units run `quay.io/crunchtools/gha-runner@sha256:…` with `--pull=missing`,
never `:main`: a merge does not reach the pool until someone promotes it.
`scripts/deploy-units-test.sh` fails CI if either template names `:main` or
`--pull=newer`.

1. Resolve the release's digest (tags carry no `v`):
   `podman pull -q quay.io/crunchtools/gha-runner:1.2.0 && podman image inspect --format '{{.Digest}}' quay.io/crunchtools/gha-runner:1.2.0`.
2. Verify it by digest, on a host that can run nested containers:
   `ENGINE=podman scripts/smoke-test.sh quay.io/crunchtools/gha-runner@<digest>`.
   That includes the bogus-token registration, the TLS round trip the libssl
   outage failed.
3. Canary one uncached runner. An instance file overrides the template:
   `cp /etc/systemd/system/gha-runner-uncached@.service /etc/systemd/system/gha-runner-uncached@1.service`,
   sed the new digest into that copy, `systemctl daemon-reload`, and
   `systemctl restart gha-runner-uncached@1` while it is idle (a waiting
   runner's container already holds the old image). Wait for one green job on
   `exedore-uncached1`.
4. Promote: sed the new digest into both templates in `/etc/systemd/system/`,
   `rm` the canary file, `systemctl daemon-reload`. A runner moves to the new
   image when its container next starts, so a busy one after its job, an idle
   one after its next job or an idle restart. Land the same digest in this
   directory by pull request.
5. Roll back with the same sed and the old digest.

## Kill switches

1. Fleet-wide, with no host access: delete or empty the ORG variables
   `CACHED_RUNNER_LABEL` / `UNCACHED_RUNNER_LABEL`
   (`gh variable delete CACHED_RUNNER_LABEL --org crunchtools`). Workflows that
   read them fall back to `ubuntu-latest`. A REPO-level variable of the same
   name overrides the org one, in both directions.
2. This host: `systemctl stop 'gha-runner-cached@*' 'gha-runner-uncached@*'`.
   Stopping `gha-runner-egress.service` also stops every runner, because they
   `Requires=` it: no fence, no runner.
3. GitHub side: set the `exedore` group's visibility to `selected` with no repos.

## Rotate the App key

Pipe the new key in, never through argv or a terminal:
`... | ssh exedore /srv/gha-runner/bin/gha-runner-instance import-key`. Then for
each instance, run `gha-runner-instance sync-key <class> <N>` and
`systemctl restart srv-secrets@gha-runner-<class><N>`. The next mint uses the
new key.

## Org settings this depends on

Fork-PR workflows need approval from all external contributors
(`all_external_contributors`). The setting was `first_time_contributors` until
2026-11-18, and a264 tightened it, because org variables reach fork-PR
workflows. Check it with
`gh api orgs/crunchtools/actions/permissions/fork-pr-contributor-approval`.

## No rollback to gloval

Gloval's two runners were disabled on 2026-11-18 and retired on Scott's order
(a279): their units, slice, `/srv` directories, image and monitoring are gone,
so exedore is the only pool. Rebuilding on another host means starting from
this directory, not reviving gloval's units.
