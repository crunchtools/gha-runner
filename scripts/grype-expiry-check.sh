#!/bin/bash
# The grype ignore expiry gate, as sdlc's `grype-expiry` command check runs it:
# the checker's own tests, then no ignore past its EXPIRES date. PyYAML is
# pinned by hash and installed outside the read-only checkout.
set -euo pipefail
deps=$(mktemp -d)
trap 'rm -rf "$deps"' EXIT
pip install -q --no-cache-dir --root-user-action=ignore --require-hashes \
  --only-binary=:all: --target "$deps" -r scripts/grype-expiry-requirements.txt
export PYTHONPATH=$deps
python scripts/test_grype_expiry.py
python scripts/grype_expiry.py
