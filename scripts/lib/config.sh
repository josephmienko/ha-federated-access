#!/usr/bin/env bash

config_get() {
  local expr="$1"
  local default_value="${2:-}"
  local required="${3:-false}"
  python3 - "${CONFIG_FILE}" "${expr}" "${default_value}" "${required}" <<'PY'
import sys
import yaml

path, expr, default_value, required = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

cur = data
for part in expr.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        if required == "true":
            raise SystemExit(f"Missing config key: {expr}")
        print(default_value)
        raise SystemExit(0)

if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print(default_value)
else:
    print(cur)
PY
}

config_first() {
  local default_value="$1"
  shift
  python3 - "${CONFIG_FILE}" "${default_value}" "$@" <<'PY'
import sys
import yaml

path = sys.argv[1]
default_value = sys.argv[2]
exprs = sys.argv[3:]
with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

def get_expr(expr):
    cur = data
    for part in expr.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur

for expr in exprs:
    value = get_expr(expr)
    if value in (None, ""):
        continue
    if isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)
    raise SystemExit(0)

print(default_value)
PY
}
