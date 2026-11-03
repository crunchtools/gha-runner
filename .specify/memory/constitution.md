# gha-runner Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-11-03
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.29.0
> **Profile:** Container Image

The self-hosted GitHub Actions runner image, for any Crunchtools repository
whose CI is cache-bound. It is a build machine: it takes one job, runs it, and
exits. It builds and runs containers for that job, nested and rootless. It
ships nothing and serves nothing.

Nothing in the image names a consuming repository — `GHA_REPO`, `GHA_LABELS`
and the App installation decide that, so a second consumer is a second
deployment and not a second image. `crunchtools/trentina` is the first, because
its container gate is cache-bound rather than CPU-bound: a warm layer cache
took a cold 2m11s build of that project's image down to 7s, measured, and
GitHub-hosted runners start cold every time.

Everything in the inherited constitution and the Container Image profile
applies and is not restated. What follows is only what is particular to this
image.

---

## Base Image

`quay.io/podman/stable`, pinned by digest.

**A deliberate exception to the usual UBI base, on measurement rather than
preference.** A CI job must RUN containers, not merely build them: every
verification step in trentina's `container-scan` is a `docker run`. On UBI 10 a
nested `podman run` fails with ``mount `proc` to `proc`: Operation not
permitted``. Ruled out by experiment on the host: crun's version (1.30 and
1.30.1 both fail), the storage driver (`fuse-overlayfs` IS packaged in ubi-10
appstream and does not fix it), every `netns`/`userns`/`cgroupns` combination,
`--privileged`, `--network host`, `unmask=ALL`, and the subuid layout. UBI 10
pins podman 5.8.2 and ships no newer build. `quay.io/podman/stable`
(podman 5.8.9) does it correctly, and it is the upstream project's own
podman-in-podman image — which is precisely this image's job.

A Hummingbird/RHHI base is wrong here for a different reason: those images
carry no shell, no package manager and no coreutils by design, and every
Actions `run:` step executes as `bash -e {0}`. RHHI is what we ship; this is
the machine that builds it.

Pinned by DIGEST, not by tag, because this image executes repository code:
"what changed under us" must never be an open question. The weekly rebuild
moves the pin deliberately.

## Where This Image Is Published

`quay.io/crunchtools/gha-runner`, mirrored to `ghcr.io/crunchtools/gha-runner`.

## Containerfile Rules Particular To This Image

- The runner tarball is verified by `sha256sum -c` against a pinned digest. An
  unverified CI runner binary is a supply-chain hole with a shell attached.
- The base's `containers.conf`, `storage.conf` and `BUILDAH_ISOLATION=chroot`
  are NOT re-declared. They are why this base was chosen, and a local copy
  would drift from it.
- Runs as uid 1000 with the base's own subuid ranges, which the nesting needs.

## Runtime

- Rootless, as an unprivileged user with no sudo and no group shared with any
  production service. A job that escapes the container must not land as root on
  the host. This is the "rootless CI" half of the RT #1546 decision.
- Inside a systemd slice with a CPU and memory quota, so a build cannot starve
  whatever else the host runs.
- **Not** on the internal `crunchtools` podman network. A CI job must not be
  able to reach other services; it gets outbound egress and nothing else. A
  deliberate departure from the usual `--network crunchtools` unit.
- Two host paths are mounted and no others: the service's `config` (the env
  file) and `data` (the nested container storage, which is the layer cache the
  whole exercise is for). A third mount is permitted and is a tmpfs, not a host
  path with contents: the directory carrying the registration token, which the
  runner unlinks once it has registered. It is a DIRECTORY rather than a podman
  secret because a secret mount is read-only and that unlink has to be real.
- **Two registration modes, and the difference is a real security trade that is
  stated here rather than left in the code.**

  *Ephemeral* is the better one and the target: a registration token minted per
  container start, one job, then the runner de-registers. A job can then steal
  nothing durable — the token it could read is good for one repository for one
  hour and only registers runners. It requires a GitHub App private key on the
  host to mint from, held only by a separate short-lived minting container so
  it never enters the container where repository code runs.

  *Persistent* is what runs without that App: credentials earned once, kept in
  `data/state`, reused on every start. The cost is explicit — the runner
  process reads those credentials and job steps run as the same user, so job
  code can read them and impersonate this runner until they are revoked. This
  is the posture of essentially every self-hosted runner, and what makes it
  acceptable is not the credential handling, it is **who can put code here**:
  the consuming repository routes only its own pull requests to this runner, so
  a fork's code never executes on it. Revoking is removing the runner from the
  repository.

  Prefer ephemeral. Do not pretend persistent is ephemeral.

  `--once` is NOT the way to make persistent behave like ephemeral: one
  identity cannot hold two sessions, so restarting per job collides with the
  session the previous container still holds ("A session for this runner
  already exists"). Workspace hygiene comes from the job-completed hook, which
  removes containers and the workspace between jobs and deliberately keeps
  images, because the images are the cache. That hook, and the entrypoint
  beside it, are root-owned in a root-owned directory and not in the job user's
  home: a hook that user could replace would run one job's code inside the
  next.
- No registry credential and no production secret is ever mounted, in either
  mode.
- A podman API socket is served inside the container, because tools that
  INSPECT an image rather than run one — Trivy — reach the engine that way and
  otherwise cannot find the image the job just built. It grants what a job in
  this container already has and no more.

## The Test That Decides This Image

A nested `podman build` AND a nested `podman run` must both succeed, asserted
in CI before the image is published.

Both halves, every time, because the build half works on bases where the run
half does not — which is exactly how UBI 10 was eliminated. An image that
builds is not evidence of an image that works.
