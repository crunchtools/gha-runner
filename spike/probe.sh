#!/bin/sh
# a1058: informational probes. Exit 1 means "does not work", so the log is readable.
NESTED=docker.io/library/docker@sha256:cd58b396e427d1ee8cddcc3f3b7e8d8c2ba45755c5dd5b821b6e615e1ccf4586
PODMAN=quay.io/podman/stable@sha256:f4ca9cbb3a7c33c168d565d2ba75882903f4440561e8ffd825249f9c9b84f28b
self=$(hostname); docker inspect "$self" >/dev/null 2>&1 || self=$(grep -oE '(containers|overlay-containers)/[0-9a-f]{64}' /proc/self/mountinfo | head -1 | sed 's,.*/,,')
sock=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Source}}{{end}}{{end}}' "$self")
[ -n "$sock" ] || sock=/var/run/docker.sock
echo "server: $(docker version --format '{{.Server.Version}} {{.Server.Os}}') socket-host=$sock"
case "${1:-}" in
podman-remote)  # the design's sdlc-boot carries a podman remote client
  docker run --rm -v "$sock:/run/s.sock" "$PODMAN" podman --remote --url unix:///run/s.sock version 2>&1 | tail -6
  docker run --rm -v "$sock:/run/s.sock" "$PODMAN" podman --remote --url unix:///run/s.sock run --rm "$NESTED" echo PODMAN-REMOTE-OK 2>&1 | tail -3 | grep -q PODMAN-REMOTE-OK && echo "PROBE podman-remote ok" || echo "PROBE podman-remote fails" ;;
one-var)  # can one 450,000-byte variable reach a nested process?
  big=$(head -c 337500 /dev/urandom | base64 -w0)
  printf '%s' "$big" > /tmp/big
  n=$(docker run --rm -e BIG="$(cat /tmp/big)" "$NESTED" sh -c 'echo ${#BIG}' 2>&1 | tail -2); echo "$n"
  [ "$n" = 450000 ] && echo "PROBE one-var ok (one 450,000-byte variable reached a nested process)" || echo "PROBE one-var refused: $n" ;;
esac
