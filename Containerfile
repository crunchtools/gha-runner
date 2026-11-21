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
# quay.io/podman/stable (Fedora, podman 6) does it correctly, and it is the
# upstream project's own podman-in-podman image -- which is the job here.
#
# WHY NOT A HUMMINGBIRD/RHHI IMAGE: those carry no shell, no package manager and
# no coreutils by design, and every Actions `run:` step executes as
# `bash -e {0}`. RHHI is what we ship; this is a build machine.
#
# The base already provides podman, crun, fuse-overlayfs, the nested
# containers.conf and BUILDAH_ISOLATION=chroot. Do not re-declare those here:
# they are the reason this base was chosen and a local copy would drift from
# it. Two exceptions, below: storage, and the /proc volume (a472).
#
# Pinned by digest, not by tag: the runner executes repository code, so "what
# changed under us" must never be a question.
# v6.2.0-immutable (Fedora 45, podman 6.2.0). podman 5's vendored grpc, x/net
# and podman module carried fixable Criticals that .grype.yaml had to ignore
# (#26, #28); 6.2.0 does not.
FROM quay.io/podman/stable@sha256:39a21e7832dbf018803aae152b421fc589563678e2559d36125a9cc4aba2617a

LABEL maintainer="crunchtools.com" \
      description="GitHub Actions self-hosted runner: ephemeral, rootless, with nested podman for container builds" \
      org.opencontainers.image.source="https://github.com/crunchtools/gha-runner" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

USER 0

# The runner is .NET: lttng-ust, openssl-libs, krb5-libs, zlib and libicu are
# upstream's stated Fedora prerequisites, and unlike UBI this base has all five.
# openssl3-libs too: Fedora 45's openssl-libs is OpenSSL 4 (libssl.so.4), and
# the runner's .NET probes only for libssl.so.3 and older, so without it
# Runner.Listener aborts on its first TLS call ("No usable version of libssl
# was found") -- every Exedore runner crash-looped on that. The smoke test
# registers against a bogus token to load libssl the way a real start does.
# git/tar/gzip are actions/checkout's; jq and openssl sign the GitHub App JWT in
# the entrypoint. skopeo is constitution container-release.yml's: build tags a
# pull request's image pr-N and mark tags it gated, registry to registry by digest.
# Floored at 1.25.1 (a315): 1.24.1-1 vendors golang.org/x/net 0.56.0
# (GO-2026-6612, Critical), and Fedora mirrors still serving it after 1.25.1-2
# went stable failed container-scan at random. A lagging mirror now fails this
# step with "No match" instead, and no build can ship the old one.
#
# The rest is what jobs held on GitHub's machines need to come here (a283):
# shellcheck (josui-skills), python3-pip (hermes' pin verifier tests), and the
# shared libraries puppeteer's Chrome loads (acquacotta's JavaScript tests),
# with one font so a page renders text. GitHub's hosted image carries all of
# them; the smoke test checks each library resolves.
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
      lttng-ust openssl-libs openssl3-libs krb5-libs zlib libicu \
      git tar gzip findutils which procps-ng hostname \
      jq openssl 'skopeo >= 1:1.25.1' \
      shellcheck python3-pip \
      nss nspr atk at-spi2-atk cups-libs dbus-libs libdrm mesa-libgbm \
      pango cairo alsa-lib expat libX11 libxcb libXcomposite libXdamage \
      libXext libXfixes libXrandr libxkbcommon liberation-sans-fonts \
 && dnf -y clean all \
 && rm -rf /var/cache/dnf

# security.yml:container-scan shells out to `docker` for every step -- build,
# run, inspect, logs, rm, and a `build -f -` heredoc. podman takes all of those
# verbs unchanged. The shim lives ONLY in this image: putting a /usr/bin/docker
# on a production host for a CI convenience is not a trade we make.
RUN printf '#!/bin/sh\nexec /usr/bin/podman "$@"\n' > /usr/local/bin/docker \
 && chmod 0755 /usr/local/bin/docker

# gh: GitHub's hosted image ships it, and Gatehouse's review, triage and
# retriage jobs call it for every API read and write (a281). Upstream's release,
# not Fedora's package: Fedora's 2.97.0 is built with golang.org/x/net 0.56.0,
# a fixable Critical (GO-2026-6612); 2.103.0 (2026-10-21) has 0.60.0. Pinned by
# version and digest, like the runner below.
ARG GH_VERSION=2.103.0
ARG GH_SHA256=fdd768eb70f6409f80fcfa9f3a1c0adf0fc98d827ab3ce0bed2ac22762c5d786
RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
 && tar xzf /tmp/gh.tar.gz -C /tmp "gh_${GH_VERSION}_linux_amd64/bin/gh" \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"

# A job with `container:` or `services:` makes the runner itself call
# `docker create ... -v /var/run/docker.sock:/var/run/docker.sock`, a path it
# hardcodes, so without a socket there every such job dies in "Initialize
# containers" (crunchtools/gatehouse#153). The entrypoint already serves the
# podman API at $XDG_RUNTIME_DIR/podman/podman.sock; point the docker path at
# it. It grants nothing a job lacks: podman as this user, as the shim does.
RUN ln -sfn /home/podman/.runtime/podman/podman.sock /run/docker.sock \
 && test "$(readlink -f /var/run)" = /run

# Storage. podman 6 reads the base's rootless drop-in
# /etc/containers/storage.rootless.conf.d/20-image_build.conf, which turns on
# fuse-overlayfs with mountopt "nodev,fsync=0" and adds /var/lib/shared as an
# image store -- right for building images, slower for a runner's jobs, and not
# what podman 5 gave this user (native overlay, no options). This later drop-in
# puts that back. shared-images.sh layers a user drop-in over it when a runner
# opts into a shared store (GHA_SHARED_IMAGES).
RUN printf '%s\n' \
      '# gha-runner: native overlay and no extra image store, as podman 5 gave' \
      '# the runner user. Overrides 20-image_build.conf.' \
      '[storage.options]' \
      'additionalimagestores = []' \
      '' \
      '[storage.options.overlay]' \
      'mount_program = ""' \
      'mountopt = "nodev"' \
      > /etc/containers/storage.rootless.conf.d/30-gha-runner.conf \
 && test -f /etc/containers/storage.rootless.conf.d/20-image_build.conf

# /proc (a472). The base's other rootless drop-in,
# /etc/containers/containers.rootless.conf.d/20-image_build.conf, adds the volume
# /proc:/proc to every container this user starts. A nested container then sees
# this runner's /proc beside its own PID namespace: its PIDs name other
# processes or none, psutil raises NoSuchProcess, and mypy 2.4 dies with
# INTERNAL ERROR (python-sdlc#75). Clearing the volume gives it a fresh procfs,
# which the kernel allows only while nothing of this container's /proc is
# masked -- so the units run it with unmask=/proc/*.
RUN printf '%s\n' \
      '# gha-runner: nested containers mount their own /proc. Overrides' \
      '# 20-image_build.conf; needs the runner started with unmask=/proc/*.' \
      '[containers]' \
      'volumes = []' \
      > /etc/containers/containers.rootless.conf.d/30-gha-runner.conf \
 && grep -q '"/proc:/proc"' /etc/containers/containers.rootless.conf.d/20-image_build.conf

# Signature policy (a358, a364). Red Hat entries require the release3 sigstore
# signature AND a Rekor SET checked against /etc/pki/sigstore/REKOR-signing-key
# (logID ca942090...), as containers-common's own policy does. On 2026-11-18
# Red Hat logged one day of signatures in a Rekor log with logID 1231502a...,
# whose key no package ships; a358 dropped the Rekor check for it. From
# 2026-11-19 Red Hat signs into ca942090 again, and an image is accepted when
# any one signature verifies (c/image prSigstoreSigned.isRunningImageAllowed),
# so a stray 1231502a signature beside a ca942090 one is ignored. When Red Hat
# publishes the new key (#44), ship it and use "rekorPublicKeyPaths": [old, new].
# /etc wins over /usr/share, so a containers-common update cannot undo this.
COPY containers/policy.json /etc/containers/policy.json
RUN chmod 0644 /etc/containers/policy.json \
 && python3 -c 'import json; p=json.load(open("/etc/containers/policy.json"))["transports"]["docker"]; assert all(p[r][0]["type"]=="sigstoreSigned" and p[r][0]["keyPath"]=="/etc/pki/sigstore/SIGSTORE-redhat-release3" and p[r][0]["rekorPublicKeyPath"]=="/etc/pki/sigstore/REKOR-signing-key" for r in ("registry.access.redhat.com","registry.redhat.io"))' \
 && test -s /etc/pki/sigstore/SIGSTORE-redhat-release3 \
 && test -s /etc/pki/sigstore/REKOR-signing-key

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
COPY scripts/entrypoint.sh scripts/mint-registration-token.sh scripts/job-completed.sh scripts/shared-images.sh /usr/local/bin/
RUN chmod 0555 /usr/local/bin/entrypoint.sh \
      /usr/local/bin/mint-registration-token.sh \
      /usr/local/bin/job-completed.sh \
      /usr/local/bin/shared-images.sh \
 && test -x /usr/bin/fuse-overlayfs

USER 1000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
