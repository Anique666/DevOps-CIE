#!/usr/bin/env bash
# Print the evidence an examiner is likely to ask for:
# SELinux mode, file/process contexts, Docker security config, logs, network.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NAME="${NAME:-cie-worker}"
NETWORK="${NETWORK:-cie-net}"

echo "============================================================"
echo "SELinux"
echo "============================================================"
getenforce
sestatus | sed -n '1,8p'
echo
echo "Input directory label:"
ls -Zd data
echo

echo "============================================================"
echo "Container state"
echo "============================================================"
docker ps -a --filter "name=$NAME" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo

echo "============================================================"
echo "Security configuration (docker inspect)"
echo "============================================================"
docker inspect "$NAME" | jq '.[0] | {
  State: {Status: .State.Status, ExitCode: .State.ExitCode, Health: .State.Health.Status},
  User: .Config.User,
  ReadonlyRootfs: .HostConfig.ReadonlyRootfs,
  CapDrop: .HostConfig.CapDrop,
  SecurityOpt: .HostConfig.SecurityOpt,
  Privileged: .HostConfig.Privileged,
  NetworkMode: .HostConfig.NetworkMode,
  Mounts: [.Mounts[] | {Type, Source, Destination, Mode, RW}]
}'
echo

echo "============================================================"
echo "Process identity and SELinux context"
echo "============================================================"
docker exec --user 10001:10001 "$NAME" sh -c \
  'id; echo "selinux: $(cat /proc/self/attr/current)"; grep -E "^Cap(Inh|Prm|Eff|Bnd)" /proc/self/status'
echo
echo "Host view (ps -eZ):"
ps -eZ | grep -E 'container_t.*(gunicorn|python)' | head -5 || true
echo

echo "============================================================"
echo "Application logs"
echo "============================================================"
docker logs --tail 15 "$NAME" 2>&1
echo

echo "============================================================"
echo "Custom network"
echo "============================================================"
docker network inspect "$NETWORK" --format \
  'Name={{.Name}} Driver={{.Driver}} Subnet={{range .IPAM.Config}}{{.Subnet}}{{end}} Containers={{range .Containers}}{{.Name}} {{end}}'
