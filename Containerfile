# The GitHub Actions runner as a disposable RHEL bootc VM (RT #1664).
#
# One VM runs one job and powers off; Exedore boots a fresh qcow2 overlay for
# the next. The job gets a whole kernel, so nested podman needs none of the
# rootless tricks the retired container image (1.1.x) carried. Container
# images the jobs pull are shared read-only from the host over virtiofs (tag
# `images`); each VM's own storage stays native overlay on its disk.
#
# Pinned by digest: the runner executes repository code,
# so "what changed under us" must never be a question. 10.3-1793862045, the
# manifest list `latest` named on 2026-11-11 (catalog.redhat.com). The weekly
# build still takes errata from `dnf update`.
FROM registry.redhat.io/rhel10/rhel-bootc@sha256:47408136693bfe3aa58dad2a1f971c024fefd0802edf467a8de14de8e20bb910

LABEL maintainer="crunchtools.com" \
      description="GitHub Actions runner VM: RHEL bootc, one ephemeral job per boot" \
      org.opencontainers.image.source="https://github.com/crunchtools/gha-runner" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

# Register, install, and unregister in ONE layer with a trap so unregister and
# clean run on any exit (constitution II): no RHSM consumer leaks into
# console.redhat.com inventory as a ghost host. The weekly rebuild is what
# carries RHEL errata in: it runs on an ephemeral runner with a per-run cache,
# so this layer is built fresh, not replayed. Nothing here forces that.
RUN --mount=type=secret,id=activation_key \
    --mount=type=secret,id=org_id <<'RUNEOF'
set -euo pipefail
subscription-manager register \
    --activationkey="$(cat /run/secrets/activation_key)" \
    --org="$(cat /run/secrets/org_id)"
trap 'subscription-manager unregister || true; subscription-manager clean || true' EXIT
dnf update -y
# The container runner (1.1.5) shipped these and jobs depend on them:
# actions/checkout clones with git (without it, a REST tarball with no .git,
# and sdlc refuses with exit 2), and the dependency audit shells out to gh.
dnf install -y --nodocs --setopt=install_weak_deps=0 \
    podman \
    jq \
    libicu \
    krb5-libs \
    openssl-libs \
    zlib \
    tar \
    git gzip findutils which procps-ng hostname \
    openssl skopeo python3-pip \
    nss nspr atk at-spi2-atk cups-libs dbus-libs libdrm mesa-libgbm \
    pango cairo alsa-lib expat libX11 libxcb libXcomposite libXdamage \
    libXext libXfixes libXrandr libxkbcommon liberation-sans-fonts
dnf clean all
rm -rf /var/cache/dnf /var/cache/yum
RUNEOF

# Workflows call `docker`; podman answers on the socket the tmpfiles entry
# links to /run/docker.sock. Only the client from Docker's static tarball: the
# image job trusts no docker.io source (gha-runner#73), and dockerd and
# containerd have no place here.
ARG DOCKER_VERSION=29.10.0
ARG DOCKER_SHA256=7c1ebadc65c716cdc6d35fc78759ed0e4317debf43c21dd12f066f2006999def
RUN set -eu; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/docker.tgz \
      "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"; \
    echo "${DOCKER_SHA256}  /tmp/docker.tgz" | sha256sum -c -; \
    tar xzf /tmp/docker.tgz -C /tmp docker/docker; \
    install -m 0755 /tmp/docker/docker /usr/bin/docker; \
    rm -rf /tmp/docker.tgz /tmp/docker

# The runner lives read-only in /usr; runner-vm-start.sh copies it to /var for
# the one job, since the runner writes into its own directory.
ARG GH_VERSION=2.103.0
ARG GH_SHA256=fdd768eb70f6409f80fcfa9f3a1c0adf0fc98d827ab3ce0bed2ac22762c5d786
RUN set -eu; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/gh.tar.gz -C /tmp "gh_${GH_VERSION}_linux_amd64/bin/gh"; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/bin/gh; \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"
ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
RUN set -eu; \
    curl -fsSL -o /tmp/runner.tgz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  /tmp/runner.tgz" | sha256sum -c -; \
    mkdir -p /usr/lib/actions-runner; \
    tar -xzf /tmp/runner.tgz -C /usr/lib/actions-runner; \
    rm -f /tmp/runner.tgz

COPY vm/rootfs/ /
COPY scripts/runner-vm-start.sh /usr/libexec/runner-start.sh
RUN chmod 755 /usr/libexec/runner-start.sh \
 && systemctl enable podman.socket gha-runner.service 'var-lib-shared\x2dimages.mount'
