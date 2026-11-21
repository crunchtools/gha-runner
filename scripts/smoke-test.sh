#!/bin/bash
# The constitution's nested test, as CI runs it.
#
# A successful image BUILD proves almost nothing here: the one property that
# makes this image usable is that a job can build AND run containers inside it,
# and the build half works on bases where the run half does not. That is
# exactly how UBI 10 was eliminated. So both are asserted, every time, before
# the image is published.
#
# Usage: smoke-test.sh <image>
set -euo pipefail

IMAGE=${1:?usage: smoke-test.sh <image>}
ENGINE=${ENGINE:-docker}

run_in_image() {
  "$ENGINE" run --rm \
    --device /dev/fuse \
    --security-opt label=disable \
    --security-opt seccomp=unconfined \
    --entrypoint /bin/bash "$IMAGE" -c "$1"
}

echo "== the runner binary is the pinned version"
run_in_image 'cd actions-runner && ./config.sh --version'

# --version never touches libssl. Registration does, on its first HTTPS call,
# and that is where a base whose OpenSSL the runner's .NET cannot load aborts
# ("No usable version of libssl was found", exit 134): podman 6 on Fedora 45
# shipped only libssl.so.4 and every Exedore runner crash-looped. A bogus token
# takes registration through a real TLS round trip to GitHub and back with a
# 404, which is the pass: an HTTP status means the handshake completed.
echo "== the runner completes a TLS round trip (registration, bogus token)"
run_in_image 'set -uo pipefail
cd actions-runner
out=$(./config.sh --unattended --url https://github.com/crunchtools/gha-runner \
  --token AAAAAAAAAAAAAAAAAAAAAAAAAAAAA --name smoke-tls 2>&1)
rc=$?
if [ "$rc" -ge 128 ] || grep -qi "libssl" <<<"$out"; then
  printf "%s\n" "$out" >&2; echo "Runner.Listener died loading TLS (exit $rc)" >&2; exit 1
fi
grep -q "Http response code: " <<<"$out" \
  || { printf "%s\n" "$out" >&2; echo "no HTTP response from GitHub" >&2; exit 1; }
grep "Http response code: " <<<"$out" | head -1 | cut -c1-80
echo "TLS from Runner.Listener: ok"'

echo "== gh, which Gatehouse's review, triage and retriage call"
run_in_image 'gh --version | head -1'

# What jobs held on GitHub's machines need (a283). The libraries are the ones
# puppeteer's Chrome links beyond this base, from ldd on Chrome for Testing 158.
echo "== shellcheck, skopeo, pip, and Chrome's shared libraries"
run_in_image 'set -euo pipefail
shellcheck --version | sed -n 2p
skopeo --version
python3 -m pip --version
missing=
for lib in libnss3.so libnssutil3.so libsmime3.so libnspr4.so libatk-1.0.so.0 \
    libatk-bridge-2.0.so.0 libcups.so.2 libdbus-1.so.3 libdrm.so.2 libgbm.so.1 \
    libpango-1.0.so.0 libcairo.so.2 libasound.so.2 libexpat.so.1 libX11.so.6 \
    libxcb.so.1 libXcomposite.so.1 libXdamage.so.1 libXext.so.6 libXfixes.so.3 \
    libXrandr.so.2 libxkbcommon.so.0 libudev.so.1; do
  /sbin/ldconfig -p | grep -q "^[[:space:]]*$lib " || missing="$missing $lib"
done
[ -z "$missing" ] || { echo "missing:$missing" >&2; exit 1; }
fc-list | grep -q . || { echo "no fonts" >&2; exit 1; }
echo "Chrome libraries and a font: ok"'

echo "== docker is shimmed to podman"
run_in_image 'docker --version | grep -qi podman && echo "docker -> podman: ok"'

# The hook runs after every job as the same uid a job's steps run as, so a hook
# that uid can replace is a command one job leaves for the next. Assert the
# image as the runner will have it rather than trusting the Containerfile to
# have kept saying `/usr/local/bin`: ownership and mode, the entrypoint and the
# hook path the entrypoint actually exports, and the two operations that have
# to fail. `write refused` covers mode; `unlink refused` covers the directory,
# which is the half a chmod does not reach.
echo "== the entrypoint and the job hook are out of the job user's reach"
run_in_image 'set -e
for f in entrypoint.sh job-completed.sh mint-registration-token.sh; do
  stat -c "%n %U %a" "/usr/local/bin/$f"
  [ "$(stat -c %u /usr/local/bin/$f)" = 0 ] || { echo "NOT root-owned: $f" >&2; exit 1; }
  [ -w "/usr/local/bin/$f" ] && { echo "writable by $(id -u): $f" >&2; exit 1; }
done
echo x > /usr/local/bin/job-completed.sh 2>/dev/null \
  && { echo "job user rewrote the hook" >&2; exit 1; } || echo "write refused: ok"
rm -f /usr/local/bin/job-completed.sh 2>/dev/null \
  && { echo "job user unlinked the hook" >&2; exit 1; } || echo "unlink refused: ok"
grep -q "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh" \
  /usr/local/bin/entrypoint.sh || { echo "entrypoint exports another hook path" >&2; exit 1; }'

"$ENGINE" image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE" \
  | grep -q '/usr/local/bin/entrypoint.sh' \
  || { echo "image entrypoint is not the installed one" >&2; exit 1; }
echo "image entrypoint: ok"

# a358/a364: Red Hat images must still be signature-checked, not merely pullable.
# The shipped policy has to accept both images below, and must reject them when
# the signing key or the Rekor key is swapped for a throwaway P-256 key, each
# with the error that proves which check fired (c/image v5.42.1,
# signature/policy_eval_sigstore.go): a wrong signing key fails to match the
# key the Rekor SET records, a wrong Rekor key fails the SET's own signature.
# A non-ECDSA key would be rejected at policy load and prove nothing.
#
# ubi-init is pinned by digest on purpose: this digest carries signatures in
# BOTH Red Hat Rekor logs -- 1231502a... (2026-11-18, key unpublished, #44) and
# ca942090... (the shipped REKOR-signing-key) -- so it proves a signature from
# an unknown log beside a good one does not reject the image. The tag moves;
# this digest does not, and the grep below fails if its signatures change.
echo "== Red Hat images are verified (release3 sigstore signature + Rekor SET)"
run_in_image 'set -euo pipefail
mixed=registry.access.redhat.com/ubi10/ubi-init@sha256:56b166666bfea9e23148aea63e035690dec4aca88372da83de0012d466aa5183
sigs=$(skopeo inspect --raw "docker://${mixed%@*}:$(echo "${mixed#*@}" | tr : -).sig")
for log in 1231502a ca942090; do
  grep -q "$log" <<<"$sigs" || { echo "$mixed has no signature in Rekor log $log: mixed-log coverage lost" >&2; exit 1; }
done
echo "pinned ubi-init carries both Rekor logs: ok"
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl ec -pubout -out /tmp/throwaway.pub 2>/dev/null
python3 - <<PY
import json
for name, field in (("wrong-key", "keyPath"), ("wrong-rekor", "rekorPublicKeyPath")):
    p = json.load(open("/etc/containers/policy.json"))
    for r in ("registry.access.redhat.com", "registry.redhat.io"):
        assert field in p["transports"]["docker"][r][0], field
        p["transports"]["docker"][r][0][field] = "/tmp/throwaway.pub"
    json.dump(p, open(f"/tmp/{name}.json", "w"))
PY
declare -A want=(
  [wrong-key]="No public key verified against the RekorSET: publicKey in Rekor SET does not match"
  [wrong-rekor]="No public key verified against the RekorSET: cryptographic signature verification of Rekor SET failed"
)
for ref in docker://registry.access.redhat.com/ubi10/ubi-minimal:latest "docker://$mixed"; do
  rm -rf /tmp/ok
  skopeo copy -q "$ref" dir:/tmp/ok
  echo "$ref: verified pull with the shipped policy: ok"
  for bad in wrong-key wrong-rekor; do
    rm -rf /tmp/bad
    if skopeo --policy "/tmp/$bad.json" copy -q "$ref" dir:/tmp/bad 2>/tmp/err; then
      echo "$ref: a policy with the $bad accepted the image: verification is not running" >&2; exit 1
    fi
    grep -qF "${want[$bad]}" /tmp/err || { echo "$ref: $bad rejected for the wrong reason:" >&2; cat /tmp/err >&2; exit 1; }
    echo "$ref: $bad rejected by the expected check: ok"
  done
done'

echo "== nested BUILD"
run_in_image 'podman build -q -t smoke:build -f - /tmp <<CF
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest
RUN echo nested-build-works > /proof
CF
'

echo "== nested RUN -- the half that eliminated UBI 10 as a base"
run_in_image 'podman build -q -t smoke:run -f - /tmp >/dev/null <<CF
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest
RUN echo nested-run-works > /proof
CF
podman run --rm smoke:run cat /proof'

echo "== a job container and a service container, as the runner starts them"
# The runner's own sequence for \`container:\` and \`services:\` (actions/runner
# ContainerOperationProvider): one network, a service reachable by its alias,
# and a job container with /var/run/docker.sock mounted, kept alive by tail.
# Run with the entrypoint's podman API up, since that is what the socket serves.
# unmask=ALL is the deploy units' flag: netavark sets the bridge's sysctls, and
# a nested container gets its own procfs rather than ours (a472).
#
# The named network needs a nested rootless network namespace, which GitHub's
# Ubuntu VMs refuse (pasta: Permission denied) and the deployed hosts allow
# (verified on Exedore, a273c). So on a GitHub-hosted runner that half is
# skipped, loudly; the socket half runs everywhere.
named_net=1
if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
  named_net=0
  echo "::warning title=smoke test::named network and service alias NOT tested: a GitHub-hosted VM cannot run a nested rootless network namespace. This half runs on our own runners."
fi
"$ENGINE" run --rm \
  --device /dev/fuse \
  --device /dev/net/tun \
  --security-opt label=disable \
  --security-opt seccomp=unconfined \
  --security-opt unmask=ALL \
  -e NAMED_NET="$named_net" \
  --entrypoint /bin/bash "$IMAGE" -c '
set -euo pipefail
export XDG_RUNTIME_DIR=/home/podman/.runtime
mkdir -p "$XDG_RUNTIME_DIR/podman" && chmod 700 "$XDG_RUNTIME_DIR"
podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" >/dev/null 2>&1 &
for _ in $(seq 50); do [ -S /var/run/docker.sock ] && break; sleep 0.1; done
test -S /var/run/docker.sock
podman info --format "storage: {{.Store.GraphDriverName}} {{json .Store.GraphOptions}}"
img=registry.access.redhat.com/ubi10/ubi-minimal:latest
docker pull -q "$img" >/dev/null
docker version --format "{{.Server.APIVersion}}" >/dev/null
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  --entrypoint test "$img" -S /var/run/docker.sock
echo "job container gets the socket: ok"
# /proc/1 is this container init only when its /proc is its own. Behind any
# masked path crun bind-mounts the runner /proc instead, and a nested PID then
# names some other process (a472: mypy INTERNAL ERROR via psutil).
docker run --rm --entrypoint sh "$img" -c \
  "test \"\$(readlink /proc/1/ns/pid)\" = \"\$(readlink /proc/self/ns/pid)\"" \
  || { echo "nested container sees the runner /proc, not its own" >&2; exit 1; }
echo "nested container has its own /proc: ok"
if [ "$NAMED_NET" != 1 ]; then
  echo "named network and service alias: SKIPPED on a GitHub-hosted runner"
  exit 0
fi
docker network create smoke_net >/dev/null
docker create --name smoke_svc --network smoke_net --network-alias svc \
  --entrypoint tail "$img" -f /dev/null >/dev/null
docker start smoke_svc >/dev/null
docker create --name smoke_job --network smoke_net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp:/__w --workdir /__w \
  --entrypoint tail "$img" -f /dev/null >/dev/null
docker start smoke_job >/dev/null
docker exec smoke_job test -S /var/run/docker.sock
# The alias must resolve to the service itself, through aardvark-dns. Anything
# else -- an NXDOMAIN that falls through the host search domain to an outside
# host of the same name, which is how Exedore first "passed" -- is a failure:
# a real job would quietly talk to that host instead of its service.
svc_ip=$(docker inspect smoke_svc --format "{{(index .NetworkSettings.Networks \"smoke_net\").IPAddress}}")
got=$(docker exec smoke_job getent ahostsv4 svc | awk "NR==1 {print \$1}")
if [ -z "$svc_ip" ] || [ "$got" != "$svc_ip" ]; then
  echo "alias svc resolved to \"$got\", not the service at \"$svc_ip\"" >&2
  docker exec smoke_job cat /etc/resolv.conf >&2
  exit 1
fi
docker rm -f smoke_job smoke_svc >/dev/null
docker network rm smoke_net >/dev/null
echo "job container and service on a named network: ok"'

# podman 6 reads the base's 20-image_build.conf, which would put every job on
# fuse-overlayfs with fsync=0; the image's 30-gha-runner.conf must win.
echo "== GHA_SHARED_IMAGES unset or missing: native overlay, no drop-in written"
run_in_image 'set -euo pipefail
dir=$HOME/.config/containers/storage.conf.d
/usr/local/bin/shared-images.sh
GHA_SHARED_IMAGES=/nowhere /usr/local/bin/shared-images.sh 2>/dev/null
test ! -e "$dir"
driver=$(podman info --format "{{.Store.GraphDriverName}}")
options=$(podman info --format "{{json .Store.GraphOptions}}")
echo "storage: $driver $options"
[ "$driver" = overlay ]
case $options in
  *fuse-overlayfs*|*fsync*|*/var/lib/shared*) echo "not native overlay: $options" >&2; exit 1 ;;
esac
echo "unset and missing: ok"'

echo "== GHA_SHARED_IMAGES set: a read-only store's image runs without a pull"
# Warmed by this image as its own user, as the README says to warm it, then
# mounted read-only, as a unit mounts it.
store=$(mktemp -d)
trap '"$ENGINE" unshare rm -rf "$store" 2>/dev/null || rm -rf "$store" 2>/dev/null || true' EXIT
"$ENGINE" run --rm \
  --device /dev/fuse \
  --security-opt label=disable \
  --security-opt seccomp=unconfined \
  -v "$store":/store:U \
  --entrypoint /bin/bash "$IMAGE" -c '
set -euo pipefail
podman --root /store pull -q registry.access.redhat.com/ubi10/ubi-micro:latest >/dev/null
podman --root /store tag registry.access.redhat.com/ubi10/ubi-micro:latest localhost/only-in-store:smoke'
"$ENGINE" run --rm \
  --device /dev/fuse \
  --security-opt label=disable \
  --security-opt seccomp=unconfined \
  -v "$store":/var/lib/shared-images:ro \
  -e GHA_SHARED_IMAGES=/var/lib/shared-images \
  --entrypoint /bin/bash "$IMAGE" -c '
set -euo pipefail
/usr/local/bin/shared-images.sh
grep -q "force_mask = \"shared\"" "$HOME/.config/containers/storage.conf.d/50-shared-images.conf"
podman info --format "{{json .Store.GraphOptions}}" | grep -q fuse-overlayfs
podman run --rm --pull=never localhost/only-in-store:smoke /bin/true
echo "image from the store, no pull: ok"
if touch /var/lib/shared-images/written 2>/dev/null; then
  echo "the shared store took a write" >&2; exit 1
fi
if podman rmi localhost/only-in-store:smoke >/dev/null 2>&1 \
  && ! podman image exists localhost/only-in-store:smoke; then
  echo "a job removed an image from the shared store" >&2; exit 1
fi
echo "store refuses writes: ok"'

echo "== smoke test passed"
