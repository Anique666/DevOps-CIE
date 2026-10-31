#!/usr/bin/env bash
# Build the worker image. Run from anywhere; paths are resolved from the repo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${IMAGE:-cie-worker:1.0}"

echo "==> Building $IMAGE from docker/Dockerfile"
docker build --pull -f docker/Dockerfile -t "$IMAGE" .

echo
echo "==> Image details"
docker image inspect "$IMAGE" \
  --format 'Repository: {{index .RepoTags 0}}
Image ID:   {{.Id}}
Size:       {{.Size}} bytes
User:       {{.Config.User}}
Exposed:    {{.Config.ExposedPorts}}'
