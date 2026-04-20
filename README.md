# ha-federated-access

Infrastructure tooling for federated Home Assistant access.

This repository packages auth and remote-access tooling for Home Assistant deployments. It is not a HACS package and not a Home Assistant integration. It is a host-level orchestration repo for installing and converging:

- NetBird-compatible WireGuard overlay access
- optional Authentik-backed federated SSO
- optional Google OIDC provider wiring
- optional NetBird browser access for Home Assistant
- optional patched Home Assistant OIDC auth
- user onboarding helpers across Authentik, NetBird, and Home Assistant

## Current State

This extraction initially preserves the known-working implementation shape with minimal repackaging. The current focus is removing project-specific names, domains, paths, and assumptions while keeping behavior testable.

Do not treat this as a clean public install surface yet.

## Repo Layout

```text
ha-federated-access/
  .github/workflows/validate.yml
  docs/
  examples/
    config.example.yaml
    env.example
  homeassistant/
    auth_oidc/static/
      injection.js
      ha-branding-overrides.js
  netbird/
    docker-compose.yaml
    templates/
  patches/
    hass-oidc-auth-subject-link.patch
  scripts/
  terraform/
    cloudflare-dns/
```

## Local Bootstrap

Copy the examples before running scripts on a target host:

```bash
cp examples/env.example .env
cp examples/config.example.yaml config.yaml
```

Then edit `.env` and `config.yaml` for the target environment.

## Configuration Contract

`examples/config.example.yaml` is the supported config shape for this repo.

Required keys:

- `system.log_dir`: writable log directory for converge and verify scripts.
- `homeassistant.config_dir`: Home Assistant config directory containing `configuration.yaml`.
- `homeassistant.port`: local Home Assistant HTTP port.
- `homeassistant.container_name`: Docker container name used for direct Home Assistant storage inspection.
- `homeassistant.compose.file`: Docker Compose file that manages the Home Assistant container.
- `homeassistant.compose.env_file`: env file for the Home Assistant Compose stack.
- `homeassistant.compose.service`: Compose service name for Home Assistant.
- `netbird.enabled`: whether NetBird convergence should run.
- `netbird.stack_root`: runtime install directory for the NetBird/Auth stack.
- `netbird.compose_service_name`: systemd service name for the NetBird/Auth stack.
- `netbird.compose_file`: runtime Compose file for the NetBird/Auth stack.

Compatibility:

- Older `stage2.homeassistant.*` and `stage2.stack_root` keys are still accepted by the scripts as fallback inputs.
- New installations should use the top-level `homeassistant.*` keys from the example.

## Validation

The validation workflow checks:

- shell syntax for scripts
- Python syntax for helper CLIs
- JavaScript syntax for auth-page static files
- dry-run application of `patches/hass-oidc-auth-subject-link.patch` against upstream `hass-oidc-auth` `v0.6.5-alpha`

Equivalent local commands:

```bash
bash -n scripts/*.sh scripts/lib/*.sh netbird/*.sh
python3 -m py_compile scripts/*.py
node --check homeassistant/auth_oidc/static/injection.js
node --check homeassistant/auth_oidc/static/ha-branding-overrides.js
```

## Extraction Plan

1. Preserve the known-working implementation in this standalone repo.
2. Replace deployment-specific defaults with generic config/env inputs.
3. Add focused tests for config rendering and patch application.
4. Run one real converge from this repo against the existing Pi.
5. Replace monorepo copies with wrappers or a vendored sync path after the standalone repo proves itself.
