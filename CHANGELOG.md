# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
