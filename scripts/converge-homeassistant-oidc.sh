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

install_base_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 python3-yaml ca-certificates curl jq tar patch
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_soft_var() {
  local key="$1"
  local value="${!key:-}"
  [[ -n "${value}" && "${value}" != "change-me" ]]
}

require_root
require_config
install_base_deps

LOG_DIR="$(yaml_get system.log_dir)"
LOG_FILE="${LOG_DIR}/converge-homeassistant-oidc.log"
STACK_ROOT="$(yaml_get stage2.stack_root)"
HA_CONFIG_DIR="$(yaml_get stage2.homeassistant.config_dir)"
HA_PORT="$(yaml_get stage2.homeassistant.port)"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "Home Assistant OIDC converge aborted at line $LINENO."' ERR

load_env_file

HA_AUTH_OIDC_ENABLED="${HA_AUTH_OIDC_ENABLED:-false}"
AUTHENTIK_DOMAIN="${AUTHENTIK_DOMAIN:-}"
HA_OIDC_COMPONENT_VERSION="${HA_OIDC_COMPONENT_VERSION:-v0.6.5-alpha}"
HA_OIDC_COMPONENT_URL="${HA_OIDC_COMPONENT_URL:-}"
HA_OIDC_COMPONENT_PATCH_FILE="${HA_OIDC_COMPONENT_PATCH_FILE:-}"
HA_OIDC_DISPLAY_NAME="${HA_OIDC_DISPLAY_NAME:-CrookedSentry SSO}"
HA_OIDC_APPLICATION_SLUG="${HA_OIDC_APPLICATION_SLUG:-home-assistant}"
HA_OIDC_DISCOVERY_URL="${HA_OIDC_DISCOVERY_URL:-https://${AUTHENTIK_DOMAIN}/application/o/${HA_OIDC_APPLICATION_SLUG}/.well-known/openid-configuration}"
HA_OIDC_USERNAME_CLAIM="${HA_OIDC_USERNAME_CLAIM:-preferred_username}"
HA_OIDC_DISPLAY_NAME_CLAIM="${HA_OIDC_DISPLAY_NAME_CLAIM:-name}"
HA_OIDC_GROUPS_CLAIM="${HA_OIDC_GROUPS_CLAIM:-groups}"
HA_OIDC_EMAIL_CLAIM="${HA_OIDC_EMAIL_CLAIM:-}"
HA_OIDC_GROUPS_SCOPE="${HA_OIDC_GROUPS_SCOPE:-groups}"
HA_OIDC_ADDITIONAL_SCOPES="${HA_OIDC_ADDITIONAL_SCOPES:-email}"
HA_OIDC_BRANDING_JSON="${HA_OIDC_BRANDING_JSON:-}"
HA_OIDC_AUTOMATIC_USER_LINKING="${HA_OIDC_AUTOMATIC_USER_LINKING:-false}"
HA_OIDC_BOOTSTRAP_VERIFIED_EMAIL_ONCE="${HA_OIDC_BOOTSTRAP_VERIFIED_EMAIL_ONCE:-}"
HA_OIDC_INCLUDE_GROUPS_SCOPE="${HA_OIDC_INCLUDE_GROUPS_SCOPE:-true}"
HA_OIDC_DISABLE_FRONTEND_CHANGES="${HA_OIDC_DISABLE_FRONTEND_CHANGES:-${HA_OIDC_DISABLE_FRONTEND_INJECTION:-false}}"
HA_OIDC_FORCE_HTTPS="${HA_OIDC_FORCE_HTTPS:-true}"
HA_OIDC_USER_ROLE_GROUP="${HA_OIDC_USER_ROLE_GROUP:-}"
HA_OIDC_ADMIN_ROLE_GROUP="${HA_OIDC_ADMIN_ROLE_GROUP:-}"

[[ "${HA_AUTH_OIDC_ENABLED}" == "true" ]] || {
  log "HA_AUTH_OIDC_ENABLED is not true. Skipping Home Assistant OIDC convergence."
  exit 0
}

require_command curl
require_command tar
require_command patch
require_command python3
require_command docker
require_soft_var AUTHENTIK_DOMAIN || fail "HA_AUTH_OIDC_ENABLED=true requires AUTHENTIK_DOMAIN."
require_soft_var HA_OIDC_CLIENT_ID || fail "HA_AUTH_OIDC_ENABLED=true requires HA_OIDC_CLIENT_ID."

HA_CONFIG_FILE="${HA_CONFIG_DIR}/configuration.yaml"
HA_CONFIG_BACKUP_FILE="${HA_CONFIG_DIR}/configuration.yaml.pre-homeassistant-oidc.bak"
HA_SECRETS_FILE="${HA_CONFIG_DIR}/secrets.yaml"
HA_OIDC_COMPONENT_PARENT="${HA_CONFIG_DIR}/custom_components"
HA_OIDC_COMPONENT_DIR="${HA_OIDC_COMPONENT_PARENT}/auth_oidc"
HA_OIDC_COMPONENT_VERSION_FILE="${HA_OIDC_COMPONENT_DIR}/.crooked-sentry-version"
HA_OIDC_COMPONENT_SOURCE_FILE="${HA_OIDC_COMPONENT_DIR}/.crooked-sentry-source"
HA_OIDC_COMPONENT_PATCH_FINGERPRINT_FILE="${HA_OIDC_COMPONENT_DIR}/.crooked-sentry-patch"
HA_OIDC_COMPONENT_DEFAULT_URL="https://codeload.github.com/christiaangoossens/hass-oidc-auth/tar.gz/refs/tags/${HA_OIDC_COMPONENT_VERSION}"
HA_OIDC_COMPONENT_SOURCE_URL="${HA_OIDC_COMPONENT_URL:-${HA_OIDC_COMPONENT_DEFAULT_URL}}"
HA_OIDC_COMPONENT_DEFAULT_PATCH_FILE="${PROJECT_ROOT}/patches/hass-oidc-auth-subject-link.patch"
HA_OIDC_FRONTEND_OVERRIDE_ROOT="${PROJECT_ROOT}/homeassistant/auth_oidc/static"
HA_OIDC_BRANDING_SOURCE_ROOT="${HA_OIDC_BRANDING_SOURCE_ROOT:-${HA_OIDC_FRONTEND_OVERRIDE_ROOT}}"

if [[ -z "${HA_OIDC_COMPONENT_PATCH_FILE}" && -f "${HA_OIDC_COMPONENT_DEFAULT_PATCH_FILE}" ]]; then
  HA_OIDC_COMPONENT_PATCH_FILE="${HA_OIDC_COMPONENT_DEFAULT_PATCH_FILE}"
elif [[ -n "${HA_OIDC_COMPONENT_PATCH_FILE}" && "${HA_OIDC_COMPONENT_PATCH_FILE}" != /* ]]; then
  HA_OIDC_COMPONENT_PATCH_FILE="${PROJECT_ROOT}/${HA_OIDC_COMPONENT_PATCH_FILE}"
fi

if [[ -n "${HA_OIDC_COMPONENT_PATCH_FILE}" ]]; then
  [[ -f "${HA_OIDC_COMPONENT_PATCH_FILE}" ]] || fail "Home Assistant OIDC patch file is missing: ${HA_OIDC_COMPONENT_PATCH_FILE}"
fi

stack_compose_cmd() {
  docker compose --env-file "${STACK_ROOT}/.env" -f "${STACK_ROOT}/compose.yaml" "$@"
}

restart_homeassistant() {
  if ! stack_compose_cmd restart homeassistant >/dev/null 2>&1; then
    stack_compose_cmd up -d homeassistant >/dev/null
  fi
}

sync_auth_oidc_frontend_overrides() {
  local source_dir="${HA_OIDC_FRONTEND_OVERRIDE_ROOT}"
  local target_dir="${HA_OIDC_COMPONENT_DIR}/static"
  local branding_source_dir="${HA_OIDC_BRANDING_SOURCE_ROOT}"
  local injection_source="${source_dir}/injection.js"
  local injection_target="${target_dir}/injection.js"
  local branding_module_source="${source_dir}/ha-branding-overrides.js"
  local branding_module_target="${target_dir}/ha-branding-overrides.js"
  local injected_auth_page="${HA_OIDC_COMPONENT_DIR}/endpoints/injected_auth_page.py"
  local changed_any="false"
  local bumped_version="unchanged"

  if [[ ! -d "${target_dir}" ]]; then
    fail "Home Assistant auth_oidc static directory is missing: ${target_dir}"
  fi

  if [[ -f "${injection_source}" ]]; then
    if [[ ! -f "${injection_target}" ]] || ! cmp -s "${injection_source}" "${injection_target}"; then
      install -m 0644 "${injection_source}" "${injection_target}"
      changed_any="true"
      log "Applied local Home Assistant auth_oidc injection override from ${injection_source}."
    else
      log "Home Assistant auth_oidc injection override already matches ${injection_source}."
    fi
  else
    log "No local auth_oidc injection override found at ${injection_source}; skipping."
  fi

  if [[ -f "${branding_module_source}" ]]; then
    if [[ ! -f "${branding_module_target}" ]] || ! cmp -s "${branding_module_source}" "${branding_module_target}"; then
      install -m 0644 "${branding_module_source}" "${branding_module_target}"
      changed_any="true"
      log "Applied local Home Assistant auth branding module from ${branding_module_source}."
    else
      log "Home Assistant auth branding module already matches ${branding_module_source}."
    fi
  else
    log "No local Home Assistant auth branding module found at ${branding_module_source}; skipping."
  fi

  local auth_branding_files=(
    "${branding_source_dir}/favicon-32.png:${target_dir}/favicon-32.png"
    "${branding_source_dir}/favicon-192.png:${target_dir}/favicon-192.png"
    "${branding_source_dir}/favicon-192.png:${target_dir}/logo.png"
    "${branding_source_dir}/auth-logo-light.svg:${target_dir}/logo.svg"
    "${branding_source_dir}/auth-logo-light.svg:${target_dir}/logo-light.svg"
    "${branding_source_dir}/auth-logo-dark.svg:${target_dir}/logo-dark.svg"
  )
  local spec=""
  for spec in "${auth_branding_files[@]}"; do
    local source_file="${spec%%:*}"
    local target_file="${spec#*:}"

    if [[ ! -f "${source_file}" ]]; then
      log "No auth branding asset found at ${source_file}; skipping."
      continue
    fi

    if [[ ! -f "${target_file}" ]] || ! cmp -s "${source_file}" "${target_file}"; then
      install -m 0644 "${source_file}" "${target_file}"
      changed_any="true"
      log "Synced Home Assistant auth branding asset ${target_file##*/} from ${source_file}."
    fi
  done

  if [[ -f "${injected_auth_page}" ]]; then
    bumped_version="$(
      python3 - "${injected_auth_page}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = re.sub(r"injection\.js\?v=\d+", "injection.js?v=12", text)
updated = re.sub(r"ha-branding-overrides\.js\?v=\d+", "ha-branding-overrides.js?v=1", updated)

if updated != text:
    path.write_text(updated, encoding="utf-8")
    print("changed")
else:
    print("unchanged")
PY
    )"

    if [[ "${bumped_version}" == "changed" ]]; then
      changed_any="true"
      log "Updated auth_oidc injection asset version in ${injected_auth_page}."
    fi
  fi

  [[ "${changed_any}" == "true" ]]
}

install_auth_oidc_component() {
  local archive backup_dir checkout_dir installed_patch installed_source installed_version patch_fingerprint source_dir tmpdir

  install -d -m 0750 "${HA_OIDC_COMPONENT_PARENT}"

  installed_version=""
  installed_source=""
  installed_patch=""
  patch_fingerprint=""
  [[ -f "${HA_OIDC_COMPONENT_VERSION_FILE}" ]] && installed_version="$(tr -d '\r\n' < "${HA_OIDC_COMPONENT_VERSION_FILE}")"
  [[ -f "${HA_OIDC_COMPONENT_SOURCE_FILE}" ]] && installed_source="$(tr -d '\r\n' < "${HA_OIDC_COMPONENT_SOURCE_FILE}")"
  [[ -f "${HA_OIDC_COMPONENT_PATCH_FINGERPRINT_FILE}" ]] && installed_patch="$(tr -d '\r\n' < "${HA_OIDC_COMPONENT_PATCH_FINGERPRINT_FILE}")"
  [[ -n "${HA_OIDC_COMPONENT_PATCH_FILE}" ]] && patch_fingerprint="$(sha256sum "${HA_OIDC_COMPONENT_PATCH_FILE}" | awk '{print $1}')"

  if [[ "${installed_version}" == "${HA_OIDC_COMPONENT_VERSION}" ]]; then
    if [[ "${installed_source}" == "${HA_OIDC_COMPONENT_SOURCE_URL}" && "${installed_patch}" == "${patch_fingerprint}" ]]; then
      if [[ -n "${patch_fingerprint}" ]]; then
        log "Home Assistant auth_oidc component already matches ${HA_OIDC_COMPONENT_VERSION} from ${HA_OIDC_COMPONENT_SOURCE_URL} with patch ${HA_OIDC_COMPONENT_PATCH_FILE}."
      else
        log "Home Assistant auth_oidc component already matches ${HA_OIDC_COMPONENT_VERSION} from ${HA_OIDC_COMPONENT_SOURCE_URL}."
      fi
      return 1
    fi
    if [[ -z "${installed_source}" && "${HA_OIDC_COMPONENT_SOURCE_URL}" == "${HA_OIDC_COMPONENT_DEFAULT_URL}" && -z "${installed_patch}" && -z "${patch_fingerprint}" ]]; then
      log "Home Assistant auth_oidc component already matches ${HA_OIDC_COMPONENT_VERSION}."
      return 1
    fi
  fi

  archive="$(mktemp)"
  tmpdir="$(mktemp -d)"
  log "Downloading hass-oidc-auth ${HA_OIDC_COMPONENT_VERSION} from ${HA_OIDC_COMPONENT_SOURCE_URL}."
  curl -fsSL "${HA_OIDC_COMPONENT_SOURCE_URL}" -o "${archive}"
  tar -xzf "${archive}" -C "${tmpdir}"

  checkout_dir="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "${checkout_dir}" && -d "${checkout_dir}" ]] || fail "Downloaded hass-oidc-auth archive does not contain a top-level directory."

  if [[ -n "${HA_OIDC_COMPONENT_PATCH_FILE}" ]]; then
    log "Applying local Home Assistant auth_oidc patch ${HA_OIDC_COMPONENT_PATCH_FILE}."
    patch -p1 -d "${checkout_dir}" < "${HA_OIDC_COMPONENT_PATCH_FILE}"
  fi

  source_dir="$(find "${tmpdir}" -type d -path '*/custom_components/auth_oidc' | head -n1)"
  [[ -d "${source_dir}" ]] || fail "Downloaded hass-oidc-auth archive does not contain custom_components/auth_oidc."

  if [[ -d "${HA_OIDC_COMPONENT_DIR}" ]]; then
    backup_dir="${HA_OIDC_COMPONENT_PARENT}/auth_oidc.pre-crooked-sentry-$(date '+%Y%m%d%H%M%S')"
    mv "${HA_OIDC_COMPONENT_DIR}" "${backup_dir}"
    log "Backed up existing Home Assistant auth_oidc component to ${backup_dir}."
  fi

  cp -R "${source_dir}" "${HA_OIDC_COMPONENT_DIR}"
  printf '%s\n' "${HA_OIDC_COMPONENT_VERSION}" > "${HA_OIDC_COMPONENT_VERSION_FILE}"
  printf '%s\n' "${HA_OIDC_COMPONENT_SOURCE_URL}" > "${HA_OIDC_COMPONENT_SOURCE_FILE}"
  chmod 0640 "${HA_OIDC_COMPONENT_VERSION_FILE}"
  chmod 0640 "${HA_OIDC_COMPONENT_SOURCE_FILE}"
  if [[ -n "${patch_fingerprint}" ]]; then
    printf '%s\n' "${patch_fingerprint}" > "${HA_OIDC_COMPONENT_PATCH_FINGERPRINT_FILE}"
    chmod 0640 "${HA_OIDC_COMPONENT_PATCH_FINGERPRINT_FILE}"
  else
    rm -f "${HA_OIDC_COMPONENT_PATCH_FINGERPRINT_FILE}"
  fi
  rm -rf "${tmpdir}" "${archive}"
  if [[ -n "${HA_OIDC_COMPONENT_PATCH_FILE}" ]]; then
    log "Installed Home Assistant auth_oidc component ${HA_OIDC_COMPONENT_VERSION} from ${HA_OIDC_COMPONENT_SOURCE_URL} with patch ${HA_OIDC_COMPONENT_PATCH_FILE}."
  else
    log "Installed Home Assistant auth_oidc component ${HA_OIDC_COMPONENT_VERSION} from ${HA_OIDC_COMPONENT_SOURCE_URL}."
  fi
  return 0
}

update_oidc_secret() {
  if ! require_soft_var HA_OIDC_CLIENT_SECRET; then
    log "HA_OIDC_CLIENT_SECRET is not set. Using Home Assistant auth_oidc public-client mode."
    return 1
  fi

  local result=""
  result="$(
    HA_SECRETS_FILE="${HA_SECRETS_FILE}" HA_OIDC_CLIENT_SECRET="${HA_OIDC_CLIENT_SECRET}" python3 - <<'PY'
import os
import yaml

path = os.environ["HA_SECRETS_FILE"]
value = os.environ["HA_OIDC_CLIENT_SECRET"]

data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle)
    if loaded is None:
        loaded = {}
    if not isinstance(loaded, dict):
        raise SystemExit("Home Assistant secrets.yaml must contain a YAML mapping at the top level")
    data = loaded

if data.get("ha_oidc_client_secret") == value:
    print("unchanged")
    raise SystemExit(0)

data["ha_oidc_client_secret"] = value
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=True)
print("changed")
PY
  )"

  case "${result}" in
    changed)
      log "Updated Home Assistant OIDC client secret in ${HA_SECRETS_FILE}."
      return 0
      ;;
    unchanged)
      log "Home Assistant OIDC client secret already matches the desired value."
      return 1
      ;;
    *)
      fail "Unexpected Home Assistant OIDC secret result: ${result}"
      ;;
  esac
}

ensure_homeassistant_oidc_config() {
  [[ -f "${HA_CONFIG_FILE}" ]] || fail "Home Assistant configuration file is missing: ${HA_CONFIG_FILE}"

  local result
  result="$(
    HA_CONFIG_FILE="${HA_CONFIG_FILE}" \
    HA_CONFIG_BACKUP_FILE="${HA_CONFIG_BACKUP_FILE}" \
    HA_OIDC_CLIENT_ID="${HA_OIDC_CLIENT_ID}" \
    HA_OIDC_DISCOVERY_URL="${HA_OIDC_DISCOVERY_URL}" \
    HA_OIDC_DISPLAY_NAME="${HA_OIDC_DISPLAY_NAME}" \
    HA_OIDC_USERNAME_CLAIM="${HA_OIDC_USERNAME_CLAIM}" \
    HA_OIDC_DISPLAY_NAME_CLAIM="${HA_OIDC_DISPLAY_NAME_CLAIM}" \
    HA_OIDC_GROUPS_CLAIM="${HA_OIDC_GROUPS_CLAIM}" \
    HA_OIDC_EMAIL_CLAIM="${HA_OIDC_EMAIL_CLAIM}" \
    HA_OIDC_GROUPS_SCOPE="${HA_OIDC_GROUPS_SCOPE}" \
    HA_OIDC_ADDITIONAL_SCOPES="${HA_OIDC_ADDITIONAL_SCOPES}" \
    HA_OIDC_BRANDING_JSON="${HA_OIDC_BRANDING_JSON}" \
    HA_OIDC_AUTOMATIC_USER_LINKING="${HA_OIDC_AUTOMATIC_USER_LINKING}" \
    HA_OIDC_BOOTSTRAP_VERIFIED_EMAIL_ONCE="${HA_OIDC_BOOTSTRAP_VERIFIED_EMAIL_ONCE}" \
    HA_OIDC_INCLUDE_GROUPS_SCOPE="${HA_OIDC_INCLUDE_GROUPS_SCOPE}" \
    HA_OIDC_DISABLE_FRONTEND_CHANGES="${HA_OIDC_DISABLE_FRONTEND_CHANGES}" \
    HA_OIDC_FORCE_HTTPS="${HA_OIDC_FORCE_HTTPS}" \
    HA_OIDC_USER_ROLE_GROUP="${HA_OIDC_USER_ROLE_GROUP}" \
    HA_OIDC_ADMIN_ROLE_GROUP="${HA_OIDC_ADMIN_ROLE_GROUP}" \
    HA_OIDC_USE_CLIENT_SECRET="$([ -n "${HA_OIDC_CLIENT_SECRET:-}" ] && [[ "${HA_OIDC_CLIENT_SECRET}" != "change-me" ]] && printf 'true' || printf 'false')" \
    python3 - <<'PY'
import copy
import json
import os
import shutil
import yaml


def env_bool(key, default=False):
    value = os.environ.get(key)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def env_present(key):
    value = os.environ.get(key)
    return value is not None and value != ""


def split_scopes(value):
    scopes = []
    for raw in (value or "").replace(",", " ").split():
        cleaned = raw.strip()
        if cleaned and cleaned not in scopes:
            scopes.append(cleaned)
    return scopes


def env_json_object(key):
    raw = os.environ.get(key)
    if raw is None or raw.strip() == "":
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{key} must be valid JSON: {exc}")
    if not isinstance(value, dict):
        raise SystemExit(f"{key} must decode to a JSON object")
    return value


class TaggedScalar(str):
    yaml_tag = None


class TaggedSequence(list):
    yaml_tag = None


class TaggedMapping(dict):
    yaml_tag = None


class PreserveTagLoader(yaml.SafeLoader):
    pass


class PreserveTagDumper(yaml.SafeDumper):
    pass


def construct_undefined(loader, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
        wrapped = TaggedScalar(value)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
        wrapped = TaggedSequence(value)
    elif isinstance(node, yaml.MappingNode):
        value = loader.construct_mapping(node)
        wrapped = TaggedMapping(value)
    else:
        raise TypeError(f"Unsupported YAML node type: {type(node)!r}")
    wrapped.yaml_tag = node.tag
    return wrapped


def represent_tagged_scalar(dumper, data):
    return dumper.represent_scalar(data.yaml_tag, str(data))


def represent_tagged_sequence(dumper, data):
    return dumper.represent_sequence(data.yaml_tag, list(data))


def represent_tagged_mapping(dumper, data):
    return dumper.represent_mapping(data.yaml_tag, dict(data))


PreserveTagLoader.add_constructor(None, construct_undefined)
PreserveTagDumper.add_representer(TaggedScalar, represent_tagged_scalar)
PreserveTagDumper.add_representer(TaggedSequence, represent_tagged_sequence)
PreserveTagDumper.add_representer(TaggedMapping, represent_tagged_mapping)

cfg_path = os.environ["HA_CONFIG_FILE"]
backup_path = os.environ["HA_CONFIG_BACKUP_FILE"]

with open(cfg_path, "r", encoding="utf-8") as handle:
    loaded = yaml.load(handle, Loader=PreserveTagLoader)

if loaded is None:
    loaded = {}
if not isinstance(loaded, dict):
    raise SystemExit("Home Assistant configuration.yaml must contain a YAML mapping at the top level")

doc = copy.deepcopy(loaded)
desired = {
    "client_id": os.environ["HA_OIDC_CLIENT_ID"],
    "discovery_url": os.environ["HA_OIDC_DISCOVERY_URL"],
    "display_name": os.environ["HA_OIDC_DISPLAY_NAME"],
    "groups_scope": os.environ["HA_OIDC_GROUPS_SCOPE"],
    "features": {
        "automatic_user_linking": env_bool("HA_OIDC_AUTOMATIC_USER_LINKING"),
        "include_groups_scope": env_bool("HA_OIDC_INCLUDE_GROUPS_SCOPE", True),
        "disable_frontend_changes": env_bool("HA_OIDC_DISABLE_FRONTEND_CHANGES"),
        "force_https": env_bool("HA_OIDC_FORCE_HTTPS"),
    },
    "claims": {
        "display_name": os.environ["HA_OIDC_DISPLAY_NAME_CLAIM"],
        "username": os.environ["HA_OIDC_USERNAME_CLAIM"],
        "groups": os.environ["HA_OIDC_GROUPS_CLAIM"],
    },
}

if env_present("HA_OIDC_EMAIL_CLAIM"):
    desired["claims"]["email"] = os.environ["HA_OIDC_EMAIL_CLAIM"]

if env_present("HA_OIDC_BOOTSTRAP_VERIFIED_EMAIL_ONCE"):
    desired["features"]["bootstrap_verified_email_once"] = env_bool(
        "HA_OIDC_BOOTSTRAP_VERIFIED_EMAIL_ONCE"
    )

additional_scopes = split_scopes(os.environ.get("HA_OIDC_ADDITIONAL_SCOPES", ""))
if additional_scopes:
    desired["additional_scopes"] = additional_scopes

branding = env_json_object("HA_OIDC_BRANDING_JSON")
if branding:
    desired["branding"] = branding

roles = {}
if os.environ.get("HA_OIDC_USER_ROLE_GROUP"):
    roles["user"] = os.environ["HA_OIDC_USER_ROLE_GROUP"]
if os.environ.get("HA_OIDC_ADMIN_ROLE_GROUP"):
    roles["admin"] = os.environ["HA_OIDC_ADMIN_ROLE_GROUP"]
if roles:
    desired["roles"] = roles

if env_bool("HA_OIDC_USE_CLIENT_SECRET"):
    secret_ref = TaggedScalar("ha_oidc_client_secret")
    secret_ref.yaml_tag = "!secret"
    desired["client_secret"] = secret_ref

changed = doc.get("auth_oidc") != desired
if changed:
    doc["auth_oidc"] = desired
    if not os.path.exists(backup_path):
      shutil.copy2(cfg_path, backup_path)
    with open(cfg_path, "w", encoding="utf-8") as handle:
        yaml.dump(doc, handle, Dumper=PreserveTagDumper, sort_keys=False)
    print("changed")
else:
    print("unchanged")
PY
  )"

  case "${result}" in
    changed)
      log "Updated Home Assistant auth_oidc configuration in ${HA_CONFIG_FILE}."
      return 0
      ;;
    unchanged)
      log "Home Assistant auth_oidc configuration already matches the desired state."
      return 1
      ;;
    *)
      fail "Unexpected Home Assistant auth_oidc config result: ${result}"
      ;;
  esac
}

wait_for_oidc_route() {
  local deadline=$((SECONDS + 180))
  local status=""
  while (( SECONDS < deadline )); do
    status="$(curl -ksS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HA_PORT}/auth/oidc/welcome" || true)"
    case "${status}" in
      200|302|303|307|308)
        log "Home Assistant OIDC welcome route is reachable (HTTP ${status})."
        return 0
        ;;
    esac
    sleep 3
  done
  fail "Home Assistant OIDC welcome route did not become reachable within 180s."
}

main() {
  log "===== crooked-sentry Home Assistant OIDC converge starting ====="

  local changed_component="false"
  local changed_secret="false"
  local changed_config="false"
  local changed_frontend="false"

  install_auth_oidc_component && changed_component="true" || true
  sync_auth_oidc_frontend_overrides && changed_frontend="true" || true
  update_oidc_secret && changed_secret="true" || true
  ensure_homeassistant_oidc_config && changed_config="true" || true

  if [[ "${changed_component}" == "true" || "${changed_frontend}" == "true" || "${changed_secret}" == "true" || "${changed_config}" == "true" ]]; then
    restart_homeassistant
    log "Restarted Home Assistant to apply OIDC changes."
  else
    log "Home Assistant OIDC state already matches the desired configuration."
  fi

  wait_for_oidc_route
  log "OIDC quick-start URL: /auth/oidc/redirect"
  warn "This uses the unofficial hass-oidc-auth component. Keep at least one local Home Assistant owner account as a fallback."
  log "===== crooked-sentry Home Assistant OIDC converge completed successfully ====="
}

main "$@"
