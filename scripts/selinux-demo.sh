#!/usr/bin/env bash
# SELinux demonstration: permitted read with :Z vs denied read without :Z.
#
# This script intentionally starts a container WITHOUT a volume label first.
# That produces a real SELinux denial (container_t -> user_home_t). It then
# starts the same image with :Z and verifies the permitted read.
#
# It does not disable SELinux or weaken any control.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${IMAGE:-cie-worker:1.0}"
DENIED_NAME="cie-selinux-denied"
DENIED_PORT="${DENIED_PORT:-5001}"
DATA_DIR="$ROOT_DIR/data"

echo "============================================================"
echo "1. Host SELinux status"
echo "============================================================"
getenforce
sestatus | sed -n '1,8p'
echo
echo "Input directory context:"
ls -Zd "$DATA_DIR"
echo
echo "Docker SELinux support:"
docker info --format '{{json .SecurityOptions}}' | jq .

CURRENT_LABEL="$(ls -Zd "$DATA_DIR" | awk '{print $1}')"
if [[ "$CURRENT_LABEL" != *":user_home_t:"* ]]; then
  echo
  echo "Resetting the lab data directory to its default user_home_t label."
  echo "Preferred command (needs root): sudo restorecon -F -Rv $DATA_DIR"
  echo "Fallback used here (user owns the lab files): chcon -R ..."
  chcon -R -u unconfined_u -r object_r -t user_home_t -l s0 "$DATA_DIR" || {
    echo "ERROR: could not relabel $DATA_DIR. Run: sudo restorecon -F -Rv $DATA_DIR" >&2
    exit 1
  }
  ls -Zd "$DATA_DIR"
fi

echo
echo "============================================================"
echo "2. DENIED: read /data without a Docker SELinux label (:Z)"
echo "============================================================"
echo "Command: docker run --rm ... -v $DATA_DIR:/data:ro ..."
echo "The host label stays user_home_t, which container_t may not read."
echo

set +e
DENIAL_OUTPUT="$(
  docker run --rm --name "$DENIED_NAME" \
    --user 10001:10001 \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    -v "${DATA_DIR}:/data:ro" \
    "$IMAGE" \
    python -c "print(open('/data/sample.txt', encoding='utf-8').read()[:60])" 2>&1
)"
DENIAL_RC=$?

echo "$DENIAL_OUTPUT"
echo "Exit status: $DENIAL_RC"
if [[ "$DENIAL_RC" -eq 0 ]]; then
  echo
  echo "UNEXPECTED: the read succeeded without :Z."
  echo "Check that SELinux is Enforcing and that the data directory is user_home_t."
else
  echo
  echo "Expected result: non-zero exit because SELinux denied container_t access."
fi

echo
echo "============================================================"
echo "3. Same failure through the Flask API (no :Z)"
echo "============================================================"
docker rm -f "$DENIED_NAME" >/dev/null 2>&1 || true
docker run -d --name "$DENIED_NAME" \
  --user 10001:10001 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -p "127.0.0.1:${DENIED_PORT}:5000" \
  -v "${DATA_DIR}:/data:ro" \
  -e INPUT_DIR=/data \
  "$IMAGE" >/dev/null

for _ in $(seq 1 20); do
  curl -sS "http://127.0.0.1:${DENIED_PORT}/health" >/dev/null 2>&1 && break
  sleep 1
done

echo "Health:"
curl -sS -w '\nHTTP %{http_code}\n' "http://127.0.0.1:${DENIED_PORT}/health" || true
echo
echo "Process request:"
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode "file=sample.txt" \
  "http://127.0.0.1:${DENIED_PORT}/process" || true
echo
echo "Application log:"
docker logs --tail 20 "$DENIED_NAME" 2>&1 || true
docker rm -f "$DENIED_NAME" >/dev/null 2>&1 || true

echo
echo "============================================================"
echo "4. Audit evidence (AVC denials)"
echo "============================================================"
echo "Journal view of the container_t denial (permissive=0 means enforcing):"
journalctl --since "15 min ago" --no-pager 2>/dev/null \
  | grep -i 'avc.*container_t' | tail -20 || true
echo
if sudo -n true 2>/dev/null; then
  echo "AVC records from auditd:"
  sudo ausearch -m AVC -ts recent 2>/dev/null | grep -E 'type=AVC|denied' | tail -30 || true
else
  echo "sudo requires a password in this shell, so run these manually:"
  echo "  sudo ausearch -m AVC -ts recent | grep -i 'container_t'"
  echo "  sudo ausearch -m AVC -ts recent -c python"
  echo "  journalctl --since '15 min ago' | grep -i 'avc.*container_t'"
fi

echo
echo "============================================================"
echo "5. PERMITTED: same image with read-only :Z label"
echo "============================================================"
"$ROOT_DIR/scripts/run.sh" || { echo "ERROR: run.sh failed" >&2; exit 1; }

echo
echo "Permitted request:"
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode "file=sample.txt" \
  "http://127.0.0.1:${PORT:-5000}/process"

echo
echo "Data directory label after :Z relabel (private MCS category):"
ls -Zd "$DATA_DIR"
echo
echo "To restore the normal home-directory label after the lab:"
echo "  sudo restorecon -F -Rv $DATA_DIR"
