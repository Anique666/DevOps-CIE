#!/usr/bin/env bash
# Build/load the image into Minikube and apply the Kubernetes manifests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${IMAGE:-cie-worker:1.0}"
NAMESPACE="${NAMESPACE:-cie}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: image $IMAGE not found. Run scripts/build.sh first." >&2
  exit 1
fi

if ! minikube status >/dev/null 2>&1; then
  echo "==> Starting Minikube (docker driver)"
  minikube start --driver=docker --cpus=2 --memory=4096
else
  echo "==> Minikube is already running"
fi

echo
echo "==> Loading $IMAGE into Minikube's container runtime"
minikube image load "$IMAGE"

echo
echo "==> Applying manifests (namespace first, then workloads)"
kubectl apply -f kubernetes/namespace.yaml
kubectl apply \
  -f kubernetes/configmap.yaml \
  -f kubernetes/deployment.yaml \
  -f kubernetes/service.yaml

echo
echo "==> Waiting for rollout"
kubectl -n "$NAMESPACE" rollout status deployment/cie-worker --timeout=180s

echo
kubectl -n "$NAMESPACE" get pods -o wide
echo
kubectl -n "$NAMESPACE" get service cie-worker

echo
echo "Access the API locally with:"
echo "  kubectl -n $NAMESPACE port-forward svc/cie-worker 8080:80"
echo "  curl http://127.0.0.1:8080/health"
echo "  curl 'http://127.0.0.1:8080/process?file=sample.txt'"
