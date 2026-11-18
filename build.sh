#!/usr/bin/env bash
# Builds the ingress-nginx controller image for the host architecture from
# Chainguard's fork. Usage: UPSTREAM_TAG=controller-v1.15.15 ./build.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

UPSTREAM_REPO=https://github.com/chainguard-forks/ingress-nginx.git
IMAGE=ghcr.io/glueops/ingress-nginx/controller

# Git allows shell metacharacters in tag names, so accept only the exact shape.
if [[ ! ${UPSTREAM_TAG:-} =~ ^controller-v1\.15\.[0-9]+$ ]]; then
  echo "UPSTREAM_TAG must look like controller-v1.15.N" >&2
  exit 1
fi
UPSTREAM_SHA=${UPSTREAM_SHA:-$(git ls-remote "$UPSTREAM_REPO" "refs/tags/$UPSTREAM_TAG" | cut -f1)}
if [[ ! $UPSTREAM_SHA =~ ^[0-9a-f]{40}$ ]]; then
  echo "could not resolve $UPSTREAM_TAG to a commit SHA" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# The fork's own TAG file is stale, so the version comes from the tag name.
version=${UPSTREAM_TAG#controller-}

rm -rf upstream
git init -q upstream
git -C upstream fetch -q --depth 1 "$UPSTREAM_REPO" "$UPSTREAM_SHA"
git -C upstream checkout -q FETCH_HEAD

# Must be a tag (FROM <image ID> is treated as a registry name) and unique, so
# a base left over from an earlier build can never be picked up.
base=local/nginx-base:$UPSTREAM_SHA-$(date -u +%Y%m%d%H%M%S)
trap 'docker rmi "$base" >/dev/null 2>&1 || true' EXIT

# --builder default: only the docker driver can see the locally built base.
docker build --builder default --provenance=false --sbom=false \
  -t "$base" upstream/images/nginx/rootfs

# Same builder image upstream's Makefile uses: golang:$(GO_VERSION)-alpineX.Y
# shellcheck disable=SC2016
alpine=$(grep -oE 'golang:\$\(GO_VERSION\)-alpine[0-9.]+' upstream/Makefile | head -n1 || true)
go_image=golang:$(cat upstream/GOLANG_VERSION)-${alpine##*-}
if [[ ! $go_image =~ ^golang:[0-9.]+-alpine[0-9.]+$ ]]; then
  echo "could not work out the Go builder image from upstream/Makefile" >&2
  exit 1
fi
docker run --rm -u "$(id -u):$(id -g)" \
  -v "$PWD/upstream:/src" -w /src \
  -e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOMODCACHE=/tmp/gomod \
  -e PKG=k8s.io/ingress-nginx -e ARCH="$arch" -e TAG="$version" \
  -e COMMIT_SHA="$UPSTREAM_SHA" -e REPO_INFO="$UPSTREAM_REPO" \
  "$go_image" build/build.sh

# BASE_IMAGE must always be ours: the fork's NGINX_BASE default is upstream's
# old, unpatched nginx.
docker build --builder default --provenance=false --sbom=false \
  --build-arg BASE_IMAGE="$base" \
  --build-arg VERSION="$version" \
  --build-arg COMMIT_SHA="$UPSTREAM_SHA" \
  --label org.opencontainers.image.source=https://github.com/GlueOps/ingress-nginx \
  --label org.opencontainers.image.vendor=GlueOps \
  -t "$IMAGE:$version-$arch" upstream/rootfs

echo "built $IMAGE:$version-$arch from $UPSTREAM_TAG ($UPSTREAM_SHA)"
