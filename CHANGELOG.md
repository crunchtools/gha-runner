# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`gh`.** GitHub's hosted image ships it, and Gatehouse's `review`, `triage`
  and `retriage` jobs call it for every API read and write, so they can run
  here (crunchtools/gatehouse, a281). Upstream's 2.103.0, pinned by version
  and sha256: Fedora's 2.97.0 is built with a vulnerable `golang.org/x/net`.
  The smoke test checks it.
- **grype ignores expire.** grype's rules have no expiry field, so each
  `.grype.yaml` ignore carries an `EXPIRES YYYY-MM-DD` comment, and
  `grype-expiry.yml` fails on every change and daily once one has passed.
  The file is parsed as YAML, so every `ignore:` entry counts, whatever it
  matches on (`vulnerability`, `package`, `fix-state`) and in block or flow
  style. Each is governed by the nearest `EXPIRES` at or above it; one with
  none, under a malformed or impossible date, or dated more than 90 days
  out, fails. `.grype.yml` and
  `.grype/config.yaml`, which grype also loads, fail by existing
  (`scripts/grype_expiry.py`, tested by `scripts/test_grype_expiry.py`).

### Fixed

- **Jobs with `container:` or `services:` start.** The runner hardcodes
  `-v /var/run/docker.sock:/var/run/docker.sock` for them, and no socket was
  there, so they failed in "Initialize containers" (crunchtools/gatehouse#153).
  `/run/docker.sock` now links to the podman API the entrypoint already serves.
  The smoke test replays the runner's network, service and job-container
  sequence before the image is published. Both units add
  `--security-opt unmask=/proc/sys`: without it the nested netavark cannot set
  its bridge's `route_localnet` on the read-only `/proc/sys`, and no job's
  named network starts (found on Exedore). Rootless, nothing host-wide becomes
  writable.
- `.grype.yaml` ignores the three Critical Go CVEs compiled into Fedora's
  podman 5.8.9 binary, each pinned to its vulnerable version and expiring
  2026-12-18; podman 6 fixes them (#26, #28).

### Added

- **A shared, read-only image store, opt-in.** With `GHA_SHARED_IMAGES` set
  to a store the unit mounts read-only, the entrypoint writes the podman
  user's `storage.conf` to read it as an additional image store, on
  fuse-overlayfs with `force_mask = "shared"`, so jobs run its images without
  pulling. Unset, nothing is written and storage is as before. The smoke test
  covers both, and that a job cannot write to the store.
- Constitution 1.4.0 permits that mount and says what the docker.sock link
  grants.

## [1.0.1] - 2026-11-11

### Changed

- **Runners register to the organization.** With `GHA_ORG` set, the mint script
  and the entrypoint register org-level runners in `GHA_RUNNER_GROUP`, through
  a GitHub App holding only Organization > Self-hosted runners. One key on the
  host serves every repository the runner group admits. `GHA_REPO` keeps the
  single-repository mode. A runner's name is `GHA_RUNNER_NAME` plus its
  container id, since every container is a new one-job runner. Constitution
  1.2.0: a second consumer is a runner-group change, not a second deployment.
- **Two deployments, cached and uncached.** `gha-runner.crunchtools.com` is
  renamed `gha-runner-cached.crunchtools.com` (user `ghrunner-cached`, label
  `crunchtools-cached`) and keeps its persistent layer cache for pull requests.
  The new `gha-runner-uncached.crunchtools.com` (user `ghrunner-uncached`,
  label `crunchtools-uncached`) registers `--ephemeral` and keeps its container
  storage on a tmpfs, so every job starts empty: it builds what gets published.
  Both now register `--ephemeral` and take one job per container; the cached
  runner no longer stays up between jobs, where one job could leave a process
  behind for the next. Constitution 1.1.0 records the two deployments, the
  uncached runner's storage tmpfs, and ephemeral registration on both.

### Fixed

- **The OS layer is upgraded on every build.** The base is pinned by digest and
  Trivy cannot scan Fedora packages, so nothing ever moved them: each weekly
  rebuild reproduced the same OS layer. The Containerfile now runs
  `dnf -y upgrade` before installing, with a per-run `UPGRADE_STAMP` build arg
  so the gha layer cache cannot replay an old result. Constitution 1.3.0 names
  Trivy's blind spot and the upgrade as the control (#14).

- The uncached runner's storage tmpfs is a `--mount type=tmpfs,...,U=true`:
  `--tmpfs` takes no `uid=` option, and podman refused to start the container.
- The base image is re-pinned to `quay.io/podman/stable:v5.8.9-immutable`'s
  digest. The 1.0.0 pin had been garbage-collected from quay, so the image
  could not be built.

## [1.0.0] - 2026-11-03

First release. It runs `crunchtools/trentina`'s container gate on gloval, which
took that job from 7m43s to 2m33s -- the win is the layer cache, 2m11s cold to
7s warm, not the cores.

### Added

- A rootless GitHub Actions runner image with nested podman, on
  `quay.io/podman/stable` pinned by digest. Not UBI, and not a Hummingbird
  image: a job has to RUN containers, not only build them, and the run half
  fails on UBI 10. The reasoning is in the Containerfile and the constitution.
- Two registration modes, and the difference is a real security trade stated in
  the constitution rather than left in the code. *Ephemeral* is the better one
  and the target: a token minted per start, one job, then de-registration.
  *Persistent* is what runs without a GitHub App to mint from -- credentials
  earned once and reused, which job code running as the same user can read.
  What makes that acceptable is who can put code here: the consuming repository
  routes only its own pull requests to this runner, never a fork's.
- A job-completed hook for the persistent mode, removing containers and the
  workspace between jobs and deliberately keeping images, because the images
  are the cache. It and the entrypoint are root-owned outside the job user's
  home: a hook that user could replace would run one job's code inside the next.
- A `docker` -> podman shim, in this image only, because the container gate
  shells out to `docker` for every step.
- A podman API socket inside the container, for tools that inspect an image
  rather than run one (Trivy finds nothing without it).
- `deploy/` carries the systemd unit, the resource slice and the env template,
  for `/srv/gha-runner.crunchtools.com/config/`.
- The smoke test is the constitution's test, and it gates publishing: a nested
  `podman build` AND a nested `podman run`, plus the assertion that the job user
  can neither rewrite nor unlink the hook.
- Weekly rebuild, so the base image's security updates reach the runner without
  anyone remembering to push.
