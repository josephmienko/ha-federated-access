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
  apt-get install -y python3 python3-yaml ca-certificates curl jq
}

require_root
require_config
install_base_deps

LOG_DIR="$(yaml_get system.log_dir)"
LOG_FILE="${LOG_DIR}/converge-netbird-browser-access.log"
NETBIRD_ENABLED="$(yaml_get netbird.enabled)"
NETBIRD_STACK_ROOT="$(yaml_get netbird.stack_root)"
NETBIRD_SERVICE_NAME="$(yaml_get netbird.compose_service_name)"
STACK_ROOT="$(yaml_get stage2.stack_root)"
STACK_COMPOSE_SERVICE_NAME="$(yaml_get stage2.docker.compose_service_name)"
HA_CONFIG_DIR="$(yaml_get stage2.homeassistant.config_dir)"
HA_PORT="$(yaml_get stage2.homeassistant.port)"
RUNTIME_PEER_ENV="${NETBIRD_STACK_ROOT}/generated/peer.env"
HA_CONFIG_FILE="${HA_CONFIG_DIR}/configuration.yaml"
HA_PROXY_BACKUP_FILE="${HA_CONFIG_DIR}/configuration.yaml.pre-netbird-browser-access.bak"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "NetBird browser-access converge aborted at line $LINENO."' ERR

[[ "${NETBIRD_ENABLED}" == "true" ]] || {
  log "NetBird is disabled in config.yaml. Nothing to do."
  exit 0
}

load_env_file

NETBIRD_REVERSE_PROXY_ENABLED="${NETBIRD_REVERSE_PROXY_ENABLED:-false}"
NETBIRD_HA_PROXY_ENABLED="${NETBIRD_HA_PROXY_ENABLED:-false}"
NETBIRD_HA_PROXY_SUBDOMAIN="${NETBIRD_HA_PROXY_SUBDOMAIN:-ha}"
NETBIRD_PI_PEER_NAME="${NETBIRD_PI_PEER_NAME:-$(hostname -s)-pi}"
NETBIRD_BROWSER_API_BASE_URL="${NETBIRD_BROWSER_API_BASE_URL:-http://127.0.0.1:${NETBIRD_MGMT_API_PORT:-33073}/api}"
HA_PROXY_DOMAIN="${NETBIRD_HA_PROXY_SUBDOMAIN}.${NETBIRD_PROXY_DOMAIN:-proxy.invalid}"
PEER_SETUP_KEY_NAME="${PEER_SETUP_KEY_NAME:-ha-federated-access-pi-peer-bootstrap}"

[[ "${NETBIRD_HA_PROXY_ENABLED}" == "true" ]] || {
  log "NETBIRD_HA_PROXY_ENABLED is not true. Skipping browser-access convergence."
  exit 0
}

[[ "${NETBIRD_REVERSE_PROXY_ENABLED}" == "true" ]] || fail "NETBIRD_HA_PROXY_ENABLED=true requires NETBIRD_REVERSE_PROXY_ENABLED=true"

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_soft_var() {
  local key="$1"
  local value="${!key:-}"
  [[ -n "${value}" && "${value}" != "change-me" ]]
}

compose_cmd() {
  docker compose --env-file "${NETBIRD_STACK_ROOT}/.env" -f "${NETBIRD_STACK_ROOT}/docker-compose.yaml" "$@"
}

stack_compose_cmd() {
  docker compose --env-file "${STACK_ROOT}/.env" -f "${STACK_ROOT}/compose.yaml" "$@"
}

api_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url="${NETBIRD_BROWSER_API_BASE_URL%/}/${path#/}"
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

delete_old_setup_keys() {
  local keys_json ids_csv
  keys_json="$(api_request GET "setup-keys")"
  ids_csv="$(
    KEYS_JSON="${keys_json}" KEY_NAME="${PEER_SETUP_KEY_NAME}" python3 - <<'PY'
import json
import os

keys = json.loads(os.environ["KEYS_JSON"])
name = os.environ["KEY_NAME"]
ids = [item.get("id", "") for item in keys if item.get("name") == name]
print(",".join([i for i in ids if i]))
PY
  )"

  [[ -n "${ids_csv}" ]] || return 0

  local id
  IFS=',' read -r -a key_ids <<< "${ids_csv}"
  for id in "${key_ids[@]}"; do
    api_request DELETE "setup-keys/${id}" >/dev/null || true
  done
}

create_one_off_setup_key() {
  delete_old_setup_keys
  local payload
  payload="$(
    jq -nc \
      --arg name "${PEER_SETUP_KEY_NAME}" \
      '{name:$name,type:"one-off",usage_limit:1,ephemeral:false,auto_groups:[]}'
  )"
  api_request POST "setup-keys" "${payload}"
}

write_runtime_peer_env() {
  local setup_key="$1"
  install -d -m 0750 "$(dirname "${RUNTIME_PEER_ENV}")"
  cat > "${RUNTIME_PEER_ENV}" <<EOF
NB_SETUP_KEY=${setup_key}
NB_MANAGEMENT_URL=http://127.0.0.1:${NETBIRD_MGMT_API_PORT}
NB_DISABLE_DNS=true
NB_LOG_LEVEL=info
EOF
  chmod 0600 "${RUNTIME_PEER_ENV}"
}

ensure_peer_runtime() {
  local key_json setup_key
  key_json="$(create_one_off_setup_key)"
  setup_key="$(printf '%s\n' "${key_json}" | jq -r '.key')"
  [[ -n "${setup_key}" && "${setup_key}" != "null" ]] || fail "NetBird API did not return a usable setup key"

  write_runtime_peer_env "${setup_key}"
  compose_cmd --profile browser-access up -d --force-recreate peer

  local deadline=$((SECONDS + 90))
  local status_json=""
  while (( SECONDS < deadline )); do
    if status_json="$(compose_cmd --profile browser-access exec -T peer netbird status --json 2>/dev/null || true)" && [[ -n "${status_json}" ]]; then
      STATUS_JSON="${status_json}" python3 - <<'PY' >/dev/null 2>&1
import json
import os
json.loads(os.environ["STATUS_JSON"])
PY
      if [[ $? -eq 0 ]]; then
        log "NetBird peer container is responding to status checks."
        return 0
      fi
    fi
    sleep 3
  done

  fail "NetBird peer container did not report status within 90s"
}

wait_for_peer_id() {
  local deadline=$((SECONDS + 120))
  local peers_json peer_json
  while (( SECONDS < deadline )); do
    peers_json="$(api_request GET "peers")"
    peer_json="$(
      PEERS_JSON="${peers_json}" PEER_NAME="${NETBIRD_PI_PEER_NAME}" python3 - <<'PY'
import json
import os
import sys

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

if len(matches) != 1:
    sys.exit(1)

print(json.dumps(matches[0]))
PY
    )" || true

    if [[ -n "${peer_json}" ]]; then
      printf '%s\n' "${peer_json}"
      return 0
    fi
    sleep 3
  done

  return 1
}

ensure_homeassistant_proxy_trust() {
  [[ -f "${HA_CONFIG_FILE}" ]] || fail "Home Assistant config file is missing: ${HA_CONFIG_FILE}"

  local result
  result="$(
    HA_CONFIG_FILE="${HA_CONFIG_FILE}" HA_PROXY_BACKUP_FILE="${HA_PROXY_BACKUP_FILE}" python3 - <<'PY'
import copy
import os
import shutil
import yaml

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
backup_path = os.environ["HA_PROXY_BACKUP_FILE"]

with open(cfg_path, "r", encoding="utf-8") as handle:
    loaded = yaml.load(handle, Loader=PreserveTagLoader)

if loaded is None:
    loaded = {}
if not isinstance(loaded, dict):
    raise SystemExit("Home Assistant configuration.yaml must contain a YAML mapping at the top level")

doc = copy.deepcopy(loaded)
http_cfg = doc.get("http")
if http_cfg is None:
    http_cfg = {}
if not isinstance(http_cfg, dict):
    raise SystemExit("Home Assistant http configuration must be a mapping")

changed = False
if http_cfg.get("use_x_forwarded_for") is not True:
    http_cfg["use_x_forwarded_for"] = True
    changed = True

trusted = http_cfg.get("trusted_proxies")
if trusted is None:
    trusted = []
elif not isinstance(trusted, list):
    raise SystemExit("Home Assistant http.trusted_proxies must be a list")

trusted = [str(item) for item in trusted]
if "100.64.0.0/10" not in trusted:
    trusted.append("100.64.0.0/10")
    changed = True

http_cfg["trusted_proxies"] = trusted
doc["http"] = http_cfg

if changed:
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
      log "Updated Home Assistant trusted proxy settings for NetBird browser access."
      if ! stack_compose_cmd restart homeassistant >/dev/null 2>&1; then
        stack_compose_cmd up -d homeassistant >/dev/null
      fi
      log "Restarted Home Assistant to apply reverse-proxy trust settings."
      ;;
    unchanged)
      log "Home Assistant already trusts the NetBird browser-access proxy range."
      ;;
    *)
      fail "Unexpected Home Assistant proxy-trust result: ${result}"
      ;;
  esac
}

upsert_homeassistant_proxy_service() {
  local peer_id="$1"
  local payload services_json service_json existing_id action

  payload="$(
    jq -nc \
      --arg name "Home Assistant" \
      --arg domain "${HA_PROXY_DOMAIN}" \
      --arg peer_id "${peer_id}" \
      --arg port "${HA_PORT}" \
      '{
        name:$name,
        domain:$domain,
        enabled:true,
        rewrite_redirects:true,
        pass_host_header:true,
        auth:{bearer_auth:{enabled:true,distribution_groups:[]}},
        targets:[
          {
            target_id:$peer_id,
            target_type:"peer",
            host:"127.0.0.1",
            port:($port|tonumber),
            protocol:"http",
            path:"/",
            enabled:true
          }
        ]
      }'
  )"

  services_json="$(api_request GET "reverse-proxies/services")"
  existing_id="$(
    SERVICES_JSON="${services_json}" SERVICE_DOMAIN="${HA_PROXY_DOMAIN}" python3 - <<'PY'
import json
import os

services = json.loads(os.environ["SERVICES_JSON"])
domain = os.environ["SERVICE_DOMAIN"]
matching = [svc for svc in services if svc.get("domain") == domain]
if len(matching) > 1:
    raise SystemExit("multiple reverse proxy services already use the same domain")
if matching:
    print(matching[0]["id"])
PY
  )"

  if [[ -n "${existing_id}" ]]; then
    action="updated"
    service_json="$(api_request PUT "reverse-proxies/services/${existing_id}" "${payload}")"
  else
    action="created"
    service_json="$(api_request POST "reverse-proxies/services" "${payload}")"
  fi

  printf '%s\n' "${service_json}" | jq -e '.id and .domain and .targets' >/dev/null
  log "NetBird Home Assistant browser-access service ${action}: ${HA_PROXY_DOMAIN}"
}

wait_for_browser_access_url() {
  local deadline=$((SECONDS + 90))
  local code=""

  while (( SECONDS < deadline )); do
    code="$(
      curl -ksS -o /dev/null -w '%{http_code}' \
        --resolve "${HA_PROXY_DOMAIN}:443:127.0.0.1" \
        "https://${HA_PROXY_DOMAIN}/" || true
    )"
    case "${code}" in
      200|302|303|307|308|401|403)
        log "Home Assistant browser-access URL is responding via ${HA_PROXY_DOMAIN} (HTTP ${code})."
        return 0
        ;;
    esac
    sleep 3
  done

  fail "Home Assistant browser-access URL did not become reachable within 90s: https://${HA_PROXY_DOMAIN}/"
}

main() {
  log "===== ha-federated-access NetBird browser-access converge starting ====="
  require_command curl
  require_command jq
  require_command python3
  require_command docker

  if ! require_soft_var NETBIRD_API_TOKEN; then
    fail "NETBIRD_API_TOKEN is required to converge NetBird browser access"
  fi

  api_request GET "instance" >/dev/null
  log "NetBird management API is reachable via ${NETBIRD_BROWSER_API_BASE_URL}"

  ensure_peer_runtime

  local peer_json peer_id
  peer_json="$(wait_for_peer_id)" || fail "Unable to locate the Pi peer in NetBird after starting the peer container"
  peer_id="$(printf '%s\n' "${peer_json}" | jq -r '.id')"
  [[ -n "${peer_id}" && "${peer_id}" != "null" ]] || fail "Matched Pi peer did not include an id"
  log "Matched Pi peer ${NETBIRD_PI_PEER_NAME} (${peer_id})."

  ensure_homeassistant_proxy_trust
  upsert_homeassistant_proxy_service "${peer_id}"
  wait_for_browser_access_url

  log "===== ha-federated-access NetBird browser-access converge completed successfully ====="
}

main "$@"
