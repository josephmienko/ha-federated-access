#!/usr/bin/env bash
set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config.yaml}"
CONFIG_LIB="${SCRIPT_DIR}/lib/config.sh"
[[ -f "${CONFIG_LIB}" ]] || { echo "Missing config library: ${CONFIG_LIB}"; exit 1; }
source "${CONFIG_LIB}"

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
  [[ -f "${ENV_FILE}" ]] || { echo "Missing env file: ${ENV_FILE}"; exit 1; }
  set -o allexport
  source "${ENV_FILE}"
  set +o allexport
}

require_root
require_config
load_env_file

LOG_DIR="$(yaml_get system.log_dir)"
LOG_FILE="${LOG_DIR}/verify-netbird.log"
NETBIRD_ENABLED="$(yaml_get netbird.enabled)"
NETBIRD_STACK_ROOT="$(yaml_get netbird.stack_root)"
NETBIRD_SERVICE_NAME="$(yaml_get netbird.compose_service_name)"
NETBIRD_COMPOSE_FILE="$(config_first "${NETBIRD_STACK_ROOT}/docker-compose.yaml" netbird.compose_file)"
NETBIRD_COMPOSE_ENV_FILE="$(config_first "${NETBIRD_STACK_ROOT}/.env" netbird.compose_env_file)"
NETBIRD_REVERSE_PROXY_ENABLED="${NETBIRD_REVERSE_PROXY_ENABLED:-false}"
NETBIRD_HA_PROXY_ENABLED="${NETBIRD_HA_PROXY_ENABLED:-false}"
NETBIRD_HA_PROXY_SUBDOMAIN="${NETBIRD_HA_PROXY_SUBDOMAIN:-ha}"
NETBIRD_PI_PEER_NAME="${NETBIRD_PI_PEER_NAME:-$(hostname -s)-pi}"
RUNTIME_PEER_ENV="${NETBIRD_STACK_ROOT}/generated/peer.env"
HA_PROXY_DOMAIN="${NETBIRD_HA_PROXY_SUBDOMAIN}.${NETBIRD_PROXY_DOMAIN:-proxy.invalid}"
LANDING_DOMAIN="${LANDING_DOMAIN:-${TF_VAR_cloudflare_zone_name:-${NETBIRD_MGMT_DNS_DOMAIN:-}}}"
LANDING_REDIRECT_URL="${LANDING_REDIRECT_URL:-https://${HA_PROXY_DOMAIN}/auth/oidc/redirect}"
AUTHENTIK_ENABLED="${AUTHENTIK_ENABLED:-false}"
AUTHENTIK_DOMAIN="${AUTHENTIK_DOMAIN:-}"
AUTHENTIK_NETBIRD_OIDC_ENABLED="${AUTHENTIK_NETBIRD_OIDC_ENABLED:-false}"
AUTHENTIK_NETBIRD_IDP_NAME="${AUTHENTIK_NETBIRD_IDP_NAME:-Authentik}"
AUTHENTIK_NETBIRD_APPLICATION_SLUG="${AUTHENTIK_NETBIRD_APPLICATION_SLUG:-netbird}"
AUTHENTIK_NETBIRD_ISSUER_URL="${AUTHENTIK_NETBIRD_ISSUER_URL:-https://${AUTHENTIK_DOMAIN}/application/o/${AUTHENTIK_NETBIRD_APPLICATION_SLUG}/}"
AUTHENTIK_OIDC_SIGNING_KEY_NAME="${AUTHENTIK_OIDC_SIGNING_KEY_NAME:-authentik Self-signed Certificate}"
NETBIRD_USER_APPROVAL_REQUIRED="${NETBIRD_USER_APPROVAL_REQUIRED:-false}"
HA_AUTH_OIDC_ENABLED="${HA_AUTH_OIDC_ENABLED:-false}"
HA_OIDC_COMPONENT_VERSION="${HA_OIDC_COMPONENT_VERSION:-v0.6.5-alpha}"
HA_CONFIG_DIR="$(config_first "" homeassistant.config_dir stage2.homeassistant.config_dir)"
HA_PORT="$(config_first "" homeassistant.port stage2.homeassistant.port)"
[[ -n "${HA_CONFIG_DIR}" ]] || { echo "Missing config key: homeassistant.config_dir"; exit 1; }
[[ -n "${HA_PORT}" ]] || { echo "Missing config key: homeassistant.port"; exit 1; }
HA_OIDC_COMPONENT_DIR="${HA_CONFIG_DIR}/custom_components/auth_oidc"
HA_OIDC_COMPONENT_MARKER_PREFIX="${HA_OIDC_COMPONENT_MARKER_PREFIX:-ha-federated-access}"
HA_OIDC_COMPONENT_VERSION_FILE="${HA_OIDC_COMPONENT_DIR}/.${HA_OIDC_COMPONENT_MARKER_PREFIX}-version"
if [[ "${HA_OIDC_COMPONENT_MARKER_PREFIX}" == "ha-federated-access" && ! -f "${HA_OIDC_COMPONENT_VERSION_FILE}" && -f "${HA_OIDC_COMPONENT_DIR}/.crooked-sentry-version" ]]; then
  HA_OIDC_COMPONENT_VERSION_FILE="${HA_OIDC_COMPONENT_DIR}/.crooked-sentry-version"
fi
HA_OIDC_APPLICATION_SLUG="${HA_OIDC_APPLICATION_SLUG:-home-assistant}"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "PASS: $*"
}

record_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  log "WARN: $*"
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "FAIL: $*"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

have_real_value() {
  local value="$1"
  [[ -n "${value}" && "${value}" != "change-me" ]]
}

require_base_commands() {
  local cmds=(python3 systemctl docker curl jq ss awk grep)
  local missing=()
  local c
  for c in "${cmds[@]}"; do
    have_command "${c}" || missing+=("${c}")
  done
  if (( ${#missing[@]} > 0 )); then
    log "ERROR: Missing required commands: ${missing[*]}"
    exit 1
  fi
}

check_service_state() {
  local state=""
  state="$(systemctl is-active "${NETBIRD_SERVICE_NAME}" 2>/dev/null || true)"
  case "${state}" in
    active)
      record_pass "NetBird service is active: ${NETBIRD_SERVICE_NAME}"
      ;;
    failed)
      record_fail "NetBird service is failed: ${NETBIRD_SERVICE_NAME}"
      ;;
    *)
      record_fail "NetBird service state is ${state:-unknown}: ${NETBIRD_SERVICE_NAME}"
      ;;
  esac
}

check_runtime_files() {
  local required=(
    "${NETBIRD_COMPOSE_FILE}" \
    "${NETBIRD_COMPOSE_ENV_FILE}" \
    "${NETBIRD_STACK_ROOT}/generated/management.json" \
    "${NETBIRD_STACK_ROOT}/generated/turnserver.conf"
  )
  local path=""

  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    required+=("${NETBIRD_STACK_ROOT}/generated/proxy.env")
  fi
  if [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]]; then
    required+=("${RUNTIME_PEER_ENV}")
  fi

  for path in "${required[@]}"; do
    if [[ -f "${path}" ]]; then
      record_pass "Runtime file exists: ${path}"
    else
      record_fail "Missing runtime file: ${path}"
    fi
  done
}

local_dashboard_https_ready() {
  curl -kIsS --max-time 10 \
    --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1" \
    "https://${NETBIRD_DOMAIN}/" >/dev/null 2>&1
}

local_dashboard_management_https_ready() {
  curl -kfsS --max-time 10 \
    --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1" \
    -o /dev/null "https://${NETBIRD_DOMAIN}/api/instance" >/dev/null 2>&1
}

local_authentik_https_status() {
  curl -ksS -o /dev/null -w '%{http_code}' \
    --resolve "${AUTHENTIK_DOMAIN}:443:127.0.0.1" \
    "https://${AUTHENTIK_DOMAIN}/" || true
}

local_landing_https_headers() {
  curl -kIsS --max-time 10 \
    --resolve "${LANDING_DOMAIN}:443:127.0.0.1" \
    "https://${LANDING_DOMAIN}/" 2>/dev/null || true
}

check_compose_services() {
  local expected=(traefik dashboard signal relay management coturn)
  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    expected+=(proxy)
  fi
  local running=()
  local service=""
  mapfile -t running < <(docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" ps --services --status running 2>/dev/null || true)

  for service in "${expected[@]}"; do
    if printf '%s\n' "${running[@]}" | grep -qx "${service}"; then
      record_pass "Compose service is running: ${service}"
    else
      record_fail "Compose service is not running: ${service}"
    fi
  done

}

check_https_endpoint() {
  local name="$1"
  local url="$2"
  if curl -kfsS --max-time 10 -o /dev/null "${url}" >/dev/null 2>&1; then
    record_pass "${name} is reachable: ${url}"
  else
    record_fail "${name} is not reachable: ${url}"
  fi
}

check_http_endpoint() {
  local name="$1"
  local url="$2"
  if curl -fsS --max-time 10 -o /dev/null "${url}" >/dev/null 2>&1; then
    record_pass "${name} is reachable: ${url}"
  else
    record_fail "${name} is not reachable: ${url}"
  fi
}

check_management_instance() {
  local instance_json=""
  instance_json="$(curl -fsS --max-time 10 "http://127.0.0.1:${NETBIRD_MGMT_API_PORT}/api/instance" 2>/dev/null || true)"
  if [[ -z "${instance_json}" ]]; then
    record_fail "NetBird management instance endpoint is not reachable"
    return
  fi

  record_pass "NetBird management instance endpoint returned JSON"

  local setup_required=""
  setup_required="$(INSTANCE_JSON="${instance_json}" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["INSTANCE_JSON"])
print("true" if data.get("setup_required") else "false")
PY
)"

  if [[ "${setup_required}" == "false" ]]; then
    record_pass "NetBird owner bootstrap completed"
  else
    record_fail "NetBird still reports setup_required=true"
  fi
}

check_tls_readiness() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if local_dashboard_https_ready && local_dashboard_management_https_ready; then
      record_pass "NetBird public HTTPS is reachable via ${NETBIRD_DOMAIN}"
      record_pass "NetBird management API is reachable via https://${NETBIRD_DOMAIN}/api"
      return
    fi
    sleep 2
  done
  record_warn "NetBird public HTTPS is not reachable yet via ${NETBIRD_DOMAIN}. Public browser onboarding will not work until DNS and 80/tcp + 443/tcp forwarding are correct."
}

check_tcp_listener() {
  local label="$1"
  local port="$2"
  if ss -ltnH 2>/dev/null | awk -v port="${port}" '
      {
        n = split($4, parts, ":")
        if (parts[n] == port) found = 1
      }
      END { exit(found ? 0 : 1) }
    '; then
    record_pass "${label} is listening on TCP port ${port}"
  else
    record_fail "${label} is not listening on TCP port ${port}"
  fi
}

check_udp_listener() {
  local label="$1"
  local port="$2"
  if ss -lunH 2>/dev/null | awk -v port="${port}" '
      {
        n = split($4, parts, ":")
        if (parts[n] == port) found = 1
      }
      END { exit(found ? 0 : 1) }
    '; then
    record_pass "${label} is listening on UDP port ${port}"
  else
    record_fail "${label} is not listening on UDP port ${port}"
  fi
}

check_dns_alignment() {
  local expected_public_ip="${TF_VAR_server_public_ip:-${NETBIRD_TURN_EXTERNAL_IP}}"
  local resolved_public_ip=""
  resolved_public_ip="$(getent ahostsv4 "${NETBIRD_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"

  if [[ -z "${resolved_public_ip}" ]]; then
    record_warn "Could not resolve ${NETBIRD_DOMAIN} from the Pi"
    return
  fi

  if [[ "${resolved_public_ip}" == "${expected_public_ip}" ]]; then
    record_pass "DNS resolves ${NETBIRD_DOMAIN} to the expected public IP ${expected_public_ip}"
  else
    record_warn "DNS resolves ${NETBIRD_DOMAIN} to ${resolved_public_ip}, expected ${expected_public_ip}"
  fi

  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    local proxy_public_ip=""
    local wildcard_probe="ha.${NETBIRD_PROXY_DOMAIN}"
    local wildcard_public_ip=""

    proxy_public_ip="$(getent ahostsv4 "${NETBIRD_PROXY_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${proxy_public_ip}" ]]; then
      record_warn "Could not resolve reverse proxy base domain ${NETBIRD_PROXY_DOMAIN} from the Pi"
    elif [[ "${proxy_public_ip}" == "${expected_public_ip}" ]]; then
      record_pass "DNS resolves ${NETBIRD_PROXY_DOMAIN} to the expected public IP ${expected_public_ip}"
    else
      record_warn "DNS resolves ${NETBIRD_PROXY_DOMAIN} to ${proxy_public_ip}, expected ${expected_public_ip}"
    fi

    wildcard_public_ip="$(getent ahostsv4 "${wildcard_probe}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${wildcard_public_ip}" ]]; then
      record_warn "Wildcard reverse proxy DNS does not resolve ${wildcard_probe}"
    elif [[ "${wildcard_public_ip}" == "${expected_public_ip}" ]]; then
      record_pass "Wildcard reverse proxy DNS resolves via ${wildcard_probe} to the expected public IP ${expected_public_ip}"
    else
      record_warn "Wildcard reverse proxy DNS resolves ${wildcard_probe} to ${wildcard_public_ip}, expected ${expected_public_ip}"
    fi
  fi

  if [[ -n "${LANDING_DOMAIN}" ]]; then
    local landing_public_ip=""
    landing_public_ip="$(getent ahostsv4 "${LANDING_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${landing_public_ip}" ]]; then
      record_warn "Could not resolve landing domain ${LANDING_DOMAIN} from the Pi"
    elif [[ "${landing_public_ip}" == "${expected_public_ip}" ]]; then
      record_pass "DNS resolves ${LANDING_DOMAIN} to the expected public IP ${expected_public_ip}"
    else
      record_warn "DNS resolves ${LANDING_DOMAIN} to ${landing_public_ip}, expected ${expected_public_ip}"
    fi
  fi

  if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
    local authentik_public_ip=""
    authentik_public_ip="$(getent ahostsv4 "${AUTHENTIK_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${authentik_public_ip}" ]]; then
      record_warn "Could not resolve Authentik domain ${AUTHENTIK_DOMAIN} from the Pi"
    elif [[ "${authentik_public_ip}" == "${expected_public_ip}" ]]; then
      record_pass "DNS resolves ${AUTHENTIK_DOMAIN} to the expected public IP ${expected_public_ip}"
    else
      record_warn "DNS resolves ${AUTHENTIK_DOMAIN} to ${authentik_public_ip}, expected ${expected_public_ip}"
    fi
  fi
}

check_landing_redirect() {
  [[ -n "${LANDING_DOMAIN}" ]] || return 0
  local headers=""
  local location=""
  headers="$(local_landing_https_headers)"
  if [[ -z "${headers}" ]]; then
    record_warn "Landing redirect is not reachable yet via https://${LANDING_DOMAIN}/"
    return 0
  fi

  location="$(awk -F': ' 'tolower($1)=="location" {print $2}' <<<"${headers}" | tr -d '\r' | tail -n1)"
  if [[ "${location}" == "${LANDING_REDIRECT_URL}" ]]; then
    record_pass "Landing redirect points ${LANDING_DOMAIN} to ${LANDING_REDIRECT_URL}"
  else
    record_warn "Landing redirect did not return the expected target ${LANDING_REDIRECT_URL}"
  fi
}

api_request() {
  local method="$1"
  local path="$2"
  local url="http://127.0.0.1:${NETBIRD_MGMT_API_PORT}/api/${path#/}"
  curl -fsS -X "${method}" \
    -H "Authorization: Token ${NETBIRD_API_TOKEN}" \
    "${url}"
}

check_google_idp() {
  local idp_name="${NETBIRD_GOOGLE_IDP_NAME:-Google}"

  if ! have_real_value "${GOOGLE_OAUTH_CLIENT_ID:-}" || ! have_real_value "${GOOGLE_OAUTH_CLIENT_SECRET:-}"; then
    record_warn "Google OAuth client credentials are not configured in .env; skipping Google IdP checks."
    return
  fi

  record_pass "Google OAuth client credentials are present in .env"

  if ! have_real_value "${NETBIRD_API_TOKEN:-}"; then
    record_warn "NETBIRD_API_TOKEN is not configured in .env; skipping Google IdP API verification."
    return
  fi

  local providers_json=""
  if ! providers_json="$(api_request GET "identity-providers" 2>/dev/null)"; then
    record_fail "NetBird identity provider API is not reachable with the configured NETBIRD_API_TOKEN"
    return
  fi

  local status=""
  status="$(
    PROVIDERS_JSON="${providers_json}" EXPECTED_NAME="${idp_name}" EXPECTED_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID}" python3 - <<'PY'
import json
import os

providers = json.loads(os.environ["PROVIDERS_JSON"])
name = os.environ["EXPECTED_NAME"]
client_id = os.environ["EXPECTED_CLIENT_ID"]

google = [p for p in providers if p.get("type") == "google"]
if not google:
    print("missing")
    raise SystemExit(0)
if len(google) > 1:
    print("multiple")
    raise SystemExit(0)
provider = google[0]
if provider.get("name") != name:
    print("name_mismatch")
    raise SystemExit(0)
if provider.get("client_id") != client_id:
    print("client_id_mismatch")
    raise SystemExit(0)
print("ok")
PY
  )"

  case "${status}" in
    ok)
      record_pass "Google identity provider is configured in NetBird"
      ;;
    missing)
      record_fail "Google identity provider is not configured in NetBird"
      ;;
    multiple)
      record_fail "Multiple Google identity providers are configured in NetBird"
      ;;
    name_mismatch)
      record_fail "Google identity provider exists but does not match NETBIRD_GOOGLE_IDP_NAME=${idp_name}"
      ;;
    client_id_mismatch)
      record_fail "Google identity provider exists but does not match GOOGLE_OAUTH_CLIENT_ID"
      ;;
    *)
      record_fail "Google identity provider verification returned unexpected status: ${status}"
      ;;
  esac

  record_warn "Google does not emit a groups claim for automatic custom NetBird group assignment; use manual assignment or front Google with Authentik/Keycloak if you need auto-group mapping."
}

check_authentik_services() {
  [[ "${AUTHENTIK_ENABLED}" == "true" ]] || return 0

  local expected=(authentik-postgresql authentik-redis authentik-server authentik-worker)
  local running=()
  local service=""

  mapfile -t running < <(docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" --profile authentik ps --services --status running 2>/dev/null || true)
  for service in "${expected[@]}"; do
    if printf '%s\n' "${running[@]}" | grep -qx "${service}"; then
      record_pass "Authentik compose service is running: ${service}"
    else
      record_fail "Authentik compose service is not running: ${service}"
    fi
  done

  local authentik_status=""
  authentik_status="$(local_authentik_https_status)"
  case "${authentik_status}" in
    200|302|303|307|308|401|403)
      record_pass "Authentik HTTPS is reachable via ${AUTHENTIK_DOMAIN} (HTTP ${authentik_status})"
      ;;
    *)
      record_warn "Authentik HTTPS is not reachable yet via ${AUTHENTIK_DOMAIN} (HTTP ${authentik_status:-none})"
      ;;
  esac
}

check_authentik_oidc_provider_signing_keys() {
  [[ "${AUTHENTIK_ENABLED}" == "true" ]] || return 0

  local provider_slugs=()
  if [[ "${AUTHENTIK_NETBIRD_OIDC_ENABLED}" == "true" ]]; then
    provider_slugs+=("${AUTHENTIK_NETBIRD_APPLICATION_SLUG}")
  fi
  if [[ "${HA_AUTH_OIDC_ENABLED}" == "true" ]]; then
    provider_slugs+=("${HA_OIDC_APPLICATION_SLUG}")
  fi

  (( ${#provider_slugs[@]} > 0 )) || return 0

  local python_script output status_line status
  python_script="$(mktemp)"
  cat > "${python_script}" <<'PY'
import os

from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import OAuth2Provider

key_name = os.environ["AUTHENTIK_OIDC_SIGNING_KEY_NAME"].strip()
provider_slugs = [
    slug.strip()
    for slug in os.environ.get("AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS", "").split(",")
    if slug.strip()
]

try:
    cert = CertificateKeyPair.objects.get(name=key_name)
except CertificateKeyPair.DoesNotExist:
    available = ", ".join(CertificateKeyPair.objects.order_by("name").values_list("name", flat=True))
    print(f"AUTHENTIK_SIGNING_KEY_CHECK missing_key available={available}")
    raise SystemExit(0)

providers = list(
    OAuth2Provider.objects.select_related("application")
    .filter(application__slug__in=provider_slugs)
    .order_by("application__slug")
)
found = {
    provider.application.slug
    for provider in providers
    if getattr(provider, "application", None) is not None
}
missing = [slug for slug in provider_slugs if slug not in found]
if missing:
    print(f"AUTHENTIK_SIGNING_KEY_CHECK missing_provider slugs={','.join(missing)}")
    raise SystemExit(0)

mismatched = []
for provider in providers:
    current = getattr(provider.signing_key, "name", "") if provider.signing_key is not None else ""
    if provider.signing_key_id != cert.pk:
        mismatched.append(f"{provider.application.slug}:{current or 'unset'}")

if mismatched:
    print(f"AUTHENTIK_SIGNING_KEY_CHECK mismatch providers={','.join(mismatched)}")
else:
    print(f"AUTHENTIK_SIGNING_KEY_CHECK ok key_name={key_name}")
PY

  output="$(
    docker compose \
      --env-file "${NETBIRD_COMPOSE_ENV_FILE}" \
      -f "${NETBIRD_COMPOSE_FILE}" \
      --profile authentik \
      exec \
      -T \
      -e AUTHENTIK_OIDC_SIGNING_KEY_NAME="${AUTHENTIK_OIDC_SIGNING_KEY_NAME}" \
      -e AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS="$(IFS=,; printf '%s' "${provider_slugs[*]}")" \
      authentik-server \
      ak shell < "${python_script}" 2>/dev/null || true
  )"
  rm -f "${python_script}"

  status_line="$(printf '%s\n' "${output}" | awk '/AUTHENTIK_SIGNING_KEY_CHECK/ {line=$0} END {print line}')"
  if [[ -z "${status_line}" ]]; then
    record_fail "Could not verify Authentik OAuth2 provider signing keys"
    return
  fi

  status="$(printf '%s\n' "${status_line}" | awk '{print $2}')"
  case "${status}" in
    ok)
      record_pass "Authentik OAuth2 providers use signing key ${AUTHENTIK_OIDC_SIGNING_KEY_NAME}"
      ;;
    missing_key)
      record_fail "Authentik signing key ${AUTHENTIK_OIDC_SIGNING_KEY_NAME} does not exist"
      ;;
    missing_provider)
      record_fail "Expected Authentik OAuth2 providers are missing (${status_line#*slugs=})"
      ;;
    mismatch)
      record_fail "Authentik OAuth2 providers are not using signing key ${AUTHENTIK_OIDC_SIGNING_KEY_NAME} (${status_line#*providers=})"
      ;;
    *)
      record_fail "Authentik signing-key verification returned unexpected status: ${status_line}"
      ;;
  esac
}

check_netbird_account_settings() {
  if ! have_real_value "${NETBIRD_API_TOKEN:-}"; then
    record_warn "NETBIRD_API_TOKEN is not configured in .env; skipping NetBird account-settings verification."
    return
  fi

  local accounts_json current_setting
  if ! accounts_json="$(api_request GET "accounts" 2>/dev/null)"; then
    record_fail "Could not retrieve NetBird accounts"
    return
  fi

  current_setting="$(
    printf '%s' "${accounts_json}" | jq -r '
      if length == 1 then
        (.[0].settings.extra.user_approval_required // false)
      else
        empty
      end
      | if . then "true" else "false" end
    ' 2>/dev/null || true
  )"

  if [[ -z "${current_setting}" ]]; then
    record_fail "Could not determine NetBird account user_approval_required setting"
    return
  fi

  if [[ "${current_setting}" == "${NETBIRD_USER_APPROVAL_REQUIRED}" ]]; then
    record_pass "NetBird account user_approval_required matches ${NETBIRD_USER_APPROVAL_REQUIRED}"
  else
    record_fail "NetBird account user_approval_required is ${current_setting}; expected ${NETBIRD_USER_APPROVAL_REQUIRED}"
  fi
}

check_authentik_netbird_oidc() {
  [[ "${AUTHENTIK_NETBIRD_OIDC_ENABLED}" == "true" ]] || return 0

  if ! have_real_value "${NETBIRD_API_TOKEN:-}"; then
    record_warn "NETBIRD_API_TOKEN is not configured in .env; skipping Authentik OIDC provider verification."
    return
  fi

  local providers_json=""
  if ! providers_json="$(api_request GET "identity-providers" 2>/dev/null)"; then
    record_fail "NetBird identity provider API is not reachable with the configured NETBIRD_API_TOKEN"
    return
  fi

  local status=""
  status="$(
    PROVIDERS_JSON="${providers_json}" EXPECTED_NAME="${AUTHENTIK_NETBIRD_IDP_NAME}" EXPECTED_ISSUER="${AUTHENTIK_NETBIRD_ISSUER_URL}" python3 - <<'PY'
import json
import os

providers = json.loads(os.environ["PROVIDERS_JSON"])
name = os.environ["EXPECTED_NAME"]
issuer = os.environ["EXPECTED_ISSUER"]
matching = [p for p in providers if p.get("type") == "oidc" and p.get("name") == name]
if len(matching) == 0:
    print("missing")
elif len(matching) > 1:
    print("multiple")
elif matching[0].get("issuer") != issuer:
    print("issuer_mismatch")
else:
    print("ok")
PY
  )"

  case "${status}" in
    ok)
      record_pass "Authentik generic OIDC provider is configured in NetBird"
      ;;
    missing)
      record_fail "Authentik generic OIDC provider is not configured in NetBird"
      ;;
    multiple)
      record_fail "Multiple Authentik generic OIDC providers are configured in NetBird"
      ;;
    issuer_mismatch)
      record_fail "Authentik OIDC provider exists in NetBird but the issuer URL does not match ${AUTHENTIK_NETBIRD_ISSUER_URL}"
      ;;
    *)
      record_fail "Authentik OIDC provider verification returned unexpected status: ${status}"
      ;;
  esac
}

check_google_inputs() {
  check_google_idp
}

check_homeassistant_oidc() {
  [[ "${HA_AUTH_OIDC_ENABLED}" == "true" ]] || return 0

  if [[ -d "${HA_OIDC_COMPONENT_DIR}" ]]; then
    record_pass "Home Assistant OIDC custom component is installed at ${HA_OIDC_COMPONENT_DIR}"
  else
    record_fail "Home Assistant OIDC custom component is missing at ${HA_OIDC_COMPONENT_DIR}"
  fi

  if [[ -f "${HA_OIDC_COMPONENT_VERSION_FILE}" ]]; then
    local installed_version=""
    installed_version="$(tr -d '\r\n' < "${HA_OIDC_COMPONENT_VERSION_FILE}")"
    if [[ "${installed_version}" == "${HA_OIDC_COMPONENT_VERSION}" ]]; then
      record_pass "Home Assistant OIDC component version marker matches ${HA_OIDC_COMPONENT_VERSION}"
    else
      record_warn "Home Assistant OIDC component marker is ${installed_version:-unset}, expected ${HA_OIDC_COMPONENT_VERSION}"
    fi
  else
    record_warn "Home Assistant OIDC component version marker is missing"
  fi

  local oidc_welcome_status=""
  oidc_welcome_status="$(curl -ksS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HA_PORT}/auth/oidc/welcome" || true)"
  case "${oidc_welcome_status}" in
    200|302|303|307|308)
      record_pass "Home Assistant OIDC welcome route is reachable locally (HTTP ${oidc_welcome_status})"
      ;;
    *)
      record_fail "Home Assistant OIDC welcome route is not reachable locally (HTTP ${oidc_welcome_status:-none})"
      ;;
  esac

  if have_real_value "${AUTHENTIK_DOMAIN:-}"; then
    local oidc_discovery_url="https://${AUTHENTIK_DOMAIN}/application/o/${HA_OIDC_APPLICATION_SLUG}/.well-known/openid-configuration"
    local oidc_discovery_probe=""
    oidc_discovery_probe="$(
      docker exec homeassistant sh -lc 'python3 - "$1" <<'"'"'PY'"'"'
import sys
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=10) as response:
        print(response.status)
except Exception:
    print("error")
PY' -- "${oidc_discovery_url}" 2>/dev/null || true
    )"

    if [[ "${oidc_discovery_probe}" == "200" ]]; then
      record_pass "Home Assistant container can reach the Authentik OIDC discovery document"
    else
      record_fail "Home Assistant container cannot reach the Authentik OIDC discovery document (${oidc_discovery_url})"
    fi
  fi
}

check_browser_access() {
  [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]] || return 0

  local peer_running=""
  peer_running="$(docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" --profile browser-access ps --services --status running 2>/dev/null | grep -x 'peer' || true)"
  if [[ "${peer_running}" == "peer" ]]; then
    record_pass "NetBird peer container is running for browser access"
  else
    record_fail "NetBird peer container is not running for browser access"
  fi

  if have_real_value "${NETBIRD_API_TOKEN:-}"; then
    local peers_json=""
    local services_json=""

    if peers_json="$(api_request GET "peers" 2>/dev/null)"; then
      local peer_status=""
      peer_status="$(
        PEERS_JSON="${peers_json}" PEER_NAME="${NETBIRD_PI_PEER_NAME}" python3 - <<'PY'
import json
import os

peers = json.loads(os.environ["PEERS_JSON"])
peer_name = os.environ["PEER_NAME"].lower()
matches = []

for peer in peers:
    candidates = []
    for key in ("name", "hostname", "dns_label", "fqdn"):
        value = peer.get(key)
        if isinstance(value, str) and value:
            candidates.append(value.lower())
            candidates.append(value.lower().split(".")[0])
    if peer_name in candidates:
        matches.append(peer)

if not matches and len(peers) == 1:
    matches = peers

print("ok" if len(matches) == 1 else "missing")
PY
      )"
      if [[ "${peer_status}" == "ok" ]]; then
        record_pass "NetBird API shows a Pi peer for browser access"
      else
        record_fail "NetBird API does not show the expected Pi peer for browser access"
      fi
    else
      record_warn "NetBird peer API is not reachable with the configured NETBIRD_API_TOKEN; skipping Pi peer verification."
    fi

    if services_json="$(api_request GET "reverse-proxies/services" 2>/dev/null)"; then
      local service_status=""
      service_status="$(
        SERVICES_JSON="${services_json}" SERVICE_DOMAIN="${HA_PROXY_DOMAIN}" python3 - <<'PY'
import json
import os

services = json.loads(os.environ["SERVICES_JSON"])
domain = os.environ["SERVICE_DOMAIN"]
matching = [svc for svc in services if svc.get("domain") == domain]
if len(matching) == 1:
    print("ok")
elif len(matching) == 0:
    print("missing")
else:
    print("multiple")
PY
      )"
      case "${service_status}" in
        ok)
          record_pass "NetBird reverse-proxy service exists for ${HA_PROXY_DOMAIN}"
          ;;
        missing)
          record_fail "NetBird reverse-proxy service is missing for ${HA_PROXY_DOMAIN}"
          ;;
        multiple)
          record_fail "Multiple NetBird reverse-proxy services exist for ${HA_PROXY_DOMAIN}"
          ;;
      esac
    else
      record_warn "NetBird reverse-proxy API is not reachable with the configured NETBIRD_API_TOKEN; skipping service verification."
    fi
  else
    record_warn "NETBIRD_API_TOKEN is not configured in .env; skipping browser-access API verification."
  fi

  local ha_proxy_status=""
  ha_proxy_status="$(
    curl -ksS -o /dev/null -w '%{http_code}' \
      --resolve "${HA_PROXY_DOMAIN}:443:127.0.0.1" \
      "https://${HA_PROXY_DOMAIN}/" || true
  )"
  case "${ha_proxy_status}" in
    200|302|303|307|308|401|403)
      record_pass "Home Assistant browser-access URL is reachable via ${HA_PROXY_DOMAIN} (HTTP ${ha_proxy_status})"
      ;;
    *)
      record_fail "Home Assistant browser-access URL is not reachable via ${HA_PROXY_DOMAIN} (HTTP ${ha_proxy_status:-none})"
      ;;
  esac
}

main() {
  require_base_commands
  log "===== ha-federated-access NetBird verification starting ====="

  if [[ "${NETBIRD_ENABLED}" != "true" ]]; then
    record_warn "NetBird is disabled in config.yaml; skipping checks."
  else
    check_service_state
    check_runtime_files
    check_compose_services
    check_authentik_services
    check_authentik_oidc_provider_signing_keys
    check_netbird_account_settings
    check_http_endpoint "NetBird HTTP entrypoint" "http://127.0.0.1/"
    check_management_instance
    check_tcp_listener "NetBird Traefik HTTP" 80
    check_tcp_listener "NetBird Traefik HTTPS" 443
    check_tcp_listener "NetBird management" "${NETBIRD_MGMT_API_PORT}"
    check_tcp_listener "NetBird TURN" 3478
    check_udp_listener "NetBird TURN" 3478
    check_tls_readiness
    check_dns_alignment
    check_landing_redirect
    check_google_inputs
    check_authentik_netbird_oidc
    check_browser_access
    check_homeassistant_oidc
  fi

  log "===== ha-federated-access NetBird verification summary ====="
  log "Passed checks: ${PASS_COUNT}"
  log "Warnings: ${WARN_COUNT}"
  log "Failures: ${FAIL_COUNT}"

  if (( FAIL_COUNT > 0 )); then
    exit 1
  fi

  if (( WARN_COUNT > 0 )); then
    exit 0
  fi
}

main "$@"
