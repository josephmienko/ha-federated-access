#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config.yaml}"
DEFAULT_LOG_DIR="/var/log/crooked-sentry"
DEFAULT_NETBIRD_STACK_ROOT="/opt/crooked-sentry/netbird"

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Must run as root"; exit 1; }
}

yaml_get_or_default() {
  local expr="$1"
  local default_value="$2"
  python3 - "${CONFIG_FILE}" "${expr}" "${default_value}" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
expr = sys.argv[2]
default = sys.argv[3]

if not path:
    print(default)
    raise SystemExit(0)

if importlib.util.find_spec("yaml") is None:
    print(default)
    raise SystemExit(0)

import yaml

try:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
except FileNotFoundError:
    print(default)
    raise SystemExit(0)

cur = data
for p in expr.split("."):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        print(default)
        raise SystemExit(0)

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

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/bootstrap-authentik-user.sh <email> <password> [display-name]

Environment fallbacks:
  AUTHENTIK_TEST_USER_EMAIL
  AUTHENTIK_TEST_USER_PASSWORD
  AUTHENTIK_TEST_USER_NAME
  AUTHENTIK_TEST_USER_EMAIL_VERIFIED=true|false

This helper:
  - creates or updates an Authentik user whose username equals the email
  - sets user.attributes.email_verified for the patched Home Assistant OIDC flow
  - creates or updates a custom Authentik OAuth2 email scope mapping
  - attaches that mapping to the NetBird and Home Assistant Authentik providers
EOF
}

normalize_bool() {
  case "${1,,}" in
    1|true|yes|on) printf 'true\n' ;;
    0|false|no|off) printf 'false\n' ;;
    *) fail "Boolean value expected, got: $1" ;;
  esac
}

authentik_compose() {
  docker compose \
    --env-file "${NETBIRD_STACK_ROOT}/.env" \
    -f "${NETBIRD_STACK_ROOT}/docker-compose.yaml" \
    --profile authentik \
    "$@"
}

run_authentik_python() {
  local script_path="$1"
  authentik_compose exec \
    -T \
    -e AUTHENTIK_TEST_USER_EMAIL="${AUTHENTIK_TEST_USER_EMAIL}" \
    -e AUTHENTIK_TEST_USER_PASSWORD="${AUTHENTIK_TEST_USER_PASSWORD}" \
    -e AUTHENTIK_TEST_USER_NAME="${AUTHENTIK_TEST_USER_NAME}" \
    -e AUTHENTIK_TEST_USER_EMAIL_VERIFIED="${AUTHENTIK_TEST_USER_EMAIL_VERIFIED}" \
    -e AUTHENTIK_EMAIL_SCOPE_MAPPING_NAME="${AUTHENTIK_EMAIL_SCOPE_MAPPING_NAME}" \
    -e AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS="${AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS}" \
    authentik-server \
    ak shell < "${script_path}"
}

ensure_authentik_running() {
  [[ -f "${NETBIRD_STACK_ROOT}/docker-compose.yaml" ]] || fail "Missing NetBird runtime compose file: ${NETBIRD_STACK_ROOT}/docker-compose.yaml"
  [[ -f "${NETBIRD_STACK_ROOT}/.env" ]] || fail "Missing NetBird runtime env file: ${NETBIRD_STACK_ROOT}/.env"

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
require_command python3
require_command docker

LOG_DIR="$(yaml_get_or_default system.log_dir "${DEFAULT_LOG_DIR}")"
LOG_FILE="${LOG_DIR}/bootstrap-authentik-user.log"
NETBIRD_STACK_ROOT="${NETBIRD_STACK_ROOT:-$(yaml_get_or_default netbird.stack_root "${DEFAULT_NETBIRD_STACK_ROOT}")}"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "Authentik test-user bootstrap aborted at line $LINENO."' ERR

load_env_file

AUTHENTIK_ENABLED="${AUTHENTIK_ENABLED:-false}"
AUTHENTIK_NETBIRD_APPLICATION_SLUG="${AUTHENTIK_NETBIRD_APPLICATION_SLUG:-netbird}"
HA_OIDC_APPLICATION_SLUG="${HA_OIDC_APPLICATION_SLUG:-home-assistant}"

AUTHENTIK_TEST_USER_EMAIL="${AUTHENTIK_TEST_USER_EMAIL:-${1:-}}"
AUTHENTIK_TEST_USER_PASSWORD="${AUTHENTIK_TEST_USER_PASSWORD:-${2:-}}"
AUTHENTIK_TEST_USER_NAME="${AUTHENTIK_TEST_USER_NAME:-${3:-}}"
AUTHENTIK_TEST_USER_EMAIL_VERIFIED="$(normalize_bool "${AUTHENTIK_TEST_USER_EMAIL_VERIFIED:-true}")"
AUTHENTIK_EMAIL_SCOPE_MAPPING_NAME="${AUTHENTIK_EMAIL_SCOPE_MAPPING_NAME:-CrookedSentry OIDC verified email}"
AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS="${AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS:-${AUTHENTIK_NETBIRD_APPLICATION_SLUG},${HA_OIDC_APPLICATION_SLUG}}"

[[ "${AUTHENTIK_ENABLED}" == "true" ]] || fail "AUTHENTIK_ENABLED=true is required."
[[ -n "${AUTHENTIK_TEST_USER_EMAIL}" ]] || { usage; fail "Missing Authentik test user email."; }
[[ -n "${AUTHENTIK_TEST_USER_PASSWORD}" ]] || { usage; fail "Missing Authentik test user password."; }
[[ "${AUTHENTIK_TEST_USER_EMAIL}" == *"@"* ]] || fail "AUTHENTIK_TEST_USER_EMAIL must be a valid email address."

if [[ -z "${AUTHENTIK_TEST_USER_NAME}" ]]; then
  AUTHENTIK_TEST_USER_NAME="${AUTHENTIK_TEST_USER_EMAIL}"
fi

ensure_authentik_running
wait_for_authentik_shell

python_script="$(mktemp)"
cat > "${python_script}" <<'PY'
import os
from django.db import transaction

from authentik.core.models import User
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping

email = os.environ["AUTHENTIK_TEST_USER_EMAIL"].strip().lower()
password = os.environ["AUTHENTIK_TEST_USER_PASSWORD"]
display_name = os.environ.get("AUTHENTIK_TEST_USER_NAME", "").strip() or email
email_verified = os.environ.get("AUTHENTIK_TEST_USER_EMAIL_VERIFIED", "true").lower() == "true"
mapping_name = os.environ.get("AUTHENTIK_EMAIL_SCOPE_MAPPING_NAME", "CrookedSentry OIDC verified email").strip()
provider_slugs = [
    slug.strip()
    for slug in os.environ.get("AUTHENTIK_OIDC_PROVIDER_APPLICATION_SLUGS", "").split(",")
    if slug.strip()
]

if not provider_slugs:
    raise SystemExit("No Authentik OAuth2 provider application slugs were supplied.")

default_email_mapping_name = "authentik default OAuth Mapping: OpenID 'email'"
mapping_expression = (
    "return {\n"
    '    "email": request.user.email,\n'
    '    "email_verified": bool(request.user.attributes.get("email_verified", False)),\n'
    "}\n"
)

with transaction.atomic():
    user, created = User.objects.get_or_create(
        username=email,
        defaults={
            "email": email,
            "name": display_name,
            "is_active": True,
            "attributes": {"email_verified": email_verified},
        },
    )

    user_changed = created
    if user.email != email:
        user.email = email
        user_changed = True
    if user.name != display_name:
        user.name = display_name
        user_changed = True
    if user.is_active is not True:
        user.is_active = True
        user_changed = True

    attrs = dict(user.attributes or {})
    if attrs.get("email_verified") is not email_verified:
        attrs["email_verified"] = email_verified
        user.attributes = attrs
        user_changed = True

    user.set_password(password)
    user_changed = True

    if user_changed:
        user.save()

    mapping, mapping_created = ScopeMapping.objects.get_or_create(
        name=mapping_name,
        defaults={
            "scope_name": "email",
            "expression": mapping_expression,
            "description": "CrookedSentry custom email scope mapping with email_verified support.",
        },
    )

    mapping_changed = mapping_created
    if getattr(mapping, "scope_name", None) != "email":
        mapping.scope_name = "email"
        mapping_changed = True
    if getattr(mapping, "expression", "").strip() != mapping_expression.strip():
        mapping.expression = mapping_expression
        mapping_changed = True
    if hasattr(mapping, "description"):
        desired_description = "CrookedSentry custom email scope mapping with email_verified support."
        if getattr(mapping, "description", "") != desired_description:
            mapping.description = desired_description
            mapping_changed = True
    if mapping_changed:
        mapping.save()

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

    removed_defaults = []
    attached_providers = []
    for provider in providers:
        attached_providers.append(provider.application.slug)
        provider.property_mappings.add(mapping)
        for default_mapping in provider.property_mappings.filter(name=default_email_mapping_name):
            provider.property_mappings.remove(default_mapping)
            removed_defaults.append(provider.application.slug)

print(
    "AUTHENTIK_BOOTSTRAP_OK "
    f"username={email} "
    f"email_verified={str(email_verified).lower()} "
    f"user_created={str(created).lower()} "
    f"mapping_created={str(mapping_created).lower()} "
    f"providers={','.join(attached_providers)} "
    f"default_email_mapping_removed={','.join(removed_defaults) if removed_defaults else 'none'}"
)
PY

log "Creating or updating Authentik user ${AUTHENTIK_TEST_USER_EMAIL} and syncing OAuth email scope mapping."
run_authentik_python "${python_script}"
rm -f "${python_script}"

log "Next step: ensure Home Assistant already has a local user whose username is exactly ${AUTHENTIK_TEST_USER_EMAIL} before the first SSO login."
log "Then test the happy path at https://ha.proxy.crookedsentry.net/auth/oidc/redirect"
