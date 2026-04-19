#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

[[ -f "${ENV_FILE}" ]] || {
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
}

set -o allexport
source "${ENV_FILE}"
set +o allexport

for key in NETBIRD_DOMAIN NETBIRD_MGMT_API_PORT NETBIRD_OWNER_EMAIL NETBIRD_OWNER_NAME NETBIRD_OWNER_PASSWORD; do
  value="${!key:-}"
  if [[ -z "${value}" || "${value}" == "change-me" ]]; then
    echo "Missing required variable ${key} in ${ENV_FILE}" >&2
    exit 1
  fi
done

instance_json=""
API_BASE=""

probe_api() {
  local base="$1"
  local api="${base%/}/api"
  local body=""
  for _ in $(seq 1 30); do
    if body="$(curl -ksSf "${api}/instance" 2>/dev/null)"; then
      API_BASE="${api}"
      instance_json="${body}"
      return 0
    fi
    sleep 2
  done
  return 1
}

if [[ -n "${NETBIRD_SETUP_BASE_URL:-}" ]]; then
  probe_api "${NETBIRD_SETUP_BASE_URL}" || {
    echo "NetBird management API is not reachable at ${NETBIRD_SETUP_BASE_URL%/}/api" >&2
    exit 1
  }
else
  probe_api "https://${NETBIRD_DOMAIN}" || \
  probe_api "https://${NETBIRD_DOMAIN}:${NETBIRD_MGMT_API_PORT}" || \
  probe_api "http://127.0.0.1:${NETBIRD_MGMT_API_PORT}" || \
  probe_api "http://${NETBIRD_DOMAIN}:${NETBIRD_MGMT_API_PORT}" || {
    echo "NetBird management API is not reachable over any known endpoint" >&2
    exit 1
  }
fi

setup_required="$(
  INSTANCE_JSON="${instance_json}" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["INSTANCE_JSON"])
print("true" if data.get("setup_required") else "false")
PY
)"

if [[ "${setup_required}" != "true" ]]; then
  echo "Instance setup already completed. Nothing to do."
  exit 0
fi

payload="$(
  NETBIRD_OWNER_EMAIL="${NETBIRD_OWNER_EMAIL}" \
  NETBIRD_OWNER_NAME="${NETBIRD_OWNER_NAME}" \
  NETBIRD_OWNER_PASSWORD="${NETBIRD_OWNER_PASSWORD}" \
  python3 - <<'PY'
import json
import os

print(json.dumps({
    "email": os.environ["NETBIRD_OWNER_EMAIL"],
    "name": os.environ["NETBIRD_OWNER_NAME"],
    "password": os.environ["NETBIRD_OWNER_PASSWORD"],
}))
PY
)"

curl -ksSf \
  -X POST "${API_BASE}/setup" \
  -H "Content-Type: application/json" \
  -d "${payload}" >/dev/null

echo "NetBird owner account bootstrapped for ${NETBIRD_OWNER_EMAIL}."
