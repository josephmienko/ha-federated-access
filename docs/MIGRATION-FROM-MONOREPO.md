# Migration From Monorepo

This repo is being extracted from a larger Home Assistant automation monorepo. During the transition, the monorepo and this repo will both contain copies of the auth and remote-access tooling.

## Current Consumption Model

Use copied files for now.

The monorepo remains the operational deployment source until this standalone repo has completed at least one real converge cycle from its own checkout. That means:

- keep the monorepo copies in place
- make active development changes in `ha-federated-access` first when they touch auth or remote access
- backport required fixes into the monorepo copy only when the current deployment still depends on it
- do not delete monorepo scripts yet

This is intentionally conservative because these scripts install packages, write `/opt` and `/var/log`, patch Home Assistant configuration, and restart containers.

## Files Owned By This Repo

These paths are now logically owned by `ha-federated-access`:

```text
homeassistant/auth_oidc/static/injection.js
homeassistant/auth_oidc/static/ha-branding-overrides.js
netbird/docker-compose.yaml
netbird/init-secrets.sh
netbird/render-config.sh
netbird/setup-instance.sh
netbird/nginx-ha-proxy.conf
netbird/templates/
patches/hass-oidc-auth-subject-link.patch
scripts/bootstrap-authentik-user.sh
scripts/converge-authentik-oidc-providers.sh
scripts/converge-homeassistant-oidc.sh
scripts/converge-netbird-browser-access.sh
scripts/converge-netbird-idps.sh
scripts/install-netbird.sh
scripts/users-cli.py
scripts/users.sh
scripts/verify-netbird.sh
scripts/verify-users-cli.sh
terraform/cloudflare-dns/
```

The monorepo may keep copies temporarily, but those copies should be treated as vendored deployment copies, not the source of truth.

## Near-Term Workflow

For auth/remote-access changes:

1. Change this repo first.
2. Run local validation.
3. If the monorepo deployment still needs the change, copy the changed files back into the monorepo.
4. Run the target converge or verify command from the deployment source currently in use.
5. Record whether the change was proven from the standalone repo or from the monorepo copy.

Validation commands:

```bash
bash -n scripts/*.sh scripts/lib/*.sh netbird/*.sh
python3 -m py_compile scripts/*.py
node --check homeassistant/auth_oidc/static/injection.js
node --check homeassistant/auth_oidc/static/ha-branding-overrides.js
```

## Standalone-Proof Milestone

Before the monorepo stops carrying full copies, this repo must prove:

- `examples/config.example.yaml` can be adapted to the real deployment without adding old monorepo-only keys
- `scripts/converge-homeassistant-oidc.sh` runs successfully from this repo checkout
- `scripts/converge-netbird-browser-access.sh` runs successfully from this repo checkout when browser access is enabled
- `scripts/verify-netbird.sh` passes or reports only known environmental warnings
- Home Assistant returns a healthy `/auth/oidc/welcome` response after converge
- no script requires files outside this repo except target runtime config, Docker state, and `.env`

## Preferred Future Consumption Model

Use release tarballs after the standalone-proof milestone.

Recommended monorepo behavior:

1. Pin a released version, for example `HA_FEDERATED_ACCESS_VERSION=v0.1.0`.
2. Download the release tarball.
3. Verify checksum.
4. Extract to a vendored runtime path, for example `.vendor/ha-federated-access`.
5. Run scripts from that extracted path with the monorepo deployment `.env` and `config.yaml`.

Example shape:

```bash
curl -fsSL \
  "https://github.com/josephmienko/ha-federated-access/archive/refs/tags/${HA_FEDERATED_ACCESS_VERSION}.tar.gz" \
  -o /tmp/ha-federated-access.tar.gz
tar -xzf /tmp/ha-federated-access.tar.gz -C .vendor
ENV_FILE="$PWD/.env" \
CONFIG_FILE="$PWD/config.yaml" \
  .vendor/ha-federated-access-*/scripts/converge-homeassistant-oidc.sh
```

This keeps the monorepo small and makes auth tooling upgrades explicit.

## Rejected For Now

Do not use a git subtree yet.

A subtree would preserve history and make local edits easy, but it also makes ownership ambiguous while the extracted repo is still moving quickly. Use copied files during proof-out, then release tarballs for operational consumption.

Do not make this HACS.

This repo is host-level infrastructure orchestration. HACS may still be relevant later for a small Home Assistant integration or frontend companion, but not for these install/converge scripts.

## Cutover Criteria

The monorepo can replace copied files with a release-tarball wrapper when:

- this repo has a pushed GitHub remote
- CI passes on the default branch
- at least one tagged release exists
- the real Pi has converged successfully from the standalone checkout
- the monorepo wrapper can run the same converge using `ENV_FILE` and `CONFIG_FILE`
- rollback is documented as pinning the previous release tag
