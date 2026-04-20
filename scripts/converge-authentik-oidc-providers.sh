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

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

authentik_compose() {
  docker compose \
    --env-file "${NETBIRD_COMPOSE_ENV_FILE}" \
    -f "${NETBIRD_COMPOSE_FILE}" \
    --profile authentik \
    "$@"
}

run_authentik_python() {
  local script_path="$1"
  authentik_compose exec \
    -T \
    -e AUTHENTIK_OIDC_SIGNING_KEY_NAME="${AUTHENTIK_OIDC_SIGNING_KEY_NAME}" \
    -e AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS="${AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS}" \
    authentik-server \
    ak shell < "${script_path}"
}

ensure_authentik_running() {
  [[ -f "${NETBIRD_COMPOSE_FILE}" ]] || fail "Missing NetBird runtime compose file: ${NETBIRD_COMPOSE_FILE}"
  [[ -f "${NETBIRD_COMPOSE_ENV_FILE}" ]] || fail "Missing NetBird runtime env file: ${NETBIRD_COMPOSE_ENV_FILE}"

  log "Ensuring Authentik services are running."
  authentik_compose up -d authentik-postgresql authentik-redis authentik-server authentik-worker >/dev/null
}

wait_for_authentik_shell() {
  local probe_script output attempt
  probe_script="$(mktemp)"

  cat > "${probe_script}" <<'PY'
from authentik.core.models import User
print("AUTHENTIK_READY")
PY

  for attempt in {1..20}; do
    if output="$(run_authentik_python "${probe_script}" 2>/dev/null)" && [[ "${output}" == *AUTHENTIK_READY* ]]; then
      rm -f "${probe_script}"
      log "Authentik shell is ready."
      return 0
    fi
    sleep 3
  done

  rm -f "${probe_script}"
  fail "Authentik did not become ready in time."
}

require_root
require_config
require_command python3
require_command docker

LOG_DIR="$(yaml_get system.log_dir)"
LOG_FILE="${LOG_DIR}/converge-authentik-oidc-providers.log"
NETBIRD_STACK_ROOT="$(yaml_get netbird.stack_root)"
NETBIRD_COMPOSE_FILE="$(config_first "${NETBIRD_STACK_ROOT}/docker-compose.yaml" netbird.compose_file)"
NETBIRD_COMPOSE_ENV_FILE="$(config_first "${NETBIRD_STACK_ROOT}/.env" netbird.compose_env_file)"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "Authentik OIDC provider converge aborted at line $LINENO."' ERR

load_env_file

AUTHENTIK_ENABLED="${AUTHENTIK_ENABLED:-false}"
AUTHENTIK_NETBIRD_OIDC_ENABLED="${AUTHENTIK_NETBIRD_OIDC_ENABLED:-false}"
HA_AUTH_OIDC_ENABLED="${HA_AUTH_OIDC_ENABLED:-false}"
AUTHENTIK_NETBIRD_APPLICATION_SLUG="${AUTHENTIK_NETBIRD_APPLICATION_SLUG:-netbird}"
HA_OIDC_APPLICATION_SLUG="${HA_OIDC_APPLICATION_SLUG:-home-assistant}"
AUTHENTIK_OIDC_SIGNING_KEY_NAME="${AUTHENTIK_OIDC_SIGNING_KEY_NAME:-authentik Self-signed Certificate}"

[[ "${AUTHENTIK_ENABLED}" == "true" ]] || {
  log "AUTHENTIK_ENABLED is not true. Skipping Authentik OAuth2 provider convergence."
  exit 0
}

declare -a provider_slugs=()
if [[ "${AUTHENTIK_NETBIRD_OIDC_ENABLED}" == "true" ]]; then
  provider_slugs+=("${AUTHENTIK_NETBIRD_APPLICATION_SLUG}")
fi
if [[ "${HA_AUTH_OIDC_ENABLED}" == "true" ]]; then
  provider_slugs+=("${HA_OIDC_APPLICATION_SLUG}")
fi

if (( ${#provider_slugs[@]} == 0 )); then
  log "Neither AUTHENTIK_NETBIRD_OIDC_ENABLED nor HA_AUTH_OIDC_ENABLED is true. Skipping Authentik OAuth2 provider convergence."
  exit 0
fi

AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS="$(IFS=,; printf '%s' "${provider_slugs[*]}")"

ensure_authentik_running
wait_for_authentik_shell

python_script="$(mktemp)"
cat > "${python_script}" <<'PY'
import os
from django.db import transaction

from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import OAuth2Provider

key_name = os.environ["AUTHENTIK_OIDC_SIGNING_KEY_NAME"].strip()
provider_slugs = [
    slug.strip()
    for slug in os.environ.get("AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS", "").split(",")
    if slug.strip()
]

if not provider_slugs:
    raise SystemExit("No Authentik OAuth2 provider application slugs were supplied.")

try:
    cert = CertificateKeyPair.objects.get(name=key_name)
except CertificateKeyPair.DoesNotExist as exc:
    available = ", ".join(CertificateKeyPair.objects.order_by("name").values_list("name", flat=True))
    raise SystemExit(
        f"Signing key '{key_name}' was not found. Available certificate names: {available}"
    ) from exc

providers = list(
    OAuth2Provider.objects.select_related("application")
    .filter(application__slug__in=provider_slugs)
    .order_by("application__slug")
)

found_slugs = {
    provider.application.slug
    for provider in providers
    if getattr(provider, "application", None) is not None
}
missing_slugs = [slug for slug in provider_slugs if slug not in found_slugs]
if missing_slugs:
    raise SystemExit(
        "Missing Authentik OAuth2 providers for application slug(s): "
        + ", ".join(missing_slugs)
    )

updated = []
already = []

with transaction.atomic():
    for provider in providers:
        if provider.signing_key_id == cert.pk:
            already.append(provider.application.slug)
            continue
        provider.signing_key = cert
        provider.save(update_fields=["signing_key"])
        updated.append(provider.application.slug)

print(
    "AUTHENTIK_PROVIDER_SIGNING_KEY_OK "
    f"key_name={key_name} "
    f"updated={','.join(updated) if updated else 'none'} "
    f"already={','.join(already) if already else 'none'}"
)
PY

log "Ensuring Authentik OAuth2 providers use signing key '${AUTHENTIK_OIDC_SIGNING_KEY_NAME}'."
run_authentik_python "${python_script}"
rm -f "${python_script}"

log "===== ha-federated-access Authentik OAuth2 provider converge completed successfully ====="
