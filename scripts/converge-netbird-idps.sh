#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config.yaml}"

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Must run as root"; exit 1; }
}

require_config() {
  [[ -f "${CONFIG_FILE}" ]] || { echo "Missing required config file: ${CONFIG_FILE}"; exit 1; }
}

yaml_get() {
  local expr="$1"
  python3 - "$CONFIG_FILE" "$expr" <<'PY'
import sys, yaml
path = sys.argv[1]
expr = sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f)

cur = data
for p in expr.split('.'):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        raise SystemExit(f"Missing config key: {expr}")

if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("")
else:
    print(cur)
PY
}

load_env_file() {
  [[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
  log "Loading environment variables from ${ENV_FILE}"
  set -o allexport
  source "${ENV_FILE}"
  set +o allexport
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_root
require_config

LOG_DIR="$(yaml_get system.log_dir)"
LOG_FILE="${LOG_DIR}/converge-netbird-idps.log"
NETBIRD_ENABLED="$(yaml_get netbird.enabled)"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "NetBird IdP converge aborted at line $LINENO."' ERR

[[ "${NETBIRD_ENABLED}" == "true" ]] || {
  log "NetBird is disabled in config.yaml. Nothing to do."
  exit 0
}

load_env_file

NETBIRD_GOOGLE_IDP_NAME="${NETBIRD_GOOGLE_IDP_NAME:-Google}"
NETBIRD_IDP_API_BASE_URL="${NETBIRD_IDP_API_BASE_URL:-http://127.0.0.1:${NETBIRD_MGMT_API_PORT:-33073}/api}"
NETBIRD_IDP_REDIRECT_HINT="${NETBIRD_IDP_REDIRECT_HINT:-https://${NETBIRD_DOMAIN:-netbird.example.invalid}/oauth2/callback}"
AUTHENTIK_NETBIRD_OIDC_ENABLED="${AUTHENTIK_NETBIRD_OIDC_ENABLED:-false}"
AUTHENTIK_NETBIRD_IDP_NAME="${AUTHENTIK_NETBIRD_IDP_NAME:-Authentik}"
AUTHENTIK_NETBIRD_APPLICATION_SLUG="${AUTHENTIK_NETBIRD_APPLICATION_SLUG:-netbird}"
AUTHENTIK_NETBIRD_ISSUER_URL="${AUTHENTIK_NETBIRD_ISSUER_URL:-https://${AUTHENTIK_DOMAIN:-auth.example.invalid}/application/o/${AUTHENTIK_NETBIRD_APPLICATION_SLUG}/}"
AUTHENTIK_NETBIRD_ISSUER_RETRY_ATTEMPTS="${AUTHENTIK_NETBIRD_ISSUER_RETRY_ATTEMPTS:-10}"
AUTHENTIK_NETBIRD_ISSUER_RETRY_DELAY_SECONDS="${AUTHENTIK_NETBIRD_ISSUER_RETRY_DELAY_SECONDS:-3}"
NETBIRD_USER_APPROVAL_REQUIRED="${NETBIRD_USER_APPROVAL_REQUIRED:-false}"

require_soft_var() {
  local key="$1"
  local value="${!key:-}"
  [[ -n "${value}" && "${value}" != "change-me" ]]
}

api_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url="${NETBIRD_IDP_API_BASE_URL%/}/${path#/}"
  local body_file
  local code
  body_file="$(mktemp)"

  if [[ -n "${data}" ]]; then
    code="$(
      curl -sS -o "${body_file}" -w '%{http_code}' \
        -X "${method}" \
        -H "Authorization: Token ${NETBIRD_API_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "${data}" \
        "${url}"
    )"
  else
    code="$(
      curl -sS -o "${body_file}" -w '%{http_code}' \
        -X "${method}" \
        -H "Authorization: Token ${NETBIRD_API_TOKEN}" \
        "${url}"
    )"
  fi

  if [[ "${code}" != 2* ]]; then
    printf 'HTTP %s\n' "${code}" >&2
    cat "${body_file}" >&2
    rm -f "${body_file}"
    return 1
  fi

  cat "${body_file}"
  rm -f "${body_file}"
}

upsert_provider() {
  local provider_type="$1"
  local provider_name="$2"
  local desired_payload="$3"
  local allow_single_type_fallback="$4"
  local redirect_base="$5"
  local providers_json matching_id result_json action provider_id

  if ! providers_json="$(api_request GET "identity-providers")"; then
    return 1
  fi

  matching_id="$(
    PROVIDERS_JSON="${providers_json}" PROVIDER_TYPE="${provider_type}" PROVIDER_NAME="${provider_name}" ALLOW_SINGLE_TYPE_FALLBACK="${allow_single_type_fallback}" python3 - <<'PY'
import json
import os
import sys

providers = json.loads(os.environ["PROVIDERS_JSON"])
provider_type = os.environ["PROVIDER_TYPE"]
provider_name = os.environ["PROVIDER_NAME"]
matching = [p for p in providers if p.get("type") == provider_type and p.get("name") == provider_name]
if len(matching) > 1:
    sys.exit("multiple exact identity providers exist already")
if matching:
    print(matching[0]["id"])
    raise SystemExit(0)

if os.environ.get("ALLOW_SINGLE_TYPE_FALLBACK", "").lower() in {"1", "true", "yes", "on"}:
    same_type = [p for p in providers if p.get("type") == provider_type]
    if len(same_type) > 1:
        sys.exit("multiple same-type identity providers exist already")
    if same_type:
        print(same_type[0]["id"])
PY
  )"

  if [[ -z "${matching_id}" ]]; then
    action="created"
    if ! result_json="$(api_request POST "identity-providers" "${desired_payload}")"; then
      return 1
    fi
  else
    action="updated"
    if ! result_json="$(api_request PUT "identity-providers/${matching_id}" "${desired_payload}")"; then
      return 1
    fi
  fi

  provider_id="$(
    RESULT_JSON="${result_json}" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["RESULT_JSON"])
print(data.get("id", ""))
PY
  )"

  [[ -n "${provider_id}" ]] || fail "NetBird API returned no provider id after ${action} ${provider_name}."

  log "${provider_name} identity provider ${action}: ${provider_id}"
  log "Redirect URI hint for upstream IdP configuration: ${redirect_base%/}/${provider_id}"
}

retry_upsert_provider() {
  local max_attempts="$1"
  local delay_seconds="$2"
  local provider_type="$3"
  local provider_name="$4"
  local desired_payload="$5"
  local allow_single_type_fallback="$6"
  local redirect_base="$7"
  local attempt=1

  while true; do
    if upsert_provider "${provider_type}" "${provider_name}" "${desired_payload}" "${allow_single_type_fallback}" "${redirect_base}"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      return 1
    fi

    warn "${provider_name} identity provider converge attempt ${attempt}/${max_attempts} failed. Retrying in ${delay_seconds}s."
    attempt=$((attempt + 1))
    sleep "${delay_seconds}"
  done
}

converge_account_settings() {
  local accounts_json account_id current_setting desired_payload updated_setting

  accounts_json="$(api_request GET "accounts")"
  account_id="$(
    ACCOUNTS_JSON="${accounts_json}" python3 - <<'PY'
import json
import os
import sys

accounts = json.loads(os.environ["ACCOUNTS_JSON"])
if len(accounts) != 1:
    sys.exit("expected exactly one NetBird account")
print(accounts[0]["id"])
PY
  )"

  current_setting="$(
    ACCOUNTS_JSON="${accounts_json}" python3 - <<'PY'
import json
import os

accounts = json.loads(os.environ["ACCOUNTS_JSON"])
current = bool(accounts[0].get("settings", {}).get("extra", {}).get("user_approval_required", False))
print("true" if current else "false")
PY
  )"

  desired_payload="$(
    ACCOUNTS_JSON="${accounts_json}" DESIRED_VALUE="${NETBIRD_USER_APPROVAL_REQUIRED}" python3 - <<'PY'
import json
import os

accounts = json.loads(os.environ["ACCOUNTS_JSON"])
account = accounts[0]
desired = os.environ["DESIRED_VALUE"].strip().lower() == "true"

settings = account.get("settings", {}) or {}
extra = settings.get("extra", {}) or {}
extra["user_approval_required"] = desired
settings["extra"] = extra

payload = {
    "settings": settings,
    "onboarding": account.get("onboarding", {}) or {},
}
print(json.dumps(payload, separators=(",", ":")))
PY
  )"

  api_request PUT "accounts/${account_id}" "${desired_payload}" >/dev/null
  accounts_json="$(api_request GET "accounts")"

  updated_setting="$(
    ACCOUNTS_JSON="${accounts_json}" python3 - <<'PY'
import json
import os

accounts = json.loads(os.environ["ACCOUNTS_JSON"])
current = bool(accounts[0].get("settings", {}).get("extra", {}).get("user_approval_required", False))
print("true" if current else "false")
PY
  )"

  if [[ "${updated_setting}" != "${NETBIRD_USER_APPROVAL_REQUIRED}" ]]; then
    fail "NetBird account user_approval_required remained ${updated_setting}; expected ${NETBIRD_USER_APPROVAL_REQUIRED}"
  fi

  if [[ "${current_setting}" == "${updated_setting}" ]]; then
    log "NetBird account setting already matches desired state: user_approval_required=${updated_setting}"
  else
    log "NetBird account setting updated: user_approval_required ${current_setting} -> ${updated_setting}"
  fi
}

main() {
  log "===== crooked-sentry NetBird IdP converge starting ====="
  require_command curl
  require_command jq
  require_command python3

  if ! require_soft_var NETBIRD_API_TOKEN; then
    warn "NETBIRD_API_TOKEN is not set. Skipping external IdP convergence."
    exit 0
  fi

  api_request GET "instance" >/dev/null
  log "NetBird management API is reachable via ${NETBIRD_IDP_API_BASE_URL}"
  converge_account_settings

  local converged_any="false"
  local desired_payload=""

  if require_soft_var GOOGLE_OAUTH_CLIENT_ID && require_soft_var GOOGLE_OAUTH_CLIENT_SECRET; then
    desired_payload="$(
      jq -nc \
        --arg type "google" \
        --arg name "${NETBIRD_GOOGLE_IDP_NAME}" \
        --arg client_id "${GOOGLE_OAUTH_CLIENT_ID}" \
        --arg client_secret "${GOOGLE_OAUTH_CLIENT_SECRET}" \
        '{type:$type,name:$name,client_id:$client_id,client_secret:$client_secret}'
    )"
    upsert_provider "google" "${NETBIRD_GOOGLE_IDP_NAME}" "${desired_payload}" "true" "${NETBIRD_IDP_REDIRECT_HINT}"
    warn "Google Cloud must still allow the exact NetBird redirect URI. Open Settings -> Identity Providers -> ${NETBIRD_GOOGLE_IDP_NAME} in the dashboard and copy the Redirect URL into Google Cloud if needed."
    converged_any="true"
  else
    warn "Google OAuth client settings are incomplete. Skipping Google IdP convergence."
  fi

  if [[ "${AUTHENTIK_NETBIRD_OIDC_ENABLED}" == "true" ]]; then
    if ! require_soft_var AUTHENTIK_DOMAIN || ! require_soft_var AUTHENTIK_NETBIRD_CLIENT_ID || ! require_soft_var AUTHENTIK_NETBIRD_CLIENT_SECRET; then
      fail "AUTHENTIK_NETBIRD_OIDC_ENABLED=true requires AUTHENTIK_DOMAIN, AUTHENTIK_NETBIRD_CLIENT_ID, and AUTHENTIK_NETBIRD_CLIENT_SECRET."
    fi

    desired_payload="$(
      jq -nc \
        --arg type "oidc" \
        --arg name "${AUTHENTIK_NETBIRD_IDP_NAME}" \
        --arg issuer "${AUTHENTIK_NETBIRD_ISSUER_URL}" \
        --arg client_id "${AUTHENTIK_NETBIRD_CLIENT_ID}" \
        --arg client_secret "${AUTHENTIK_NETBIRD_CLIENT_SECRET}" \
        '{type:$type,name:$name,issuer:$issuer,client_id:$client_id,client_secret:$client_secret}'
    )"
    retry_upsert_provider \
      "${AUTHENTIK_NETBIRD_ISSUER_RETRY_ATTEMPTS}" \
      "${AUTHENTIK_NETBIRD_ISSUER_RETRY_DELAY_SECONDS}" \
      "oidc" \
      "${AUTHENTIK_NETBIRD_IDP_NAME}" \
      "${desired_payload}" \
      "false" \
      "${NETBIRD_IDP_REDIRECT_HINT}"
    converged_any="true"
  fi

  if [[ "${converged_any}" != "true" ]]; then
    warn "No identity providers were converged."
  fi

  log "===== crooked-sentry NetBird IdP converge completed successfully ====="
}

main "$@"
