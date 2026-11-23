#!/bin/sh
# Spike A1058: mechanics of "sdlc-boot" -- resolve sdlc:<major> to a digest,
# cosign-verify it against a BAKED public key, enforce a BAKED minimum version,
# then run the verified digest as a sibling container. Every refusal exits 2.
#
# Runs in a docker:28 CLI job container; everything else is a sibling via
# /var/run/docker.sock. No -v of job-container paths (they would be host
# paths): files travel via docker cp, tar|docker build, env vars, or stdout.
#
# The self-hosted runner fences host-local addresses, so NOTHING uses localhost:
# the registry is a sibling on a user-defined network, addressed as reg:5000,
# and every registry interaction is a sibling (skopeo, cosign) on that network.
#
# MODEL: the real boot image bakes sdlc.pub, MAJOR and MIN_VERSION. Here a
# "boot stub" image carries them (file + labels) and boot() reads them back
# with docker create/cp/inspect, so boot() never sees the test-harness values.
set -eu

BASE=registry.access.redhat.com/ubi10/ubi-micro@sha256:1c1666ee13b1d7c4a438f86bb32772910424c3dc0db2b53b1e52a0d7b987a15b
COSIGN=ghcr.io/sigstore/cosign/cosign@sha256:ad281047f85c5e1fc6ffbc30c2b55be3b07b4032bef715a12122ce5829619aca
REGISTRY=docker.io/library/registry@sha256:46faa9a1ae6813194b53921a370f2f4f8c5e1aae228a89bceafef5847a6a3278
SKOPEO=quay.io/containers/skopeo@sha256:0fb57c934e28d541d803bf7d34822acfeac465b26d80b37bc174c1dd7c16fdce
REG=reg:5000
REPO=$REG/sdlc
L=spike=a1058
KEYS=spike-a1058-keys
NET=spike-a1058-$$
TMP=$(mktemp -d)
FAILS=0
DIGEST=
# Legacy builder: talks to plain docker and to podman's compat API alike.
export DOCKER_BUILDKIT=0

cleanup() {
  c=$(docker ps -aq --filter "label=$L" 2>/dev/null || true)
  [ -z "$c" ] || docker rm -f $c >/dev/null 2>&1 || true
  docker volume rm -f "$KEYS" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== docker: server $(docker version --format '{{.Server.Version}}')" \
  "os=$(docker version --format '{{.Server.Os}}')" \
  "name=$(docker info --format '{{.Name}} / {{.OperatingSystem}}')"

# ---- cosign siblings -------------------------------------------------------
# Signer: has the key volume. Runs as root so it can write the fresh volume.
cs_sign() {
  docker run --rm --label "$L" --network "$NET" --user 0 -v "$KEYS:/keys" \
    -e COSIGN_PASSWORD= -e COSIGN_YES=true "$COSIGN" "$@"
}
# Verifier: no key volume; the public key arrives via env://.
cs_verify() {
  pub=$1; shift
  docker run --rm --label "$L" --network "$NET" -e "SDLC_PUB=$pub" "$COSIGN" "$@"
}

sk() { docker run --rm --label "$L" --network "$NET" "$SKOPEO" "$@"; }
sk_i() { docker run --rm -i --label "$L" --network "$NET" "$SKOPEO" "$@"; }

# ---- boot logic (the thing under test) ------------------------------------
die() { echo "REFUSE: $*" >&2; exit 2; }

# semver "X.Y.Z" (no leading zeros, no prerelease/build) -> succeeds if strict
is_semver() {
  printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}
# ver_ge A B -> A >= B
ver_ge() {
  a1=${1%%.*}; r=${1#*.}; a2=${r%%.*}; a3=${r#*.}
  b1=${2%%.*}; r=${2#*.}; b2=${r%%.*}; b3=${r#*.}
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -ge "$b3" ]
}

# Runs in a subshell with errexit ineffective: every step checks explicitly.
boot() {
  # baked values, read back out of the stub image
  stub=$(docker create --label "$L" sdlc-boot-stub /nonexistent) || die "stub"
  docker cp "$stub:/sdlc.pub" "$TMP/baked.pub" || die "baked key"
  PUB=$(cat "$TMP/baked.pub")
  MAJOR=$(docker inspect --format '{{index .Config.Labels "MAJOR"}}' sdlc-boot-stub)
  MIN_VERSION=$(docker inspect --format '{{index .Config.Labels "MIN_VERSION"}}' sdlc-boot-stub)
  [ -n "$PUB" ] && [ -n "$MAJOR" ] && is_semver "$MIN_VERSION" || die "bad baked config"

  # 1. tag -> digest (registry is http: skopeo needs --tls-verify=false)
  digest=$(sk inspect --tls-verify=false --format '{{.Digest}}' "docker://$REPO:$MAJOR") \
    || die "cannot resolve $REPO:$MAJOR"
  case $digest in sha256:????????????????????????????????????????????????????????????????) ;; *) die "bad digest '$digest'";; esac
  ref=$REPO@$digest
  echo "resolved $REPO:$MAJOR -> $digest"

  # 2. signature by the baked key, bound to our repo
  out=$(cs_verify "$PUB" verify --key env://SDLC_PUB -a repo=crunchtools/sdlc \
    --insecure-ignore-tlog --allow-insecure-registry --allow-http-registry "$ref") \
    || die "cosign verification failed"

  # 3. signed version annotation (optional.version in each payload) vs image label
  sigv=$(printf '%s' "$out" | tr -d ' \n' | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | sort -u)
  [ -n "$sigv" ] || die "no version annotation in signature"
  [ "$(printf '%s\n' "$sigv" | wc -l)" -eq 1 ] || die "conflicting version annotations: $sigv"
  labelv=$(sk inspect --tls-verify=false --format '{{index .Labels "version"}}' "docker://$ref") \
    || die "cannot read label"
  [ "$sigv" = "$labelv" ] || die "annotation $sigv != label '$labelv'"
  is_semver "$sigv" || die "version '$sigv' is not strict SemVer"
  [ "${sigv%%.*}" = "$MAJOR" ] || die "version $sigv not in major $MAJOR"
  ver_ge "$sigv" "$MIN_VERSION" || die "version $sigv < minimum $MIN_VERSION"
  echo "verified $sigv >= $MIN_VERSION"

  # 4. run exactly the verified digest. The daemon cannot reach reg:5000, so
  # skopeo copies that digest out as a tar and the job container loads it.
  sk copy -q --src-tls-verify=false "docker://$ref" docker-archive:/dev/stdout:sdlc-verified:run \
    >"$TMP/img.tar" || die "cannot fetch verified digest"
  docker load -q -i "$TMP/img.tar" >/dev/null || die "cannot load image"
  docker run --rm --label "$L" sdlc-verified:run || die "sibling run failed"
}

# ---- harness ---------------------------------------------------------------
# mkimg CASE LABEL_VERSION  -> builds, copies into the registry as $REPO:1, sets DIGEST.
# The case label keeps digests unique so signatures never leak between cases.
mkimg() {
  printf 'FROM %s\nLABEL version=%s case=%s\nCMD ["echo","SDLC-RAN-%s"]\n' \
    "$BASE" "$2" "$1" "$2" | docker build -q -t "sdlc-case:$1" - >/dev/null
  docker save "sdlc-case:$1" | sk_i copy --dest-tls-verify=false \
    docker-archive:/dev/stdin "docker://$REPO:1" >/dev/null
  DIGEST=$(sk inspect --tls-verify=false --format '{{.Digest}}' "docker://$REPO:1")
  [ -n "$DIGEST" ]
}
# sign KEY [-a k=v ...]
sign() {
  k=$1; shift
  cs_sign sign --key "/keys/$k.key" --allow-insecure-registry --allow-http-registry --tlog-upload=false \
    "$@" "$REPO@$DIGEST" >/dev/null 2>&1
}
# check NAME EXPECT [MARKER]
check() {
  rc=0
  (boot) >"$TMP/out" 2>&1 || rc=$?
  sed 's/^/    | /' "$TMP/out"
  ok=0
  [ "$rc" -eq "$2" ] && ok=1
  if [ "$ok" = 1 ] && [ -n "${3:-}" ]; then grep -q "$3" "$TMP/out" || ok=0; fi
  if [ "$ok" = 1 ]; then v=PASS; else v=FAIL; FAILS=$((FAILS + 1)); fi
  echo "CASE $1 expect=$2 got=$rc $v"
}

# ---- setup -----------------------------------------------------------------
docker volume create "$KEYS" >/dev/null
for k in good evil; do
  docker run --rm --label "$L" --user 0 -v "$KEYS:/keys" -w /keys -e COSIGN_PASSWORD= \
    "$COSIGN" generate-key-pair --output-key-prefix "$k" >/dev/null
done
kc=$(docker create --label "$L" -v "$KEYS:/keys" "$COSIGN")
mkdir "$TMP/stub"
docker cp "$kc:/keys/good.pub" "$TMP/stub/sdlc.pub"
printf 'FROM %s\nCOPY sdlc.pub /sdlc.pub\nLABEL MAJOR=1 MIN_VERSION=1.2.0\n' "$BASE" >"$TMP/stub/Dockerfile"
tar -C "$TMP/stub" -c . | docker build -q -t sdlc-boot-stub - >/dev/null

docker network create "$NET" >/dev/null
docker run -d --label "$L" --network "$NET" --name reg "$REGISTRY" >/dev/null
i=0
until docker exec reg wget -qO- http://localhost:5000/v2/ >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "registry did not start"; exit 1; }
  sleep 1
done

# ---- cases -----------------------------------------------------------------
GV="-a version=1.3.0"
R="-a repo=crunchtools/sdlc"

mkimg ok 1.3.0 && sign good $R $GV
check ok 0 SDLC-RAN-1.3.0

mkimg unsigned 1.3.0
check unsigned 2

mkimg wrong-key 1.3.0 && sign evil $R $GV
check wrong-key 2

mkimg wrong-repo 1.3.0 && sign good -a repo=crunchtools/evil $GV
check wrong-repo 2

mkimg label-mismatch 1.3.1 && sign good $R $GV
check label-mismatch 2

mkimg below-min 1.1.0 && sign good $R -a version=1.1.0
check below-min 2

mkimg wrong-major 2.0.0 && sign good $R -a version=2.0.0
check wrong-major 2

mkimg no-annotation 1.3.0 && sign good $R
check no-annotation 2

[ "$FAILS" -eq 0 ] || { echo "$FAILS case(s) FAILED"; exit 1; }
echo "all cases passed"
