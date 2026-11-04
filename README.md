# gha-runner

The self-hosted GitHub Actions runner image for Crunchtools. It takes one job,
runs it, and exits.

Generic by construction: nothing in the image names a repository. `GHA_REPO`,
`GHA_LABELS` and which repositories the GitHub App is installed on decide that,
so a second consumer is a second deployment rather than a second image.
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

The same image runs as two units on gloval, named for what they do:

| Unit | User | Label | Container storage | Takes |
|---|---|---|---|---|
| `gha-runner-cached.crunchtools.com` | `ghrunner-cached` | `crunchtools-cached` | persistent bind mount: the layer cache | our pull requests |
| `gha-runner-uncached.crunchtools.com` | `ghrunner-uncached` | `crunchtools-uncached` | 16g tmpfs, empty every job | pushes to `main`: the build that gets published |

The cache is what makes the cached runner fast, and it is also why nothing it
builds may be published: every job it runs can write to that storage, and podman
reuses an extracted layer without re-hashing it. Both runners register
`--ephemeral`, take one job and exit, so no process or runner file outlives its
job; the cached one keeps only its layer cache. The uncached runner's storage is
a tmpfs inside the container, so its next job starts from nothing. Separate
users keep the two stores apart.

Each unit's files go to its own `/srv/<unit>/config/`:

```
/srv/gha-runner-cached.crunchtools.com/
├── config/   # gha-runner-cached.env, the .service and .slice
└── data/
    └── containers/   # nested container storage: the layer cache. A CACHE --
                      # exclude it from backups.
/srv/gha-runner-uncached.crunchtools.com/
└── config/   # gha-runner-uncached.env and the .service; it keeps no data
```

The units and the shared slice are installed from `config/` to
`/etc/systemd/system/`, so git in `/srv` stays the source of truth and the drift
checks can see it:

```bash
install -m 0644 /srv/gha-runner-cached.crunchtools.com/config/gha-runner.slice /etc/systemd/system/
for u in gha-runner-cached gha-runner-uncached; do
  install -m 0644 /srv/$u.crunchtools.com/config/$u.crunchtools.com.service /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable --now gha-runner-cached.crunchtools.com gha-runner-uncached.crunchtools.com
```

The GitHub App private key is a **podman secret**, not a file in `config/`:

```bash
podman secret create gha-app-key /path/to/app-private-key.pem   # as each runner user
```

Podman secrets are per user, so each runner user holds its own copy. Both
runners mint a registration token on every start.

The App, `gha-runner.crunchtools.com`, holds one permission: **Organization >
Self-hosted runners: Read and write**. Runners register to the crunchtools org,
in the `gloval` runner group. Which repositories may use them is that group's
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

A fork's pull request never executes on gloval. Neither does a Dependabot pull
request: its job runs the new release of a third-party package, and that is not
code we want writing to the cached runner's storage. Pushes and scheduled runs
go to the uncached runner, so the image that gets published comes from storage
nothing else has written to.

Clearing `CACHED_RUNNER_LABEL` or `UNCACHED_RUNNER_LABEL` is the kill switch for
that runner: its jobs go back to GitHub-hosted with no commit and no review. Use
it when the host is down, because a required check that never reports blocks
every pull request silently.
