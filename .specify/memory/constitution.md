# gha-runner Constitution

> **Version:** 2.0.0
> **Ratified:** 2026-11-03 (2.0.0: 2026-11-24, RT #1664)
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.46.0
> **Profile:** Container Image

The self-hosted GitHub Actions runner for Crunchtools, as a RHEL bootc VM
image. Exedore builds a disk from it and boots a fresh copy for every job: the
VM takes one job, runs it, and powers off. It builds and runs containers for
that job. It ships nothing and serves nothing.

Nothing in the image names a consuming repository. Runners register to the
crunchtools organization in a runner group; the group's repository list and
each repository's `runs-on` decide who uses them.

Everything in the inherited constitution and the Container Image profile
applies and is not restated, except where this file says otherwise. What
follows is only what is particular to this image.

---

## Why A VM (2.0.0)

1.x was a rootless container that ran jobs in rootless podman nested inside it.
A job that itself nests podman (sdlc's check does) was then three levels deep,
and that fails: there are too few ids to map and /proc cannot be mounted at
the third level. A VM gives each job its own kernel, so the job's container is
level one and anything it nests is level two, which is what GitHub-hosted
runners offer. The isolation boundary moves from user namespaces on a shared
host to KVM.

## Base Image

`registry.redhat.io/rhel10/rhel-bootc`, pinned by digest.

Pinned by DIGEST, not by tag, because this image executes repository code:
"what changed under us" must never be an open question. The pin moves only
when a person edits it.

**The OS layer's control is `dnf update` on every build**, inside the one
RHSM register/unregister layer. A per-run `UPGRADE_STAMP` build arg keeps the
layer cache from replaying an old update, and the weekly rebuild is what
carries RHEL errata in.

The base's own containers policy is kept: it requires sigstore signatures,
checked against Rekor, for `registry.redhat.io` and
`registry.access.redhat.com`. The smoke test fails if that changes.

## Where This Image Is Published

`quay.io/crunchtools/gha-runner` (Quay.io is the only registry). 1.x digests
stay there, and anything that pins one keeps running it.

## Containerfile Rules Particular To This Image

- The runner tarball is verified by `sha256sum -c` against a pinned digest. An
  unverified CI runner binary is a supply-chain hole with a shell attached.
- The docker CLI is copied from an image pinned by digest. It drives the VM's
  podman through `/run/docker.sock`.
- The runner lives read-only in `/usr`. Each boot copies it to `/var` for its
  one job.

## Runtime

- **One job per VM, and one VM per job.** Each boot starts from a fresh qcow2
  overlay on a base disk built from a pinned digest. The overlay is deleted
  when the VM powers off, so a job can leave nothing behind for the next one.
- **Root inside the guest, unprivileged outside it.** The runner and the job
  run as root in the VM, which gives the job rootful podman with native
  overlay. This is the deliberate exception to the profile's rootless-runtime
  rule: the boundary is the hypervisor. On the host, qemu runs as a per-slot
  user with no shell, in the egress fence's uid range, with only `/dev/kvm`
  and its own overlay.
- **Ephemeral just-in-time registration.** The host mints a JIT config for one
  named runner with the GitHub App key, which never enters the VM. The config
  reaches the VM as the `gha.jitconfig` systemd credential and the runner as
  an environment variable, never on a command line. The runner removes it from
  the environment its jobs inherit. A job that read it could only act as the
  runner it already is, for the job it is already running.
- **Egress only.** The VM's user-mode network leaves the host as the slot's
  uid, so the nft fence blocks the LAN exactly as it did for 1.x.
- **One shared image store, read-only.** The host serves a rootful image store
  over virtiofs with `--readonly`. The VM lists it as an additional image
  store. Jobs read images from it and can neither add, change nor remove one,
  so it carries nothing from one job to the next.
- No registry credential and no production secret ever enters the VM.
- `/var/run/docker.sock` is the VM's podman socket. The runner mounts it into a
  job's `container:` and `services:`. Inside a throwaway VM it grants what the
  job already has.

## The Test That Decides This Image

In CI, against the pushed digest (`scripts/vm-smoke-test.sh`):

- `bootc container lint` passes;
- the runner and the docker CLI run;
- the boot units are enabled;
- the shared store is listed;
- the Red Hat signature policy holds;
- the start script refuses to run without a credential.

GitHub's runners have no KVM, so the decisive half runs on Exedore before a
digest is promoted to the VM slots. A booted VM must take a real job and
complete both a nested `podman build` and a nested `podman run`. An image that
builds is not evidence of an image that works.
