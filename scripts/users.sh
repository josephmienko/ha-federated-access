#!/usr/bin/env bash
# Convenience wrapper for users-cli.py
# Automatically sources .env and sets up environment

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

# Load environment if it exists
if [[ -f "${ENV_FILE}" ]]; then
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
fi

# Run Python CLI with any arguments passed
exec python3 "${SCRIPT_DIR}/users-cli.py" "$@"
