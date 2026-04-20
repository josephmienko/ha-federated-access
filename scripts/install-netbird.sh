#!/usr/bin/env bash
set -Eeuo pipefail

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
  [[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
  log "Loading environment variables from ${ENV_FILE}"
  set -o allexport
  source "${ENV_FILE}"
  set +o allexport
}

install_base_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 python3-yaml ca-certificates curl jq
}

require_root
require_config
install_base_deps

LOG_DIR="$(yaml_get system.log_dir)"
LOG_FILE="${LOG_DIR}/install-netbird.log"
NETBIRD_ENABLED="$(yaml_get netbird.enabled)"
NETBIRD_STACK_ROOT="$(yaml_get netbird.stack_root)"
NETBIRD_SERVICE_NAME="$(yaml_get netbird.compose_service_name)"
NETBIRD_COMPOSE_FILE="$(config_first "${NETBIRD_STACK_ROOT}/docker-compose.yaml" netbird.compose_file)"
NETBIRD_COMPOSE_ENV_FILE="$(config_first "${NETBIRD_STACK_ROOT}/.env" netbird.compose_env_file)"
RUNTIME_PROXY_ENV="${NETBIRD_STACK_ROOT}/generated/proxy.env"
RUNTIME_PEER_ENV="${NETBIRD_STACK_ROOT}/generated/peer.env"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "NetBird installer aborted at line $LINENO."' ERR

[[ "${NETBIRD_ENABLED}" == "true" ]] || {
  log "NetBird is disabled in config.yaml. Nothing to do."
  exit 0
}

load_env_file

NETBIRD_REVERSE_PROXY_ENABLED="${NETBIRD_REVERSE_PROXY_ENABLED:-false}"
NETBIRD_HA_PROXY_ENABLED="${NETBIRD_HA_PROXY_ENABLED:-false}"
NETBIRD_PROXY_ACME_CHALLENGE_TYPE="${NETBIRD_PROXY_ACME_CHALLENGE_TYPE:-tls-alpn-01}"
NETBIRD_PI_PEER_NAME="${NETBIRD_PI_PEER_NAME:-$(hostname -s)-pi}"
AUTHENTIK_ENABLED="${AUTHENTIK_ENABLED:-false}"
AUTHENTIK_DOMAIN="${AUTHENTIK_DOMAIN:-}"
AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-${NETBIRD_OWNER_EMAIL:-}}"
AUTHENTIK_NETBIRD_OIDC_ENABLED="${AUTHENTIK_NETBIRD_OIDC_ENABLED:-false}"
AUTHENTIK_NETBIRD_APPLICATION_SLUG="${AUTHENTIK_NETBIRD_APPLICATION_SLUG:-netbird}"
AUTHENTIK_NETBIRD_ISSUER_URL="${AUTHENTIK_NETBIRD_ISSUER_URL:-https://${AUTHENTIK_DOMAIN}/application/o/${AUTHENTIK_NETBIRD_APPLICATION_SLUG}/}"
HA_AUTH_OIDC_ENABLED="${HA_AUTH_OIDC_ENABLED:-false}"
HA_OIDC_COMPONENT_VERSION="${HA_OIDC_COMPONENT_VERSION:-v0.6.5-alpha}"
HA_OIDC_APPLICATION_SLUG="${HA_OIDC_APPLICATION_SLUG:-home-assistant}"
HA_OIDC_DISCOVERY_URL="${HA_OIDC_DISCOVERY_URL:-https://${AUTHENTIK_DOMAIN}/application/o/${HA_OIDC_APPLICATION_SLUG}/.well-known/openid-configuration}"
LANDING_DOMAIN="${LANDING_DOMAIN:-${TF_VAR_cloudflare_zone_name:-${NETBIRD_MGMT_DNS_DOMAIN:-}}}"
LANDING_REDIRECT_URL="${LANDING_REDIRECT_URL:-https://${NETBIRD_HA_PROXY_SUBDOMAIN:-ha}.${NETBIRD_PROXY_DOMAIN:-proxy.invalid}/auth/oidc/redirect}"

if [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" && "${NETBIRD_REVERSE_PROXY_ENABLED}" != "true" ]]; then
  fail "NETBIRD_HA_PROXY_ENABLED=true requires NETBIRD_REVERSE_PROXY_ENABLED=true"
fi

require_var() {
  local key="$1"
  local value="${!key:-}"
  if [[ -z "${value}" || "${value}" == "change-me" ]]; then
    fail "Missing required variable ${key} in ${ENV_FILE}"
  fi
}

for key in \
  NETBIRD_DOMAIN \
  NETBIRD_MGMT_API_PORT \
  NETBIRD_SIGNAL_PORT \
  NETBIRD_RELAY_PORT \
  NETBIRD_TURN_EXTERNAL_IP \
  NETBIRD_TURN_MIN_PORT \
  NETBIRD_TURN_MAX_PORT \
  NETBIRD_LETSENCRYPT_EMAIL \
  NETBIRD_MGMT_DNS_DOMAIN \
  NETBIRD_MGMT_DISABLE_DEFAULT_POLICY \
  NETBIRD_DISABLE_ANONYMOUS_METRICS \
  NETBIRD_LOCAL_AUTH_DISABLED \
  NETBIRD_OWNER_EMAIL \
  NETBIRD_OWNER_NAME \
  NETBIRD_OWNER_PASSWORD \
  NETBIRD_TURN_USER \
  NETBIRD_TURN_PASSWORD \
  NETBIRD_TURN_SECRET \
  NETBIRD_RELAY_AUTH_SECRET \
  NETBIRD_DATASTORE_ENC_KEY
do
  require_var "${key}"
done

require_soft_var() {
  local key="$1"
  local value="${!key:-}"
  [[ -n "${value}" && "${value}" != "change-me" ]]
}

valid_proxy_token() {
  local value="$1"
  [[ "${value}" =~ ^nbx_[A-Za-z0-9_-]+$ ]]
}

if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
  require_var NETBIRD_PROXY_DOMAIN
fi

if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
  for key in \
    AUTHENTIK_DOMAIN \
    AUTHENTIK_POSTGRES_PASSWORD \
    AUTHENTIK_SECRET_KEY \
    AUTHENTIK_BOOTSTRAP_PASSWORD
  do
    require_var "${key}"
  done
fi

if [[ "${AUTHENTIK_NETBIRD_OIDC_ENABLED}" == "true" ]]; then
  for key in \
    AUTHENTIK_DOMAIN \
    AUTHENTIK_NETBIRD_CLIENT_ID \
    AUTHENTIK_NETBIRD_CLIENT_SECRET
  do
    require_var "${key}"
  done
fi

if [[ "${HA_AUTH_OIDC_ENABLED}" == "true" ]]; then
  for key in \
    AUTHENTIK_DOMAIN \
    HA_OIDC_CLIENT_ID
  do
    require_var "${key}"
  done
fi

require_network() {
  if ! getent ahosts github.com >/dev/null 2>&1; then
    warn "DNS resolution test failed. Continuing because NetBird can use cached images."
    return 0
  fi

  if ! curl -fsSLI --max-time 10 https://github.com >/dev/null 2>&1; then
    warn "HTTPS connectivity test failed. Continuing because NetBird can use cached images."
  fi
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
  else
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
  fi

  if ! docker compose version >/dev/null 2>&1; then
    apt-get update
    apt-get install -y docker-compose-plugin || true
  fi

  systemctl enable docker
  systemctl start docker
  docker version >/dev/null || fail "Docker command not functional after install."
  docker compose version >/dev/null || fail "Docker Compose plugin not available."
}

check_dns_alignment() {
  local expected_public_ip="${TF_VAR_server_public_ip:-${NETBIRD_TURN_EXTERNAL_IP}}"
  local resolved_public_ip=""

  resolved_public_ip="$(getent ahostsv4 "${NETBIRD_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -z "${resolved_public_ip}" ]]; then
    warn "Could not resolve ${NETBIRD_DOMAIN} from the Pi. Let's Encrypt will fail until DNS is in place."
    return
  fi

  if [[ "${resolved_public_ip}" == "${expected_public_ip}" ]]; then
    log "DNS check passed: ${NETBIRD_DOMAIN} resolves to ${resolved_public_ip}"
  else
    warn "DNS mismatch: ${NETBIRD_DOMAIN} resolves to ${resolved_public_ip}, expected ${expected_public_ip}. Let's Encrypt may fail until Cloudflare is updated."
  fi

  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    local proxy_public_ip=""
    local wildcard_public_ip=""
    local wildcard_probe="ha.${NETBIRD_PROXY_DOMAIN}"

    proxy_public_ip="$(getent ahostsv4 "${NETBIRD_PROXY_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${proxy_public_ip}" ]]; then
      warn "Could not resolve ${NETBIRD_PROXY_DOMAIN} from the Pi. Reverse proxy TLS issuance will fail until DNS is in place."
    elif [[ "${proxy_public_ip}" == "${expected_public_ip}" ]]; then
      log "DNS check passed: ${NETBIRD_PROXY_DOMAIN} resolves to ${proxy_public_ip}"
    else
      warn "DNS mismatch: ${NETBIRD_PROXY_DOMAIN} resolves to ${proxy_public_ip}, expected ${expected_public_ip}. Reverse proxy TLS may fail until Cloudflare is updated."
    fi

    wildcard_public_ip="$(getent ahostsv4 "${wildcard_probe}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${wildcard_public_ip}" ]]; then
      warn "Wildcard DNS does not currently resolve ${wildcard_probe}. Browser-only NetBird services will not come online until the wildcard record exists."
    elif [[ "${wildcard_public_ip}" == "${expected_public_ip}" ]]; then
      log "DNS check passed: wildcard proxy domain resolves via ${wildcard_probe} -> ${wildcard_public_ip}"
    else
      warn "Wildcard DNS mismatch: ${wildcard_probe} resolves to ${wildcard_public_ip}, expected ${expected_public_ip}."
    fi
  fi

  if [[ -n "${LANDING_DOMAIN}" ]]; then
    local landing_public_ip=""
    landing_public_ip="$(getent ahostsv4 "${LANDING_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${landing_public_ip}" ]]; then
      warn "Could not resolve ${LANDING_DOMAIN} from the Pi. Apex landing redirect will not work until DNS is in place."
    elif [[ "${landing_public_ip}" == "${expected_public_ip}" ]]; then
      log "DNS check passed: ${LANDING_DOMAIN} resolves to ${landing_public_ip}"
    else
      warn "DNS mismatch: ${LANDING_DOMAIN} resolves to ${landing_public_ip}, expected ${expected_public_ip}. Apex landing redirect may fail until Cloudflare is updated."
    fi
  fi

  if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
    local authentik_public_ip=""
    authentik_public_ip="$(getent ahostsv4 "${AUTHENTIK_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "${authentik_public_ip}" ]]; then
      warn "Could not resolve ${AUTHENTIK_DOMAIN} from the Pi. Authentik public OIDC flows will fail until DNS is in place."
    elif [[ "${authentik_public_ip}" == "${expected_public_ip}" ]]; then
      log "DNS check passed: ${AUTHENTIK_DOMAIN} resolves to ${authentik_public_ip}"
    else
      warn "DNS mismatch: ${AUTHENTIK_DOMAIN} resolves to ${authentik_public_ip}, expected ${expected_public_ip}. Authentik public OIDC flows may fail until Cloudflare is updated."
    fi
  fi
}

prepare_stack_root() {
  install -d -m 0750 "${NETBIRD_STACK_ROOT}" "${NETBIRD_STACK_ROOT}/generated" "$(dirname "${NETBIRD_COMPOSE_FILE}")" "$(dirname "${NETBIRD_COMPOSE_ENV_FILE}")"
  install -m 0640 "${PROJECT_ROOT}/netbird/docker-compose.yaml" "${NETBIRD_COMPOSE_FILE}"

  GENERATED_DIR="${NETBIRD_STACK_ROOT}/generated" \
  ENV_FILE="${ENV_FILE}" \
  "${PROJECT_ROOT}/netbird/render-config.sh"

  chmod 0600 "${NETBIRD_STACK_ROOT}/generated/management.json" "${NETBIRD_STACK_ROOT}/generated/turnserver.conf"
  chmod 0644 "${NETBIRD_STACK_ROOT}/generated/dashboard-default.conf"
  chmod 0600 "${NETBIRD_STACK_ROOT}/generated/proxy.env" 2>/dev/null || true
}

proxy_runtime_env_ready() {
  [[ -f "${RUNTIME_PROXY_ENV}" ]] || return 1
  grep -q '^NB_PROXY_TOKEN=nbx_' "${RUNTIME_PROXY_ENV}" 2>/dev/null
}

write_stack_env_file() {
  cat > "${NETBIRD_COMPOSE_ENV_FILE}" <<EOF
NETBIRD_DOMAIN=${NETBIRD_DOMAIN}
NETBIRD_PROXY_DOMAIN=${NETBIRD_PROXY_DOMAIN:-}
NETBIRD_MGMT_API_PORT=${NETBIRD_MGMT_API_PORT}
NETBIRD_SIGNAL_PORT=${NETBIRD_SIGNAL_PORT}
NETBIRD_RELAY_PORT=${NETBIRD_RELAY_PORT}
NETBIRD_LETSENCRYPT_EMAIL=${NETBIRD_LETSENCRYPT_EMAIL}
NETBIRD_MGMT_DNS_DOMAIN=${NETBIRD_MGMT_DNS_DOMAIN}
NETBIRD_RELAY_AUTH_SECRET=${NETBIRD_RELAY_AUTH_SECRET}
NETBIRD_DISABLE_ANONYMOUS_METRICS=${NETBIRD_DISABLE_ANONYMOUS_METRICS}
NETBIRD_REVERSE_PROXY_ENABLED=${NETBIRD_REVERSE_PROXY_ENABLED}
NETBIRD_HA_PROXY_ENABLED=${NETBIRD_HA_PROXY_ENABLED}
NETBIRD_PI_PEER_NAME=${NETBIRD_PI_PEER_NAME}
LANDING_DOMAIN=${LANDING_DOMAIN}
LANDING_REDIRECT_URL=${LANDING_REDIRECT_URL}
AUTHENTIK_ENABLED=${AUTHENTIK_ENABLED}
AUTHENTIK_DOMAIN=${AUTHENTIK_DOMAIN}
AUTHENTIK_POSTGRES_DB=${AUTHENTIK_POSTGRES_DB:-authentik}
AUTHENTIK_POSTGRES_USER=${AUTHENTIK_POSTGRES_USER:-authentik}
AUTHENTIK_POSTGRES_PASSWORD=${AUTHENTIK_POSTGRES_PASSWORD:-}
AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY:-}
AUTHENTIK_BOOTSTRAP_EMAIL=${AUTHENTIK_BOOTSTRAP_EMAIL}
AUTHENTIK_BOOTSTRAP_PASSWORD=${AUTHENTIK_BOOTSTRAP_PASSWORD:-}
AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN:-}
EOF

  local optional_keys=(
    NETBIRD_DASHBOARD_TAG
    NETBIRD_SIGNAL_TAG
    NETBIRD_RELAY_TAG
    NETBIRD_MANAGEMENT_TAG
    NETBIRD_PROXY_TAG
    NETBIRD_CLIENT_TAG
    NETBIRD_TRAEFIK_TAG
    COTURN_TAG
    AUTHENTIK_TAG
    AUTHENTIK_POSTGRES_TAG
    AUTHENTIK_REDIS_TAG
  )
  local key=""
  for key in "${optional_keys[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      printf '%s=%s\n' "${key}" "${!key}" >> "${NETBIRD_COMPOSE_ENV_FILE}"
    fi
  done

  chmod 0600 "${NETBIRD_COMPOSE_ENV_FILE}"
}

write_systemd_service() {
  local svc="/etc/systemd/system/${NETBIRD_SERVICE_NAME}"
  cat > "${svc}" <<EOF
[Unit]
Description=ha-federated-access NetBird Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${NETBIRD_STACK_ROOT}
ExecStart=/bin/sh -c 'profiles=""; if grep -q "^AUTHENTIK_ENABLED=true" ${NETBIRD_COMPOSE_ENV_FILE} 2>/dev/null; then profiles="\$profiles --profile authentik"; fi; if grep -q "^NB_PROXY_TOKEN=nbx_" ${RUNTIME_PROXY_ENV} 2>/dev/null; then profiles="\$profiles --profile reverse-proxy"; fi; if grep -q "^NB_SETUP_KEY=" ${RUNTIME_PEER_ENV} 2>/dev/null; then profiles="\$profiles --profile browser-access"; fi; exec /usr/bin/docker compose --env-file ${NETBIRD_COMPOSE_ENV_FILE} -f ${NETBIRD_COMPOSE_FILE} \$profiles up -d'
ExecStop=/bin/sh -c 'profiles=""; if grep -q "^AUTHENTIK_ENABLED=true" ${NETBIRD_COMPOSE_ENV_FILE} 2>/dev/null; then profiles="\$profiles --profile authentik"; fi; if grep -q "^NB_PROXY_TOKEN=nbx_" ${RUNTIME_PROXY_ENV} 2>/dev/null; then profiles="\$profiles --profile reverse-proxy"; fi; if grep -q "^NB_SETUP_KEY=" ${RUNTIME_PEER_ENV} 2>/dev/null; then profiles="\$profiles --profile browser-access"; fi; exec /usr/bin/docker compose --env-file ${NETBIRD_COMPOSE_ENV_FILE} -f ${NETBIRD_COMPOSE_FILE} \$profiles down'
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${NETBIRD_SERVICE_NAME}"
}

stop_existing_service() {
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${NETBIRD_SERVICE_NAME}"; then
    log "Stopping existing NetBird service: ${NETBIRD_SERVICE_NAME}"
    systemctl stop "${NETBIRD_SERVICE_NAME}" || true
  fi

  log "Ensuring stale NetBird containers are down before port checks."
  docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
}

port_in_use_tcp() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v port="${port}" '
    {
      n = split($4, parts, ":")
      if (parts[n] == port) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

port_in_use_udp() {
  local port="$1"
  ss -lunH 2>/dev/null | awk -v port="${port}" '
    {
      n = split($5, parts, ":")
      if (parts[n] == port) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

check_host_port_conflicts() {
  local tcp_ports=(80 443 "${NETBIRD_MGMT_API_PORT}" 3478)
  local port=""
  for port in "${tcp_ports[@]}"; do
    if port_in_use_tcp "${port}"; then
      fail "TCP port ${port} is already in use after stopping NetBird. Resolve the conflict before deploying NetBird."
    fi
  done

  if port_in_use_udp 3478; then
    fail "UDP port 3478 is already in use after stopping NetBird. Resolve the conflict before deploying NetBird."
  fi
}

pull_images() {
  local compose_args=()
  if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
    compose_args+=(--profile authentik)
  fi
  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    compose_args+=(--profile reverse-proxy)
  fi

  if docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" "${compose_args[@]}" pull; then
    if [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]]; then
      docker pull "netbirdio/netbird:${NETBIRD_CLIENT_TAG:-latest}" || true
    fi
    return
  fi

  warn "Docker image pull failed. Falling back to cached local NetBird images where available."

  local images=(
    "traefik:${NETBIRD_TRAEFIK_TAG:-v3.6.7}"
    "netbirdio/dashboard:${NETBIRD_DASHBOARD_TAG:-latest}"
    "netbirdio/signal:${NETBIRD_SIGNAL_TAG:-latest}"
    "netbirdio/relay:${NETBIRD_RELAY_TAG:-latest}"
    "netbirdio/management:${NETBIRD_MANAGEMENT_TAG:-latest}"
    "coturn/coturn:${COTURN_TAG:-4.6.3}"
  )
  if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
    images+=(
      "ghcr.io/goauthentik/server:${AUTHENTIK_TAG:-2026.2}"
      "postgres:${AUTHENTIK_POSTGRES_TAG:-16-alpine}"
      "redis:${AUTHENTIK_REDIS_TAG:-7-alpine}"
    )
  fi
  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    images+=("netbirdio/reverse-proxy:${NETBIRD_PROXY_TAG:-latest}")
  fi
  if [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]]; then
    images+=("netbirdio/netbird:${NETBIRD_CLIENT_TAG:-latest}")
  fi
  local missing=()
  local image=""
  for image in "${images[@]}"; do
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      missing+=("${image}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    fail "Image pull failed and required images are not cached locally: ${missing[*]}"
  fi
}

start_stack() {
  docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
  systemctl start "${NETBIRD_SERVICE_NAME}"
}

write_runtime_proxy_env() {
  local proxy_token="$1"
  install -d -m 0750 "$(dirname "${RUNTIME_PROXY_ENV}")"
  cat > "${RUNTIME_PROXY_ENV}" <<EOF
NB_PROXY_DOMAIN=${NETBIRD_PROXY_DOMAIN}
NB_PROXY_TOKEN=${proxy_token}
NB_PROXY_MANAGEMENT_ADDRESS=http://management:33073
NB_PROXY_ALLOW_INSECURE=true
NB_PROXY_ADDRESS=:8443
NB_PROXY_ACME_CERTIFICATES=true
NB_PROXY_ACME_CHALLENGE_TYPE=${NETBIRD_PROXY_ACME_CHALLENGE_TYPE}
NB_PROXY_CERTIFICATE_DIRECTORY=/certs
EOF
  chmod 0600 "${RUNTIME_PROXY_ENV}"
}

ensure_proxy_env_placeholder() {
  [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]] || return 0
  [[ -f "${RUNTIME_PROXY_ENV}" ]] && return 0
  write_runtime_proxy_env "change-me"
}

ensure_peer_env_state() {
  if [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]]; then
    return 0
  fi

  rm -f "${RUNTIME_PEER_ENV}" 2>/dev/null || true
}

generate_proxy_token() {
  local raw_output=""
  raw_output="$(
    docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" exec -T management \
      /go/bin/netbird-mgmt token create --name "${NETBIRD_PROXY_TOKEN_NAME:-ha-federated-access-proxy}" 2>/dev/null || true
  )"
  printf '%s\n' "${raw_output}" | grep -Eo 'nbx_[A-Za-z0-9_-]+' | tail -n1
}

start_reverse_proxy_if_enabled() {
  [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]] || return 0

  local proxy_token=""
  if require_soft_var NETBIRD_PROXY_TOKEN; then
    valid_proxy_token "${NETBIRD_PROXY_TOKEN}" || fail "NETBIRD_PROXY_TOKEN must be a reverse-proxy token that starts with nbx_. Do not reuse NETBIRD_API_TOKEN here."
    proxy_token="${NETBIRD_PROXY_TOKEN}"
  elif proxy_runtime_env_ready; then
    proxy_token="$(awk -F= '$1=="NB_PROXY_TOKEN"{print $2}' "${RUNTIME_PROXY_ENV}")"
  else
    log "Generating a NetBird reverse-proxy token locally on the Pi."
    proxy_token="$(generate_proxy_token)"
  fi

  [[ -n "${proxy_token}" ]] || fail "Unable to obtain a NetBird reverse-proxy token. Set NETBIRD_PROXY_TOKEN in .env or create one via netbird-mgmt token create."

  write_runtime_proxy_env "${proxy_token}"

  docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" --profile reverse-proxy up -d proxy
  log "NetBird reverse proxy service started."
}

wait_for_endpoint() {
  local name="$1"
  local url="$2"
  local timeout_seconds="${3:-180}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if curl -kfsS --max-time 5 -o /dev/null "${url}" >/dev/null 2>&1; then
      log "${name} is reachable: ${url}"
      return 0
    fi
    sleep 3
  done

  fail "${name} did not become reachable within ${timeout_seconds}s: ${url}"
}

local_authentik_https_ready() {
  curl -kIsS --max-time 10 \
    --resolve "${AUTHENTIK_DOMAIN}:443:127.0.0.1" \
    "https://${AUTHENTIK_DOMAIN}/" >/dev/null 2>&1
}

local_dashboard_https_ready() {
  curl -kIsS --max-time 10 \
    --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1" \
    "https://${NETBIRD_DOMAIN}/" >/dev/null 2>&1
}

local_landing_https_redirect_ready() {
  [[ -n "${LANDING_DOMAIN}" ]] || return 1
  local headers=""
  local location=""
  headers="$(
    curl -kIsS --max-time 10 \
      --resolve "${LANDING_DOMAIN}:443:127.0.0.1" \
      "https://${LANDING_DOMAIN}/" 2>/dev/null || true
  )"
  [[ -n "${headers}" ]] || return 1
  location="$(awk -F': ' 'tolower($1)=="location" {print $2}' <<<"${headers}" | tr -d '\r' | tail -n1)"
  [[ "${location}" == "${LANDING_REDIRECT_URL}" ]]
}

warn_if_public_tls_pending() {
  if local_dashboard_https_ready; then
    log "NetBird public HTTPS is reachable locally through Traefik."
  else
    warn "Public HTTPS is not reachable yet through Traefik. This is usually because DNS or router forwards for 80/tcp and 443/tcp are not in place."
    warn "NetBird owner bootstrap completed locally, but public browser onboarding is still pending."
    warn "After DNS and router forwards are fixed, restart ${NETBIRD_SERVICE_NAME} to retry certificate issuance."
  fi

  [[ -n "${LANDING_DOMAIN}" ]] || return 0
  if local_landing_https_redirect_ready; then
    log "Apex landing redirect is reachable locally through Traefik."
    return 0
  fi

  warn "Apex landing redirect is not reachable yet through Traefik at https://${LANDING_DOMAIN}/."
}

warn_if_authentik_tls_pending() {
  [[ "${AUTHENTIK_ENABLED}" == "true" ]] || return 0

  if local_authentik_https_ready; then
    log "Authentik public HTTPS is reachable locally through Traefik."
    return 0
  fi

  warn "Authentik public HTTPS is not reachable yet through Traefik. Shared OIDC flows will not work until DNS and 80/tcp + 443/tcp forwarding are correct."
}

bootstrap_owner() {
  NETBIRD_SETUP_BASE_URL="http://127.0.0.1:${NETBIRD_MGMT_API_PORT}" \
  ENV_FILE="${ENV_FILE}" \
  "${PROJECT_ROOT}/netbird/setup-instance.sh"
}

run_smoke_tests() {
  wait_for_endpoint "NetBird management API (HTTP)" "http://127.0.0.1:${NETBIRD_MGMT_API_PORT}/api/instance" 300
  bootstrap_owner
  start_reverse_proxy_if_enabled

  local instance_json=""
  instance_json="$(curl -fsS "http://127.0.0.1:${NETBIRD_MGMT_API_PORT}/api/instance")"
  INSTANCE_JSON="${instance_json}" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["INSTANCE_JSON"])
if data.get("setup_required"):
    sys.exit("NetBird setup is still marked as required after owner bootstrap")
PY

  log "NetBird owner bootstrap verified."
  warn_if_public_tls_pending
  warn_if_authentik_tls_pending
}

print_next_steps() {
  local proxy_url_line=""
  local proxy_next_step=""
  local authentik_url_line=""
  local authentik_next_step=""
  if [[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]]; then
    proxy_url_line=$'- Proxy Base:     https://'"${NETBIRD_PROXY_DOMAIN}"
    if [[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]]; then
      proxy_next_step=$'7. Browser access convergence will publish Home Assistant at `ha.'"${NETBIRD_PROXY_DOMAIN}"$'` during deploy.'
    else
      proxy_next_step=$'7. In NetBird Control Center, use Reverse Proxy to publish Home Assistant at a hostname such as `ha.'"${NETBIRD_PROXY_DOMAIN}"$'`.'
    fi
  fi
  if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
    authentik_url_line=$'- Authentik:      https://'"${AUTHENTIK_DOMAIN}"
    authentik_next_step=$'8. Sign in to Authentik at `https://'"${AUTHENTIK_DOMAIN}"$'/` using `AUTHENTIK_BOOTSTRAP_EMAIL` and `AUTHENTIK_BOOTSTRAP_PASSWORD` from `.env`, then configure Google as the upstream source and create OIDC applications for NetBird and Home Assistant.'
  fi

  cat <<EOF

NetBird install completed.

URLs:
- Landing:        https://${LANDING_DOMAIN}
- Dashboard:      https://${NETBIRD_DOMAIN}
- Management API: https://${NETBIRD_DOMAIN}/api
- Embedded IdP:   https://${NETBIRD_DOMAIN}/oauth2
- Signal:         https://${NETBIRD_DOMAIN} (path-routed over 443)
- Relay:          rels://${NETBIRD_DOMAIN}:443
${proxy_url_line}
${authentik_url_line}

Required router forwards to ${NETBIRD_TURN_EXTERNAL_IP} / this Pi:
- 80/tcp
- 443/tcp
- 3478/tcp+udp
- ${NETBIRD_TURN_MIN_PORT}-${NETBIRD_TURN_MAX_PORT}/udp

Next steps:
1. Run \`tofu -chdir=infrastructure apply\` from your Mac if you have not already done so.
2. Confirm the router forwards the ports above to the Pi.
3. If ports 80/tcp or 443/tcp were not forwarded during this install, run \`sudo systemctl restart ${NETBIRD_SERVICE_NAME}\` after you fix the router so Traefik certificate issuance can retry.
4. Log into the dashboard as ${NETBIRD_OWNER_EMAIL}.
5. Create an admin service-user token under Team -> Service Users if you have not already done so, store it locally as \`NETBIRD_API_TOKEN\`, then run \`sudo ./scripts/converge-netbird-idps.sh\` on the Pi or rerun \`./deploy-rp5.sh\`.
6. After the Google provider exists, copy its exact Redirect URL from Settings -> Identity Providers into Google Cloud if needed.
${proxy_next_step}
${authentik_next_step}

Useful commands:
- systemctl status ${NETBIRD_SERVICE_NAME}
- journalctl -u ${NETBIRD_SERVICE_NAME} -b --no-pager
- docker compose --env-file ${NETBIRD_COMPOSE_ENV_FILE} -f ${NETBIRD_COMPOSE_FILE} ps
- docker compose --env-file ${NETBIRD_COMPOSE_ENV_FILE} -f ${NETBIRD_COMPOSE_FILE} logs --tail 100
- sudo ./scripts/converge-netbird-idps.sh
- sudo ./scripts/converge-homeassistant-oidc.sh
EOF
}

main() {
  log "===== ha-federated-access NetBird installer starting ====="
  require_network
  install_docker_if_needed
  check_dns_alignment
  prepare_stack_root
  ensure_proxy_env_placeholder
  ensure_peer_env_state
  write_stack_env_file
  write_systemd_service
  stop_existing_service
  check_host_port_conflicts
  pull_images
  start_stack
  run_smoke_tests
  print_next_steps
  log "===== ha-federated-access NetBird installer completed successfully ====="
}

main "$@"
