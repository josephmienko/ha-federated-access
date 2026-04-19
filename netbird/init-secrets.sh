#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"

[[ -f "${ENV_FILE}" ]] || {
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
}

python3 - "${ENV_FILE}" <<'PY'
import base64
import os
import pathlib
import secrets
import sys

env_path = pathlib.Path(sys.argv[1])
lines = env_path.read_text(encoding="utf-8").splitlines()

current = {}
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        continue
    key, value = stripped.split("=", 1)
    current[key] = value

def random_urlsafe(n=32):
    return secrets.token_urlsafe(n)

updates = {}
if current.get("NETBIRD_OWNER_PASSWORD", "change-me") in ("", "change-me"):
    updates["NETBIRD_OWNER_PASSWORD"] = random_urlsafe(16)
if current.get("NETBIRD_TURN_PASSWORD", "change-me") in ("", "change-me"):
    updates["NETBIRD_TURN_PASSWORD"] = random_urlsafe(16)
if current.get("NETBIRD_TURN_SECRET", "change-me") in ("", "change-me"):
    updates["NETBIRD_TURN_SECRET"] = random_urlsafe(24)
if current.get("NETBIRD_RELAY_AUTH_SECRET", "change-me") in ("", "change-me"):
    updates["NETBIRD_RELAY_AUTH_SECRET"] = random_urlsafe(24)
if current.get("NETBIRD_DATASTORE_ENC_KEY", "change-me") in ("", "change-me"):
    updates["NETBIRD_DATASTORE_ENC_KEY"] = base64.b64encode(os.urandom(32)).decode("ascii")

if not updates:
    print("No NetBird secrets needed initialization.")
    raise SystemExit(0)

new_lines = []
seen = set()
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
        key, _ = stripped.split("=", 1)
        if key in updates:
            new_lines.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    new_lines.append(line)

for key, value in updates.items():
    if key not in seen:
      new_lines.append(f"{key}={value}")

env_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
print("Initialized NetBird secrets in .env:")
for key in updates:
    print(f"  - {key}")
PY
