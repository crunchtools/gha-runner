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

---

## License

AGPL-3.0-or-later

## Versioning

Follow Semantic Versioning 2.0.0. MAJOR/MINOR/PATCH.

## Base Image

`quay.io/podman/stable`, pinned by digest.

**This is a deliberate exception to the usual UBI base, and the reason is
measured rather than preferred.** A CI job must RUN containers, not merely build
them: every verification step in trentina's `container-scan` is a `docker run`.
On UBI 10 a nested `podman run` fails with ``mount `proc` to `proc`: Operation
not permitted``. Ruled out on the host by experiment: crun's version (1.30 and
1.30.1 both fail), the storage driver (`fuse-overlayfs` IS packaged in
ubi-10 appstream and does not fix it), every `netns`/`userns`/`cgroupns`
combination, `--privileged`, `--network host`, `unmask=ALL`, and the subuid
layout. UBI 10 pins podman 5.8.2 and ships no newer build. `quay.io/podman/stable`
(podman 5.8.9) does it correctly, and it is the upstream project's own
podman-in-podman image — which is precisely this image's job.

A Hummingbird/RHHI base is wrong here for a different reason: those images carry
no shell, no package manager and no coreutils by design, and every Actions
`run:` step executes as `bash -e {0}`. RHHI is what we ship; this is the machine
that builds it.

Pinned by DIGEST, not by tag, because this image executes repository code: "what
changed under us" must never be an open question. The weekly rebuild moves the
pin deliberately.

## Registry

Published to `quay.io/crunchtools/gha-runner`, mirrored to
`ghcr.io/crunchtools/gha-runner`.

## RHSM Registration

Not required.

## Containerfile Conventions

- Uses `Containerfile` (not Dockerfile)
- Required LABELs: `maintainer`, `description`
- `dnf install -y` with `--setopt=install_weak_deps=0`, followed by `dnf clean all`
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
  able to reach other services; it gets outbound egress and nothing else. This
  is a deliberate departure from the usual `--network crunchtools` unit.
- Two host paths are mounted and no others: the service's `config` (the env
  file) and `data` (the nested container storage, which is the layer cache the
  whole exercise is for). A third mount is permitted and is a tmpfs, not a host
  path with contents: the directory carrying the registration token, which the
  runner unlinks once it has registered. It is a DIRECTORY rather than a podman
  secret because a secret mount is read-only and that unlink has to be real.
- `--ephemeral`: one job, then the runner de-registers and the container exits.
  The unit restarts it. No job inherits another's workspace.
- The only credential is a GitHub App private key scoped to
  `administration:write` on ONE repository. No registry credential and no
  production secret is ever mounted.

## Testing

- **Build test**: CI builds the Containerfile successfully
- **Nested test**: a nested `podman build` and a nested `podman run` must both
  succeed. Either one failing makes the image useless, and only the build half
  works on bases that look fine.
- **Security scan**: Trivy on the built image

## Quality Gates

1. Build — CI builds the Containerfile successfully
2. Push — image published after a successful build
3. Weekly rebuild — cron picks up base image updates every Monday 4:30 AM UTC
