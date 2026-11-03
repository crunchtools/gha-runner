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

## Deployment

Files in `deploy/` go to `/srv/gha-runner.crunchtools.com/config/`:

```
/srv/gha-runner.crunchtools.com/
├── config/   # gha-runner.env, the .service and .slice
└── data/
    └── containers/   # nested container storage: the layer cache. A CACHE --
                      # exclude it from backups.
```

The GitHub App private key is a **podman secret**, not a file in `config/`:

```bash
podman secret create gha-app-key /path/to/app-private-key.pem
```

The App needs `administration:write` on the one repository whose runners it
registers, and nothing else. No registry credential and no production secret is
mounted: the workflows that hold those stay on GitHub-hosted runners.

### Two departures from the standard Crunchtools unit

Both security, not taste, and both are in the constitution:

- **`User=ghrunner`, not root.** This container runs repository code. A job that
  escapes it must not land as root on the host.
- **Not on the `crunchtools` network.** The internal network is how production
  services reach each other; a CI job must not be able to. Outbound only.

### Verify the quota actually bound

systemd will accept a cap and not apply it — a drop-in added while a slice is
already running is the usual way. Check both sides:

```bash
systemctl show gha-runner.slice -p CPUQuotaPerSecUSec -p MemoryMax
cat /sys/fs/cgroup/gha-runner.slice/cpu.max      # expect: 1200000 100000
```

## Which jobs reach it

The consuming repository decides, by expression rather than by a setting
someone can click past. In `trentina`:

```yaml
runs-on: >-
  ${{ github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.full_name == github.repository
      && (vars.FAST_RUNNER_LABEL || 'ubuntu-latest')
      || 'ubuntu-latest' }}
```

A fork's pull request therefore never executes here. `push`, `schedule` and
`workflow_dispatch` stay GitHub-hosted, so the image that gets published is
never built by this runner — it can make a pull request pass that should not;
it cannot ship.

Clearing `FAST_RUNNER_LABEL` is the kill switch: every job goes back to
GitHub-hosted with no commit and no review. Use it when the host is down,
because a required check that never reports blocks every pull request silently.
