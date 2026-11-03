# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-03

### Added

- First release: an ephemeral, rootless GitHub Actions runner image with nested
  podman, for `crunchtools/trentina`'s container gate.
- `deploy/` carries the systemd unit, the resource slice and the env template,
  for `/srv/gha-runner.crunchtools.com/config/`.
- Weekly rebuild, so the base image's security updates reach the runner without
  anyone remembering to push.
