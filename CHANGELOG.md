# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **The Exedore unit templates match what runs there** (a315). After the libssl
  outage, the deployed `gha-runner-{cached,uncached}@.service` run
  `quay.io/crunchtools/gha-runner@sha256:9f8aa398…` (1.1.1) with
  `--pull=missing` instead of `:main` with `--pull=newer`, so a merge no longer
  reaches the pool by itself. The repo copies now say the same.
  `deploy/exedore/README.md` "Promoting a new image" gives the steps: verify
  by digest, canary one uncached runner, then sed and reload.
  `scripts/deploy-units-test.sh`, run by `deploy-units-test.yml`, fails if
  either template names `:main` or `--pull=newer`, or if the templates pin
  different digests. `gha-images-warm` runs the same digest with
  `--pull=missing`, is promoted with the units, and is checked the same way.
- **The cached runners' stores are pruned daily** (a315). Each grew to 40-45G
  unpruned and filled the runner filesystem (ENOSPC on private-repo jobs).
  `gha-runner-prune.timer` touches `/run/gha-runner-prune/requested`, a
  root-owned directory the runners can only read. Each cached runner's own
  `ExecStartPre` runs `gha-runner-prune` between two jobs, never under one,
  when the request is newer than its stamp. That removes images created more
  than 7 days ago, tagged or pulled by digest (except those in
  `shared-images.list` and the pinned runner image), the build layer cache and
  leftover build containers. The prune container runs with `--init` and
  `--replace`, so a timed-out prune can't block the next one.
  `scripts/gha-runner-prune-test.sh` tests it with a stub podman, including
  the timer-to-runner handoff taken from the unit files.
- **skopeo is floored at 1.25.1** (a315). 1.24.1-1 vendors `golang.org/x/net`
  0.56.0 (GO-2026-6612, Critical). Fedora mirrors still serving it after
  1.25.1-2 went stable failed `container-scan` at random. A lagging mirror now
  fails the build with "No match" instead. `sdlc ci` also passes
  `UPGRADE_STAMP` (`sdlc.toml`), so a cached runner no longer replays an old
  package layer.
- **The runner filesystem is 400G** (a315), grown online from 200G. The mount
  unit's "To grow it" now gives the online steps (`truncate`, `losetup -c`,
  `xfs_growfs`). The pool doesn't need stopping.

## [1.1.1] - 2026-11-18

### Added

- **skopeo** (a308). constitution's `container-release.yml` calls it in `build`
  (tagging a pull request's image `pr-N` by digest) and in `mark`, so private
  repos' container releases can run here instead of on GitHub's machines. The
  smoke test checks it.

## [1.1.0] - 2026-11-18

### Added

- **Tests for `gha-images-warm`** (#34, a298). `scripts/gha-images-warm-test.sh`
  puts a stub `podman` first on PATH and runs the warm script against a
  temporary store, list and HOME: an empty list, pruning a pending ID that is
  still dangling and keeping one that is not, a failed pull setting the exit
  status without stopping the rest, and the final `chmod -R a+rX` on disk.
  `images-warm-test.yml` runs it on every change. The script reads its store
  and list from `GHA_IMAGES_STORE` and `GHA_IMAGES_LIST` when set; the unit
  sets neither.
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

- **The Exedore pool** (`deploy/exedore`, a264). It runs six ephemeral runners
  in the `exedore` runner group: `gha-runner-cached@1..4` and
  `gha-runner-uncached@1..2`. Each instance gets its own rootless user, subuid
  range and OpenBao AppRole. They share one slice (16 CPUs, 24G), whose weight
  sits on `gha.slice`, where it competes with the seats. Storage is a 200G
  XFS loop image on the backup volume, capped by its size, and uncached
  scratch is on disk rather than tmpfs. An nftables owner match keeps runner
  traffic off the host, the seats and the private networks, multicast and
  broadcast included.
  `gha-runner-instance` provisions an instance.
- Constitution 1.5.0 lets an uncached runner keep its nested storage in a
  host scratch directory of its own, emptied before and after every job, as
  Exedore's do: a tmpfs there would be charged to the pool's memory.

### Fixed

- **The runner starts on the podman 6 base** (a300). Fedora 45's
  `openssl-libs` is OpenSSL 4 (`libssl.so.4`) and the runner's .NET probes only
  for `libssl.so.3` and older, so `Runner.Listener` aborted on its first HTTPS
  call ("No usable version of libssl was found", exit 134) and every Exedore
  runner crash-looped until the units were pinned back to sha-ee3cb4d. The
  image now installs Fedora's `openssl3-libs`. The smoke test registers with a
  bogus token, which takes the runner through a real TLS round trip to GitHub
  and fails on anything but an HTTP status coming back; `--version` never
  loaded libssl, which is how #33 passed.
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
- **podman 6.2.0** (`quay.io/podman/stable:v6.2.0-immutable`, by digest),
  which carries none of the three Critical Go CVEs in Fedora's podman 5.8.9
  binary, so `.grype.yaml` and its ignores are gone (#26, #28). podman 6 reads
  the base's rootless storage drop-in, which would put every job on
  fuse-overlayfs with `fsync=0`; the image's `30-gha-runner.conf` keeps native
  overlay, and the smoke test asserts it.
- `shared-images.sh` writes a user `storage.conf.d` drop-in instead of
  `storage.conf`, so it layers over the image's storage rather than replacing it.

### Added

- **A shared, read-only image store, opt-in.** With `GHA_SHARED_IMAGES` set
  to a store the unit mounts read-only, the entrypoint writes the podman
  user's `storage.conf` to read it as an additional image store, on
  fuse-overlayfs with `force_mask = "shared"`, so jobs run its images without
  pulling. Unset, nothing is written and storage is as before. The smoke test
  covers both, and that a job cannot write to the store.
- **What GitHub-held jobs need (a283):** shellcheck, python3-pip, and the
  libraries and font puppeteer's headless Chrome loads (nss, nspr, atk, cups,
  gbm, pango, the X client libraries and others). Chrome for Testing 158
  renders a page in the image; the smoke test checks each library resolves.
- Constitution 1.5.0 lets the image override the base's rootless storage
  drop-in to stay on native overlay.
- Constitution 1.4.0 permits that mount and says what the docker.sock link
  grants.

### Removed

- Gloval's deploy files (`deploy/gha-runner-{cached,uncached}.crunchtools.com.service`,
  their `.env.example` files and `deploy/gha-runner.slice`). Scott retired both
  gloval runners (a279), and the host side is gone, so the README's gloval
  layout and install steps and `deploy/exedore`'s gloval rollback go with them.

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
