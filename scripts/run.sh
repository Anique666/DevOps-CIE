#!/usr/bin/env bash
# Run the worker with a hardened Docker configuration.
#
# Key security choices:
#   --user 10001:10001        non-root runtime identity
#   --read-only               immutable container root filesystem
#   --tmpfs /tmp              the only writable path, noexec/nosuid
#   --cap-drop ALL            no Linux capabilities
#   --security-opt no-new-privileges:true
#   -v ...:/data:ro,Z         read-only bind mount, private SELinux label
#   -p 127.0.0.1:...          listen on loopback only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${IMAGE:-cie-worker:1.0}"
NAME="${NAME:-cie-worker}"
NETWORK="${NETWORK:-cie-net}"
PORT="${PORT:-5000}"
INPUT_DIR="${INPUT_DIR:-$ROOT_DIR/data}"

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "ERROR: input directory does not exist: $INPUT_DIR" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: image $IMAGE not found. Run scripts/build.sh first." >&2
  exit 1
fi

# Custom bridge network (idempotent).
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "==> Creating custom bridge network $NETWORK"
  docker network create --driver bridge "$NETWORK"
fi

echo "==> Removing any previous container named $NAME"
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "==> Starting $NAME"
docker run -d \
  --name "$NAME" \
  --network "$NETWORK" \
  --user 10001:10001 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --publish "127.0.0.1:${PORT}:5000" \
  -v "${INPUT_DIR}:/data:ro,Z" \
  -e INPUT_DIR=/data \
  "$IMAGE" >/dev/null

echo "==> Waiting for the health endpoint"
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "ERROR: worker did not become healthy. Recent logs:" >&2
  docker logs --tail 40 "$NAME" >&2 || true
  exit 1
fi

echo
echo "==> Worker is healthy"
curl -sS "http://127.0.0.1:${PORT}/health" | jq .
echo
echo "Container : $NAME"
echo "Network   : $NETWORK"
echo "Endpoint  : http://127.0.0.1:${PORT}"
echo "Input     : $INPUT_DIR -> /data (ro, SELinux label Z)"
