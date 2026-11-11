# gha-runner Constitution

> **Version:** 1.3.0
> **Ratified:** 2026-11-03
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.39.1
> **Profile:** Container Image

The self-hosted GitHub Actions runner image, for any Crunchtools repository
whose CI is cache-bound. It is a build machine: it takes one job, runs it, and
exits. It builds and runs containers for that job, nested and rootless. It
ships nothing and serves nothing.

Nothing in the image names a consuming repository. Runners register to the
crunchtools organization (`GHA_ORG`) in a runner group (`GHA_RUNNER_GROUP`);
the group's repository list decides which repositories may use them, and each
repository's `runs-on` decides which of its jobs land here. A second consumer
is a change to that list and to its own workflow, not a second deployment and
not a second image. `GHA_REPO` remains for a runner that serves one
repository. `crunchtools/trentina` is the first, because
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
"what changed under us" must never be an open question. The pin moves only
when a person edits it.

**The OS layer's only control is `dnf -y upgrade` on every build.** Trivy has
no Fedora advisory source: it detects `family="fedora"`, warns `Unsupported
os`, and scans language packages only. Its green result says nothing about the
OS packages, and with the base pinned nothing else would ever move them. So the
Containerfile upgrades before it installs, a per-run `UPGRADE_STAMP` build arg
keeps the layer cache from replaying an old upgrade, and the weekly rebuild is
what carries Fedora's fixes in.

## Where This Image Is Published

`quay.io/crunchtools/gha-runner` (Quay.io is the only registry).

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
- **Two deployments, named for their storage.** `gha-runner-cached` keeps its
  nested container storage on a host path (`data/containers`, the layer cache)
  and takes a repository's own pull requests. `gha-runner-uncached` keeps it on
  a tmpfs inside the container and takes the builds that get published. A
  cached store cannot build a release: every job it runs can write to that
  storage, and podman reuses an extracted layer without re-hashing it. Each runs
  as its own user, so neither can reach the other's store.
- Mounts, and no others. Host paths: the service's `config` (the env file,
  read-only) and, on the cached runner only, `data/containers`. Tmpfs: the
  directory carrying the registration token, which the runner unlinks once it
  has registered (a DIRECTORY rather than a podman secret because a secret
  mount is read-only and that unlink has to be real); and, on the uncached
  runner only, the nested container storage, capped in size and charged to the
  slice like the job itself.
- **Ephemeral registration, one job per container, on both.** A registration
  token is minted per container start by a separate short-lived container that
  alone holds the GitHub App private key; the runner registers `--ephemeral`,
  takes one job and exits, and the unit's restart starts a fresh one. A job can
  steal nothing durable — the token it could read is good for one hour and
  only registers runners — and nothing it starts outlives it:
  no process, no modified runner file, and on the uncached runner no stored
  layer.

  Persistent registration (credentials saved in `data/state` and reused, the
  runner taking jobs continuously) was the 1.0.0 posture of the cached runner
  and is retired: job code could read those credentials and impersonate the
  runner, and a job could leave a process or a file behind for the next job.
  The entrypoint still supports it for a host with no App key; neither
  deployment uses it.

  The job-completed hook removes containers and the workspace after each job.
  It, and the entrypoint beside it, are root-owned in a root-owned directory
  and not in the job user's home: a hook that user could replace would run one
  job's code inside the next.
- No registry credential and no production secret is ever mounted.
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
