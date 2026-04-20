#!/usr/bin/env bash
# Verify user management CLI configuration
# Check that all required environment variables are set

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config.yaml}"
CONFIG_LIB="${SCRIPT_DIR}/lib/config.sh"
[[ -f "${CONFIG_LIB}" ]] || { echo "Missing config library: ${CONFIG_LIB}"; exit 1; }
source "${CONFIG_LIB}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  User Management CLI - Configuration Verification  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
echo

if [[ ! -f "${ENV_FILE}" ]]; then
    echo -e "${RED}✗ .env file not found at: ${ENV_FILE}${NC}"
    exit 1
fi
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${RED}✗ config.yaml file not found at: ${CONFIG_FILE}${NC}"
    exit 1
fi

# Load environment
set -o allexport
source "${ENV_FILE}"
set +o allexport

NETBIRD_STACK_ROOT="${NETBIRD_STACK_ROOT:-$(config_first "/opt/ha-federated-access/netbird" netbird.stack_root)}"
NETBIRD_COMPOSE_FILE="${NETBIRD_COMPOSE_FILE:-$(config_first "${NETBIRD_STACK_ROOT}/docker-compose.yaml" netbird.compose_file)}"
NETBIRD_COMPOSE_ENV_FILE="${NETBIRD_COMPOSE_ENV_FILE:-$(config_first "${NETBIRD_STACK_ROOT}/.env" netbird.compose_env_file)}"
HA_PORT="${HA_PORT:-$(config_first "8123" homeassistant.port stage2.homeassistant.port)}"

check_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    local is_required="${2:-false}"
    
    if [[ -n "${var_value}" ]]; then
        local display_value="${var_value}"
        if [[ ${#var_value} -gt 40 ]]; then
            display_value="${var_value:0:40}..."
        fi
        echo -e "${GREEN}✓${NC} ${var_name} = ${display_value}"
        return 0
    else
        if [[ "${is_required}" == "true" ]]; then
            echo -e "${RED}✗${NC} ${var_name} (REQUIRED - NOT SET)"
            return 1
        else
            echo -e "${YELLOW}○${NC} ${var_name} (optional, using default)"
            return 0
        fi
    fi
}

echo -e "${BLUE}NetBird Configuration:${NC}"
check_var "NETBIRD_DOMAIN" false
check_var "NETBIRD_MGMT_API_PORT" false
check_var "NETBIRD_API_TOKEN" true || true
echo

echo -e "${BLUE}Authentik Configuration:${NC}"
check_var "AUTHENTIK_ENABLED" false
check_var "AUTHENTIK_DOMAIN" false
echo

echo -e "${BLUE}Home Assistant Configuration:${NC}"
check_var "HA_PORT" false
check_var "HA_TOKEN" true || true
echo

# Check if required tokens are set
MISSING_TOKENS=0

if [[ -z "${NETBIRD_API_TOKEN:-}" ]]; then
    echo -e "${RED}✗ NETBIRD_API_TOKEN not set${NC}"
    echo -e "  Get from: NetBird Dashboard → Settings → API Keys → Create (select 'Users' scope)"
    ((MISSING_TOKENS++))
else
    echo -e "${GREEN}✓ NETBIRD_API_TOKEN is set${NC}"
fi

if [[ -z "${HA_TOKEN:-}" ]]; then
    echo -e "${RED}✗ HA_TOKEN not set${NC}"
    echo -e "  Get from: Home Assistant UI → Profile (bottom left) → Long-Lived Tokens → Create"
    ((MISSING_TOKENS++))
else
    echo -e "${GREEN}✓ HA_TOKEN is set${NC}"
fi

echo

# Test connectivity
echo -e "${BLUE}Testing API Connectivity:${NC}"

# Test NetBird
if [[ -n "${NETBIRD_API_TOKEN:-}" ]]; then
    if curl -s -H "Authorization: Token ${NETBIRD_API_TOKEN}" \
        "http://localhost:${NETBIRD_MGMT_API_PORT:-33073}/api/instance" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ NetBird API responding${NC}"
    else
        echo -e "${YELLOW}! NetBird API not responding (may be starting)${NC}"
    fi
else
    echo -e "${YELLOW}○ NetBird API test skipped (token not set)${NC}"
fi

# Test Home Assistant
if [[ -n "${HA_TOKEN:-}" ]]; then
    if curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
        "http://localhost:${HA_PORT:-8123}/api/" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Home Assistant API responding${NC}"
    else
        echo -e "${YELLOW}! Home Assistant API not responding (may be starting)${NC}"
    fi
else
    echo -e "${YELLOW}○ Home Assistant API test skipped (token not set)${NC}"
fi

# Test Authentik
if docker ps 2>/dev/null | grep -q "authentik-server"; then
    if docker compose --env-file "${NETBIRD_COMPOSE_ENV_FILE}" -f "${NETBIRD_COMPOSE_FILE}" \
        --profile authentik exec -T authentik-server ak shell <<< "from authentik.core.models import User; print('OK')" \
        >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Authentik Django shell responding${NC}"
    else
        echo -e "${YELLOW}! Authentik shell not ready${NC}"
    fi
else
    echo -e "${YELLOW}○ Authentik containers not running${NC}"
fi

echo

if [[ ${MISSING_TOKENS} -eq 0 ]]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ All required configuration is set!              ║${NC}"
    echo -e "${GREEN}║  You can now use: ./scripts/users.sh list          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗ Missing ${MISSING_TOKENS} required variable(s)                    ║${NC}"
    echo -e "${RED}║  See above for details on how to get tokens        ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
