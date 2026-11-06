# The GitHub Actions self-hosted runner for crunchtools/trentina.
#
# WHAT THIS IMAGE IS: the machine a CI job runs on. It is NOT part of anything
# Trentina ships. Trentina's own image is built from Trentina's own
# Containerfile on quay.io/hummingbird/python:3.14, and nothing here changes a
# byte of it.
#
# WHY NOT UBI, WHICH WAS THE FIRST CHOICE: a job has to run containers, not just
# build them -- every verification step in security.yml:container-scan is a
# `docker run`. On UBI 10 a nested `podman run` fails with
# "mount `proc` to `proc`: Operation not permitted". Ruled out by measurement on
# this host: crun's version (1.30 and 1.30.1 both fail), the storage driver
# (fuse-overlayfs IS packaged in ubi-10 appstream and does not fix it), every
# netns/userns/cgroupns combination, --privileged, --network host, unmask=ALL,
# and the subuid layout. UBI 10 pins podman 5.8.2 and ships no newer build.
# quay.io/podman/stable (Fedora, podman 5.8.9) does it correctly, and it is the
# upstream project's own podman-in-podman image -- which is the job here.
#
# WHY NOT A HUMMINGBIRD/RHHI IMAGE: those carry no shell, no package manager and
# no coreutils by design, and every Actions `run:` step executes as
# `bash -e {0}`. RHHI is what we ship; this is a build machine.
#
# The base already provides podman, crun, fuse-overlayfs, the nested
# containers.conf/storage.conf and BUILDAH_ISOLATION=chroot. Do not re-declare
# those here: they are the reason this base was chosen and a local copy would
# drift from it.
#
# Pinned by digest, not by tag: the runner executes repository code, so "what
# changed under us" must never be a question.
# v5.8.9-immutable. The previous pin's digest was garbage-collected from quay
# (2026-11-04), which stopped every build of this image.
FROM quay.io/podman/stable@sha256:0ccbc4e7f79f9c33e7fc959be59f714abbc0f4c9cffbe14f5bceff537a014738

LABEL maintainer="crunchtools.com" \
      description="GitHub Actions self-hosted runner: ephemeral, rootless, with nested podman for container builds" \
      org.opencontainers.image.source="https://github.com/crunchtools/gha-runner" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

USER 0

# The runner is .NET: lttng-ust, openssl-libs, krb5-libs, zlib and libicu are
# upstream's stated Fedora prerequisites, and unlike UBI this base has all five.
# git/tar/gzip are actions/checkout's; jq and openssl sign the GitHub App JWT in
# the entrypoint.
#
# `dnf -y upgrade` first, because nothing else moves this layer: the base is
# pinned by digest, and Trivy has no Fedora advisory source (it prints
# `Unsupported os family="fedora"` and scans language packages only), so the
# OS packages get no CVE coverage. The weekly rebuild is the only control.
# UPGRADE_STAMP is per pipeline run and is referenced in the RUN on purpose:
# BuildKit only misses the cache where an ARG is used, and without the miss
# the gha layer cache would replay last week's upgrade forever.
ARG UPGRADE_STAMP=unset
RUN : "upgrade ${UPGRADE_STAMP}" \
 && dnf -y upgrade --setopt=install_weak_deps=0 \
 && dnf -y install --setopt=install_weak_deps=0 \
      lttng-ust openssl-libs krb5-libs zlib libicu \
      git tar gzip findutils which procps-ng hostname \
      jq openssl \
 && dnf -y clean all \
 && rm -rf /var/cache/dnf

# security.yml:container-scan shells out to `docker` for every step -- build,
# run, inspect, logs, rm, and a `build -f -` heredoc. podman takes all of those
# verbs unchanged. The shim lives ONLY in this image: putting a /usr/bin/docker
# on a production host for a CI convenience is not a trade we make.
RUN printf '#!/bin/sh\nexec /usr/bin/podman "$@"\n' > /usr/local/bin/docker \
 && chmod 0755 /usr/local/bin/docker

# uid 1000, with the base's own carefully-laid-out subuid ranges for nesting.
USER 1000
WORKDIR /home/podman

# Pinned by version AND digest: an unverified CI runner binary is a
# supply-chain hole with a shell attached.
# --retry, because the first build of this image failed on a transient 502
# from GitHub's release CDN. The weekly rebuild is unattended; one flaky
# download should not require a human.
RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - \
 && mkdir -p /home/podman/actions-runner \
 && tar xzf /tmp/runner.tar.gz -C /home/podman/actions-runner \
 && rm -f /tmp/runner.tar.gz

# Root-owned, mode 0555, and OUTSIDE /home/podman. The job-completed hook runs
# after every job as uid 1000 -- the same user a job's own steps run as -- so a
# hook that user can replace is a command a job leaves behind for the next one.
# Mode alone does not close that: /home/podman belongs to uid 1000, and write on
# a directory is permission to unlink a file in it whatever the file's own mode
# says. /usr/local/bin is root-owned and nothing here ever runs as root.
USER 0
COPY scripts/entrypoint.sh scripts/mint-registration-token.sh scripts/job-completed.sh /usr/local/bin/
RUN chmod 0555 /usr/local/bin/entrypoint.sh \
      /usr/local/bin/mint-registration-token.sh \
      /usr/local/bin/job-completed.sh

USER 1000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
