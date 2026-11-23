#!/bin/sh
# a1058 / sdlc#103 item 4: the runner's container socket from a `container:` job.
# Runs in docker:cli with /var/run/docker.sock mounted. Prints RESULT lines.
set -u
NESTED=docker.io/library/docker@sha256:cd58b396e427d1ee8cddcc3f3b7e8d8c2ba45755c5dd5b821b6e615e1ccf4586
PODMAN=quay.io/containers/podman@sha256:6cccd812027425f33fd7c65ca13e0ae6e19c5230a27a78708b199cf97569d85e
fails=0
result() { echo "RESULT $1 $2${3:+ ($3)}"; [ "$2" = pass ] || [ "$2" = info ] || fails=$((fails + 1)); }

echo "server: $(docker version --format '{{.Server.Version}} {{.Server.Os}}' 2>&1)"
docker info --format 'name={{.Name}} driver={{.Driver}} rootless={{.SecurityOptions}}' 2>&1 | head -3
docker run --rm "$NESTED" true && result socket-nested-run pass || result socket-nested-run fail

# Find our own container: hostname first, then the id in our mountinfo.
self=""
docker inspect "$(hostname)" >/dev/null 2>&1 && self=$(hostname)
if [ -z "$self" ]; then
  self=$(grep -oE '(containers|overlay-containers)/[0-9a-f]{64}' /proc/self/mountinfo | head -1 | sed 's,.*/,,')
fi
docker inspect "$self" >/dev/null 2>&1 || self=""  # an id our engine cannot see is not us
echo "self=$self"
mounts=$(docker inspect --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$self" 2>&1)
echo "$mounts"
ws=$(echo "$mounts" | awk -F'|' -v d="$GITHUB_WORKSPACE" '$2 != "" && index(d, $2) == 1 { print length($2), $1 "|" $2 }' | sort -rn | head -1 | cut -d' ' -f2-)
host_ws=""
if [ -n "$ws" ]; then
  src=${ws%%|*}; dst=${ws#*|}
  host_ws="$src${GITHUB_WORKSPACE#"$dst"}"
fi
sock_host=$(echo "$mounts" | awk -F'|' '$2 == "/var/run/docker.sock" { print $1 }')
if [ -z "$self" ] && [ -z "$host_ws" ]; then  # a plain step on the runner: no mapping needed
  host_ws=$GITHUB_WORKSPACE; sock_host=/var/run/docker.sock; echo "host mode: not in a job container"
fi
echo "GITHUB_WORKSPACE=$GITHUB_WORKSPACE host=$host_ws socket-host=$sock_host"
[ -n "$host_ws" ] && result workspace-host-path pass "$host_ws" || result workspace-host-path fail "self=$self"

mkdir -p "$GITHUB_WORKSPACE" && marker="a1058-$$-$(date +%s)" && echo "$marker" > "$GITHUB_WORKSPACE/marker"
got=$(docker run --rm -v "$host_ws:/w:ro" "$NESTED" cat /w/marker 2>&1)
[ "$got" = "$marker" ] && result workspace-mount pass || result workspace-mount fail "$got"

# Repo code runs nested with no token, no socket, no network, no caps.
out=$(docker run --rm --cap-drop=all --network=none -v "$host_ws:/w:ro" "$NESTED" sh -c '
  env | grep -iE "token|secret|github_" && echo LEAK-ENV
  [ -e /var/run/docker.sock ] && echo LEAK-SOCKET
  wget -q -T 5 -O /dev/null https://quay.io/ 2>/dev/null && echo LEAK-NET
  sed -n "3,\$p" /proc/net/dev | cut -d: -f1 | tr -d " "
  echo done' 2>&1)
echo "$out"
case "$out" in *LEAK*) result nested-isolation fail "$out" ;; *done*) result nested-isolation pass ;; *) result nested-isolation fail "$out" ;; esac
nets=$(echo "$out" | grep -vxE 'lo|done' | tr '\n' ' ')
[ -z "$nets" ] && result nested-network-none pass || result nested-network-none fail "$nets"

# Build a Containerfile FROM a verified @digest, no --privileged, RUN with no network.
ctx=$(mktemp -d)
printf 'FROM %s\nRUN echo built-%s > /built && cat /built\n' "$NESTED" "$marker" > "$ctx/Containerfile"
for kit in 1 0; do
  if DOCKER_BUILDKIT=$kit docker build --network=none -q -t "spike-a1058-build:$marker" -f "$ctx/Containerfile" "$ctx" >"$ctx/b.log" 2>&1; then
    out=$(docker run --rm "spike-a1058-build:$marker" cat /built 2>&1)
    [ "$out" = "built-$marker" ] && result build-from-digest pass "DOCKER_BUILDKIT=$kit" || result build-from-digest fail "$out"
    break
  fi
  echo "build with DOCKER_BUILDKIT=$kit failed:"; tail -5 "$ctx/b.log"
  [ "$kit" = 0 ] && result build-from-digest fail "both builders: $(grep -v '^ *$' "$ctx/b.log" | tail -1)"
done
docker rmi -f "spike-a1058-build:$marker" >/dev/null 2>&1

# The design's sdlc-boot carries a *podman remote* client: does it speak to this socket?
if [ -n "$sock_host" ]; then
  out=$(docker run --rm -v "$sock_host:/run/s.sock" "$PODMAN" podman --remote --url unix:///run/s.sock version 2>&1 | tail -4)
  echo "$out"
  case "$out" in *Server*|*"API Version"*) result podman-remote-client info "works" ;; *) result podman-remote-client info "fails: $(echo "$out" | tail -1)" ;; esac
fi
docker run --rm -v "$sock_host:/run/s.sock" "$NESTED" docker -H unix:///run/s.sock version --format '{{.Server.Version}}' >/dev/null 2>&1 \
  && result docker-client-sibling info works || result docker-client-sibling info fails

echo "socket.sh: $fails failure(s)"
exit "$fails"
