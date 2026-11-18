# Exedore runner pool (a264)

Six ephemeral runners in the org runner group `exedore` (visibility: all repos,
public allowed): `gha-runner-cached@1..4` (label `crunchtools-cached`) and
`gha-runner-uncached@1..2` (label `crunchtools-uncached`). Same image and
two-container mint as gloval's; the unit headers say what differs.

| Piece | Where |
|---|---|
| Units | `/etc/systemd/system/gha-runner-{cached,uncached}@.service`, `gha-runner.slice`, `gha.slice`, `gha-runner-egress.service`, `var-mnt-onsite-gha\x2drunner\x2dcache.mount` |
| Env (no secrets) | `/srv/gha-runner/config/gha-runner-{cached,uncached}.env` |
| Fence | `/etc/nftables/gha-runner-egress.nft` |
| Provisioning | `/srv/gha-runner/bin/gha-runner-instance` |
| Storage | `/var/mnt/onsite/gha-runner-cache` = 200G XFS loop image `/var/mnt/onsite/gha-runner-cache.img` |
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
  shows 200G no matter what the backup volume holds. Uncached scratch lives on
  disk in the same filesystem and is wiped before and after every job. It is
  never tmpfs, because tmpfs is charged to the slice's memory.
- Network: runner users (uids 2100-2199) cannot reach the host (loopback, so
  OpenBao, and every local address), the seats' bridge 10.88/16, WireGuard,
  or the LAN. The LAN resolver is the one exception, for DNS only. If DHCP
  changes the resolver, runners lose DNS and fail closed; update the two
  accept lines.

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

## Gloval rollback

Gloval's two runners were disabled on 2026-11-18. The units, config and data
stay in place. To bring them back, run
`ssh gloval systemctl enable --now gha-runner-cached.crunchtools.com gha-runner-uncached.crunchtools.com`.
They re-register on start, but only into a runner group named `gloval`, which
must exist first:
`gh api -X POST orgs/crunchtools/actions/runner-groups -f name=gloval -f visibility=all -F allows_public_repositories=true`.
Alternatively, set their `GHA_RUNNER_GROUP=exedore`.
