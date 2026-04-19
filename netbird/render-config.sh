#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETBIRD_DIR="${NETBIRD_DIR:-${ROOT_DIR}/netbird}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
GENERATED_DIR="${GENERATED_DIR:-${NETBIRD_DIR}/generated}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${NETBIRD_DIR}/templates}"

[[ -f "${ENV_FILE}" ]] || {
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
}

set -o allexport
source "${ENV_FILE}"
set +o allexport

json_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) printf 'true\n' ;;
    0|false|FALSE|no|NO|off|OFF) printf 'false\n' ;;
    *)
      echo "Expected boolean value, got: ${1:-<empty>}" >&2
      exit 1
      ;;
  esac
}

require_var() {
  local key="$1"
  local value="${!key:-}"
  if [[ -z "${value}" || "${value}" == "change-me" ]]; then
    echo "Missing required variable ${key} in ${ENV_FILE}" >&2
    exit 1
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
  NETBIRD_TURN_USER \
  NETBIRD_TURN_PASSWORD \
  NETBIRD_TURN_SECRET \
  NETBIRD_RELAY_AUTH_SECRET \
  NETBIRD_DATASTORE_ENC_KEY
do
  require_var "${key}"
done

NETBIRD_REVERSE_PROXY_ENABLED="${NETBIRD_REVERSE_PROXY_ENABLED:-false}"

export NETBIRD_MGMT_DISABLE_DEFAULT_POLICY_JSON
NETBIRD_MGMT_DISABLE_DEFAULT_POLICY_JSON="$(json_bool "${NETBIRD_MGMT_DISABLE_DEFAULT_POLICY:-true}")"
export NETBIRD_LOCAL_AUTH_DISABLED_JSON
NETBIRD_LOCAL_AUTH_DISABLED_JSON="$(json_bool "${NETBIRD_LOCAL_AUTH_DISABLED:-false}")"

mkdir -p "${GENERATED_DIR}"

python3 - "${TEMPLATE_DIR}" "${GENERATED_DIR}" <<'PY'
import os
import pathlib
import sys
from string import Template

template_dir = pathlib.Path(sys.argv[1])
generated_dir = pathlib.Path(sys.argv[2])

targets = {
    "management.json.tmpl": "management.json",
    "turnserver.conf.tmpl": "turnserver.conf",
    "dashboard-default.conf.tmpl": "dashboard-default.conf"
}

for source_name, target_name in targets.items():
    source = template_dir / source_name
    target = generated_dir / target_name
    rendered = Template(source.read_text(encoding="utf-8")).substitute(os.environ)
    target.write_text(rendered + ("\n" if not rendered.endswith("\n") else ""), encoding="utf-8")
    print(f"rendered {target}")

if os.environ.get("NETBIRD_REVERSE_PROXY_ENABLED", "").lower() in {"1", "true", "yes", "on"}:
    proxy_domain = os.environ.get("NETBIRD_PROXY_DOMAIN", "")
    proxy_token = os.environ.get("NETBIRD_PROXY_TOKEN", "")
    if proxy_domain and proxy_token and proxy_token != "change-me":
        source = template_dir / "proxy.env.tmpl"
        target = generated_dir / "proxy.env"
        rendered = Template(source.read_text(encoding="utf-8")).substitute(os.environ)
        target.write_text(rendered + ("\n" if not rendered.endswith("\n") else ""), encoding="utf-8")
        print(f"rendered {target}")
    else:
        target = generated_dir / "proxy.env"
        if target.exists():
            target.unlink()
            print(f"removed stale {target}")
else:
    target = generated_dir / "proxy.env"
    if target.exists():
        target.unlink()
        print(f"removed stale {target}")
PY
