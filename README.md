# gha-runner

The self-hosted GitHub Actions runner image for Crunchtools. It takes one job,
runs it, and exits.

Generic by construction: nothing in the image names a repository. Runners
register to the crunchtools org in a runner group; the group's repository list
and each repository's `runs-on` decide who uses them, so a second consumer is a
runner-group change rather than a second deployment or a second image.
`crunchtools/trentina` is the first consumer.

## Why it exists

Some CI is cache-bound rather than CPU-bound. Trentina's container gate is: a
warm layer cache took a cold 2m11s build of that project's image down to **7s**,
measured on the host, and GitHub-hosted runners start cold every time. The
runner also builds *and runs* containers for the job, nested and rootless,
because every verification step in that gate is a `docker run`.

More cores, on their own, buy nothing: the L2 model's ONNX thread scaling goes
*negative* past about four threads (32 cases: 52.3s at 1 thread, 29.6s at 4,
49.0s at 14). The cache is the win.

## What it is not

It ships nothing and serves nothing. It is a build machine.

## Base image

`quay.io/podman/stable`, pinned by digest — a deliberate exception to the usual
UBI base. On UBI 10 a nested `podman run` fails with ``mount `proc` to `proc`:
Operation not permitted``, and UBI 10 pins podman 5.8.2 with no newer build.
The constitution records what was ruled out by experiment. A Hummingbird/RHHI
base cannot work at all here: those images have no shell, and every Actions
`run:` step executes as `bash -e {0}`.

## Two deployments: cached and uncached

The pool runs on exedore: four cached and two uncached instances in the
`exedore` runner group, one rootless user and one OpenBao AppRole each. Its
units, egress fence, storage and runbook are in
[deploy/exedore](deploy/exedore/README.md). Gloval's original two units were
retired (a279) and their deploy files removed; git history keeps them.

| Kind | Label | Container storage | Takes |
|---|---|---|---|
| `gha-runner-cached@1..4` | `crunchtools-cached` | persistent: the layer cache | our pull requests |
| `gha-runner-uncached@1..2` | `crunchtools-uncached` | scratch, empty every job | pushes to `main`: the build that gets published |

The cache is what makes the cached runner fast, and it is also why nothing it
builds may be published: every job it runs can write to that storage, and podman
reuses an extracted layer without re-hashing it. Every runner registers
`--ephemeral`, takes one job and exits, so no process or runner file outlives
its job; a cached one keeps only its layer cache. An uncached runner's scratch
is emptied between jobs, so its next job starts from nothing. Separate users
keep the stores apart.

Each runner mints a registration token on every start.

The App, `gha-runner.crunchtools.com`, holds one permission: **Organization >
Self-hosted runners: Read and write**. Runners register to the crunchtools org,
in the `exedore` runner group. Which repositories may use them is that group's
setting (org settings > Actions > Runner groups); which jobs land on them is each
repository's `runs-on`. Adding a repository is a runner-group change plus its
own `runs-on`, not a new deployment. `GHA_REPO` still works for a runner that
serves one repository; `GHA_ORG` wins when both are set.

No registry credential and no production secret is mounted: the workflows that
hold those stay on GitHub-hosted runners.

### Two departures from the standard Crunchtools unit

Both security, not taste, and both are in the constitution:

- **`User=ghrunner-cached` / `ghrunner-uncached`, not root.** This container runs repository code. A job that
  escapes it must not land as root on the host.
- **Not on the `crunchtools` network.** The internal network is how production
  services reach each other; a CI job must not be able to. Outbound only.

### Verify the quota actually bound

systemd will accept a cap and not apply it — a drop-in added while a slice is
already running is the usual way. Check both sides:

```bash
systemctl show gha-runner.slice -p CPUQuotaPerSecUSec -p MemoryMax
cat /sys/fs/cgroup/gha.slice/gha-runner.slice/cpu.max   # expect: 1200000 100000
```

Two things about that path. systemd reads the dash in `gha-runner.slice` as
hierarchy, so the cgroup sits under an implicit `gha.slice` rather than at
`/sys/fs/cgroup/gha-runner.slice`. And an empty slice has no cgroup at all —
systemd realizes it when the first unit in it starts — so checking before the
service runs reports nothing, which is not the same as reporting a problem.

## A shared, read-only image store

Opt-in, per runner. Mount a warmed store read-only and name it in the env file:

```
# in the unit's podman run
-v /srv/gha-shared-images/store:/var/lib/shared-images:ro
# in gha-runner-*.env
GHA_SHARED_IMAGES=/var/lib/shared-images
```

At start, `shared-images.sh` writes the podman user's `storage.conf`: overlay,
that path under `additionalimagestores`, fuse-overlayfs with
`force_mask = "shared"`, and nothing else, so graphroot and runroot stay the
rootless defaults. The base's `/etc/containers/storage.conf` is its rootful
config, which the rootless runner user never reads. That is what Exedore measured working: the store's
files are 0700 under an id the runner's user namespace does not map, which
native overlay can neither read nor copy up from. Jobs then run the store's
images without pulling and keep their own writable storage. fuse-overlayfs is
slower for a runner's own builds, so it is enabled per runner class, not by
default: with `GHA_SHARED_IMAGES` unset, or naming a path that is not there,
nothing is written and podman's storage is exactly as before.

Read-only is the point: a job can use an image from the store and cannot
change, add or remove one, so nothing a job does reaches the next job through
it. `scripts/smoke-test.sh` checks the store, the read-only half, and that
nothing changes when the variable is unset.

## Job containers and services

A job with `container:` or `services:` makes the runner call `docker create`
with `-v /var/run/docker.sock:/var/run/docker.sock`, a path it hardcodes. That
path links to the podman API the entrypoint serves, through the `docker` shim,
so those jobs start here as they do on GitHub's machines. The socket gives a
job container what any job's own steps already have here: podman as the runner
user, in a container that is thrown away after the job.

## Which jobs reach it

The consuming repository decides, by expression rather than by a setting
someone can click past. In `trentina`:

```yaml
runs-on: >-
  ${{ github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.full_name == github.repository
      && github.event.pull_request.user.login != 'dependabot[bot]'
      && (vars.CACHED_RUNNER_LABEL || 'ubuntu-latest')
      || github.event_name != 'pull_request'
      && (vars.UNCACHED_RUNNER_LABEL || 'ubuntu-latest')
      || 'ubuntu-latest' }}
```

A fork's pull request never executes on our runners. Neither does a Dependabot pull
request: its job runs the new release of a third-party package, and that is not
code we want writing to the cached runner's storage. Pushes and scheduled runs
go to the uncached runner, so the image that gets published comes from storage
nothing else has written to.

Clearing `CACHED_RUNNER_LABEL` or `UNCACHED_RUNNER_LABEL` is the kill switch for
that runner: its jobs go back to GitHub-hosted with no commit and no review. Use
it when the host is down, because a required check that never reports blocks
every pull request silently.
