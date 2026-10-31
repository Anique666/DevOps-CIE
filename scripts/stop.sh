#!/usr/bin/env bash
# Stop and remove the Docker worker. Minikube is left running on purpose.
set -euo pipefail

NAME="${NAME:-cie-worker}"
docker rm -f "$NAME" >/dev/null 2>&1 && echo "Removed container $NAME" || echo "No container $NAME"
