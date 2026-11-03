# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
