#!/usr/bin/env bash
# End-to-end API tests against a running worker (Docker or port-forwarded K8s).
# Usage: BASE_URL=http://127.0.0.1:5000 scripts/test.sh
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:5000}"
EXPECTED_WORDS="${EXPECTED_WORDS:-114}"
RESP_BODY="$(mktemp)"
trap 'rm -f "$RESP_BODY"' EXIT

PASS=0
FAIL=0

request() {
  local method="$1" path="$2"
  shift 2
  HTTP_CODE="$(curl -sS -o "$RESP_BODY" -w '%{http_code}' -X "$method" "$@" "${BASE_URL}${path}")"
}

check_code() {
  local expected="$1" description="$2"
  if [[ "$HTTP_CODE" == "$expected" ]]; then
    printf 'PASS  %-55s HTTP %s\n' "$description" "$HTTP_CODE"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-55s expected HTTP %s, got %s\n' "$description" "$expected" "$HTTP_CODE"
    echo "      body: $(cat "$RESP_BODY")"
    FAIL=$((FAIL + 1))
  fi
}

check_json() {
  local filter="$1" description="$2"
  if jq -e "$filter" "$RESP_BODY" >/dev/null 2>&1; then
    printf 'PASS  %-55s %s\n' "$description" "$filter"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-55s expected %s\n' "$description" "$filter"
    echo "      body: $(cat "$RESP_BODY")"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> Testing $BASE_URL"
echo

echo "-- Health check"
request GET /health
check_code 200 "health endpoint"
check_json '.status == "ok" and .input_dir_readable == true' "health reports readable input dir"

echo
echo "-- Permitted file operation"
request GET /process --get --data-urlencode "file=sample.txt"
check_code 200 "process sample.txt"
check_json ".word_count == ${EXPECTED_WORDS}" "word count equals ${EXPECTED_WORDS}"
check_json '.file == "sample.txt" and .size_bytes > 0' "response identifies file and size"

echo
echo "-- Unauthorized path / filename rejection"
request GET /process --get --data-urlencode "file=../etc/passwd"
check_code 400 "traversal ../etc/passwd rejected"
check_json '.error.code == "invalid_filename"' "traversal error code"

request GET /process --get --data-urlencode "file=/etc/passwd"
check_code 400 "absolute path /etc/passwd rejected"
check_json '.error.code == "invalid_filename"' "absolute path error code"

request GET /process --get --data-urlencode "file=..%2F..%2Fetc%2Fpasswd"
check_code 400 "encoded traversal rejected"

request GET /process --get --data-urlencode "file=."
check_code 400 "dot filename rejected"

echo
echo "-- Graceful error handling"
request GET /process --get --data-urlencode "file=missing.txt"
check_code 404 "missing file returns 404"
check_json '.error.code == "file_not_found"' "missing file error code"

request GET /process
check_code 400 "missing file parameter returns 400"
check_json '.error.code == "missing_file_parameter"' "missing parameter error code"

request GET /does-not-exist
check_code 404 "unknown endpoint returns JSON 404"
check_json '.error.code == "not_found"' "unknown endpoint error code"

request POST /process
check_code 405 "POST /process rejected"

echo
echo "======================================"
echo "PASS: $PASS   FAIL: $FAIL"
echo "======================================"
[[ "$FAIL" -eq 0 ]]
