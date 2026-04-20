# User Management Integration Technical Specification

This document provides technical details on how the user management CLI integrates with NetBird, Authentik, and Home Assistant.

## Table of Contents

1. [Architecture](#architecture)
2. [API Integration Details](#api-integration-details)
3. [Data Synchronization](#data-synchronization)
4. [Authentication Flows](#authentication-flows)
5. [Error Handling](#error-handling)
6. [Troubleshooting](#troubleshooting)

## Architecture

### System Overview

```
┌────────────────────────────────────────────────────┐
│             Admin Workstation                       │
│  ┌──────────────────────────────────────────────┐  │
│  │   users-cli.py / users.sh                    │  │
│  │   (Unifies user management across systems)   │  │
│  └──────────────────────────────────────────────┘  │
└────┬────────────────┬────────────────────┬─────────┘
     │                │                    │
     │ REST API       │ Docker exec        │ REST API
     │ (curl)         │ (Django ORM)       │ (urllib)
     ▼                ▼                    ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│  NetBird     │ │   Authentik  │ │ Home         │
│  (VPN)       │ │ (Identity)   │ │ Assistant    │
└──────────────┘ └──────────────┘ └──────────────┘
```

### Component Responsibilities

| Component | Role | Communication |
|-----------|------|-----------------|
| **users-cli.py** | Main CLI orchestrator | Instantiates client classes, coordinates API calls |
| **NetBirdClient** | VPN/Network access mgmt | REST API to `http://localhost:33073/api` |
| **AuthentikClient** | Identity provider | Docker exec `ak shell` (Django ORM) |
| **HomeAssistantClient** | Home automation access | REST API to `http://localhost:8123/api` |
| **ConfigLoader** | Configuration management | Loads `.env` and `config.yaml` |

## API Integration Details

### NetBird REST API

#### Authentication

NetBird uses **Bearer Token Authentication** with custom header format:

```bash
Authorization: Token YOUR_API_TOKEN
```

#### Endpoints Used

| Operation | Method | Endpoint | Notes |
|-----------|--------|----------|-------|
| List users | GET | `/users` | Returns paginated list of all users |
| Get user | GET | `/users/{id}` | Fetch single user by ID |
| Create user | POST | `/users` | Create new user account |
| Update user | PUT | `/users/{id}` | Modify existing user |
| Delete user | DELETE | `/users/{id}` | Remove user account |

#### User Object Structure

```json
{
  "id": "e2d3c4b5-a1f2-4c5d-8e9f-a1b2c3d4e5f6",
  "email": "user@example.com",
  "name": "User Name",
  "role": "user",
  "is_service_user": false,
  "is_admin": false,
  "auto_groups": [],
  "created_at": "2024-01-15T10:30:00Z",
  "status": "active"
}
```

#### Example API Call

```bash
# List users
curl -s -H "Authorization: Token $NETBIRD_API_TOKEN" \
  http://localhost:33073/api/users | python3 -m json.tool

# Create user
curl -X POST \
  -H "Authorization: Token $NETBIRD_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email":"new@example.com","name":"New User"}' \
  http://localhost:33073/api/users
```

#### API Token Management

1. **Obtain token**:
   - Login to NetBird dashboard (https://netbird.domain)
   - Navigate to Settings → API Keys
   - Click "Create API Key"
   - Select scope: "Users"
   - Copy the displayed token

2. **Store token**:
   ```bash
   echo "NETBIRD_API_TOKEN=your-token-here" >> .env
   ```

3. **Rotate token** (periodically for security):
   - Regenerate in dashboard
   - Update `.env`
   - Restart any services/scripts using the token

### Authentik Django ORM

#### Integration Method

Authentik is integrated via **Docker shell execution**, which runs Python code directly in the Authentik container:

```bash
docker compose -f /opt/ha-federated-access/netbird/docker-compose.yaml \
  --profile authentik \
  exec -T authentik-server ak shell < python_script.py
```

This approach:
- ✓ Provides full application access via Django ORM
- ✓ No separate API token needed (runs as app process)
- ✓ Supports complex transactional operations
- ⚠ Requires Docker access and running containers
- ⚠ Slower than REST API (container startup overhead)

#### Django Models Used

```python
# Core user model
from authentik.core.models import User

class User(models.Model):
    username          # Unique identifier (typically email)
    email             # Email address
    name              # Display name
    password          # Hashed password
    is_active         # Account status
    attributes        # JSON field for custom data
    created            # Creation timestamp
    last_login        # Last login time
```

#### User Creation Flow

```python
from django.db import transaction
from authentik.core.models import User

with transaction.atomic():
    user, created = User.objects.get_or_create(
        username=email,
        defaults={
            'email': email,
            'name': name,
            'is_active': True,
        }
    )
    user.set_password(password)
    user.save()
```

#### Available Operations

| Operation | Method | Model | Notes |
|-----------|--------|-------|-------|
| List users | `User.objects.all()` | Django ORM | Query all users |
| Get user | `User.objects.get(username=...)` | Django ORM | Query single user |
| Create user | `User.objects.create(...)` | Django ORM | Create new user |
| Update user | `user.save()` | Django ORM | Persist changes |
| Set password | `user.set_password(pwd)` | Django method | Hash and store password |
| Delete user | `user.delete()` | Django ORM | Remove user |

#### Container Discovery

The client discovers the Authentik container stack location from:

1. `NETBIRD_STACK_ROOT` environment variable
2. System config `netbird.stack_root` key
3. Default: `/opt/ha-federated-access/netbird`

### Home Assistant REST API

#### Authentication

Home Assistant uses **Bearer Token Authentication**:

```bash
Authorization: Bearer YOUR_LONG_LIVED_TOKEN
```

#### Endpoints Used

| Operation | Method | Endpoint | Notes |
|-----------|--------|----------|-------|
| List users | GET | `/api/auth/users` | Returns list of system users |
| Get user | GET | `/api/auth/users?username=...` | Fetch specific user |
| Create user | POST | `/api/auth/users` | Create new user account |
| Update user | PUT | `/api/auth/users/{id}` | Modify existing user |
| Delete user | DELETE | `/api/auth/users/{id}` | Remove user account |

#### User Object Structure

```json
{
  "id": "1234abc",
  "username": "user@example.com",
  "name": "User Name",
  "is_owner": false,
  "is_admin": false,
  "local_only": false,
  "system_generated": false,
  "disabled_by_user": false,
  "active_tokens": 0,
  "mfa_modules": []
}
```

#### Example API Call

```bash
# List users
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  http://localhost:8123/api/auth/users

# Create user
curl -X POST \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"user@example.com","password":"secure-password","name":"User Name"}' \
  http://localhost:8123/api/auth/users
```

#### Token Management

1. **Obtain long-lived token**:
   - Goto Home Assistant UI
   - Click profile icon (bottom left)
   - Scroll to "Long-Lived Access Tokens"
   - Click "Create Token"
   - Copy token (won't be shown again)

2. **Store token**:
   ```bash
   echo "HA_TOKEN=eyJ..." >> .env
   ```

3. **Revoke token** (for security):
   - Goto Home Assistant UI
   - Delete token from same screen
   - Update `.env` with new token

#### API Limitations

- User self-registration is **disabled** when you provide the password
- Passwords are **required** for API-created users
- Email is **optional** (Home Assistant stores username mostly)
- User can be created with just username and password

## Data Synchronization

### User Identity Mapping

Users are identified differently across systems:

| System | Identifier | Primary Key | Secondary |
|--------|-----------|------------|-----------|
| **NetBird** | email | `id` (UUID) | `email` |
| **Authentik** | email (username) | `id` (int) | `username`, `email` |
| **Home Assistant** | email (username) | `id` (UUID) | `username`, `name` |

### Synchronization Strategy

The CLI uses **email as the common identifier**:

```
Create user alice@example.com:
├─ NetBird: Create with email="alice@example.com"
├─ Authentik: Create with username="alice@example.com", email="alice@example.com"
└─ Home Assistant: Create with username="alice@example.com"
```

### Current Limitations

1. **One-way sync**: Changes in one system don't automatically propagate
2. **No delta sync**: The CLI doesn't track what changed
3. **Partial failures**: If one system fails, user exists partially
4. **No versioning**: No tracking of user state across systems

### Future Enhancement: Two-Way Sync

```python
# Pseudocode for future implementation
def sync_all_users():
    """Ensure all users in source exist in destination."""
    netbird_users = netbird.list_users()
    for user in netbird_users:
        if not authentik.get_user(user.email):
            authentik.create_user(...)
        if not ha.get_user(user.email):
            ha.create_user(...)
```

## Authentication Flows

### User Registration Flow

```
Admin initiates user creation:
│
├─> users-cli.py add user@example.com
│   ├─> Prompt for password
│   ├─> Prompt for display name
│   └─> Call manager.add_user()
│
├─> NetBird creates user:
│   ├─> POST /api/users with email
│   ├─> Receive user.id
│   └─> User activation automatic
│
├─> Authentik creates user:
│   ├─> Execute Django shell
│   ├─> User.objects.create(username=email)
│   ├─> user.set_password(password)
│   ├─> user.save()
│   └─> Return user PK
│
└─> Home Assistant creates user:
    ├─> POST /api/auth/users
    ├─> Include username and password
    ├─> Receive user.id
    └─> User can login immediately
```

### User Login Flow (OIDC)

If OIDC is enabled, the flow is:

```
User attempts login to Home Assistant or NetBird:
│
├─> Service redirects to Authentik OIDC endpoint
├─> Authentik validates credentials
├─> Authentik returns ID token with claims
├─> Service validates token
├─> Service grants access
└─> User authenticated
```

## Error Handling

### HTTP Error Codes

| Status | Meaning | CLI Handling |
|--------|---------|--------------|
| 200 | Success | Process response |
| 201 | Created | Process response (user created) |
| 204 | No Content | Treat as success |
| 400 | Bad Request | Log error, retry with different params |
| 401 | Unauthorized | Token expired or invalid |
| 404 | Not Found | User doesn't exist |
| 409 | Conflict | User already exists |
| 500 | Server Error | Log error, don't retry |

### Exception Handling Strategy

```python
try:
    user = netbird.create_user(email, name)
except urllib.error.HTTPError as e:
    if e.code == 401:
        raise ValueError("Invalid NetBird API token")
    elif e.code == 409:
        logger.warning(f"User already exists: {email}")
    else:
        raise RuntimeError(f"NetBird API error: {e.code}")
except Exception as e:
    raise RuntimeError(f"Failed to create user: {e}")
```

### Docker-specific Errors

```
Error: docker: command not found
→ Docker not installed or not in PATH

Error: permission denied while trying to connect to Docker daemon
→ Run with `sudo` or add user to docker group:
  sudo usermod -aG docker $USER

Error: Authentik shell command timed out
→ Authentik containers not responding or too slow
→ Check: docker ps | grep authentik
```

## Troubleshooting

### Common Issues and Solutions

#### 1. "NETBIRD_API_TOKEN not found"

**Symptom**: CLI exits with error about missing token

**Root Cause**: Token not set in `.env`

**Solution**:
```bash
# Get token from NetBird dashboard
# Navigate to Settings > API Keys

# Add to .env
echo "NETBIRD_API_TOKEN=your-token-here" >> .env

# Verify
source .env
echo $NETBIRD_API_TOKEN
```

#### 2. "NetBird API error: 401"

**Symptom**: Authentication fails when calling NetBird

**Root Cause**: Token is invalid or expired

**Solution**:
```bash
# Regenerate token in NetBird dashboard
# Update .env with new token
sed -i 's/NETBIRD_API_TOKEN=.*/NETBIRD_API_TOKEN=new-token/' .env
```

#### 3. "Authentik shell command timed out"

**Symptom**: Authentik user operations hang

**Root Cause**: Authentik containers not responsive

**Solution**:
```bash
# Check if containers are running
docker ps | grep authentik

# If not running, start them
cd /opt/ha-federated-access/netbird
docker compose --profile authentik up -d

# Wait for startup
sleep 10

# Try again
./scripts/users-cli.py list
```

#### 4. "Connection refused: http://localhost:8123"

**Symptom**: Home Assistant API calls fail

**Root Cause**: Home Assistant not running or wrong port

**Solution**:
```bash
# Check if Home Assistant is running
docker ps | grep home-assistant

# Check if using correct port
grep -i "HA_PORT" .env

# If on different port, update .env
echo "HA_PORT=8123" >> .env
```

#### 5. User created in some systems but not all

**Symptom**: Partial user creation (created in NetBird but not HA)

**Root Cause**: System failed mid-operation or API unreachable

**Solution**:
```bash
# Check which systems have the user
./scripts/users-cli.py show user@example.com

# Manually create in missing systems through web UI OR
# Fix the underlying issue and try again

# For manual creation:
# - NetBird: Dashboard > Users > Add User
# - Authentik: Dashboard > Users > Create User
# - Home Assistant: Settings > People > Create User
```

### Debug Mode

Enable detailed logging:

```bash
./scripts/users-cli.py --debug list
```

This shows:
- All API requests and responses
- Field mapping details
- Full error tracebacks
- Timing information

### Manual API Testing

Function testing of each system independently:

```bash
# Test NetBird API
curl -s -H "Authorization: Token $NETBIRD_API_TOKEN" \
  http://localhost:33073/api/instance | python3 -m json.tool

# Test Authentik
cd /opt/ha-federated-access/netbird
docker compose --profile authentik exec -T \
  authentik-server ak shell << 'EOF'
from authentik.core.models import User
print(f"Total users: {User.objects.count()}")
EOF

# Test Home Assistant
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  http://localhost:8123/api/ | python3 -m json.tool
```

### Performance Considerations

- **NetBird**: API calls typically 100-500ms
- **Authentik**: Django shell startup ~5-10 seconds per call
- **Home Assistant**: API calls typically 300-800ms
- **Total user creation**: ~15-30 seconds (depends on Authentik startup)

### Security Best Practices

1. **Token Storage**
   - Never commit `.env` to git
   - Use `.env.example` with placeholders
   - Rotate tokens periodically (quarterly recommended)

2. **Access Control**
   - Only admins should run `users-cli.py`
   - Store scripts on secure systems
   - Audit user creation logs

3. **Audit Trail**
   - All operations logged to console
   - Consider redirecting to file:
     ```bash
     ./scripts/users.sh list 2>&1 | tee user-mgmt.log
     ```

4. **Password Management**
   - Prompt for passwords instead of passing via CLI
   - Never log passwords
   - Use strong password requirements

## Integration Points

### With Existing Scripts

The user management CLI integrates with:

- `scripts/bootstrap-authentik-user.sh` — Can be replaced by `users-cli.py add`
- `scripts/converge-authentik-oidc-providers.sh` — Still needed for OIDC setup
- `scripts/converge-netbird-idps.sh` — Still needed for IdP configuration

### Future Integrations

Potential future integrations:

- [ ] Okta/Azure AD sync
- [ ] LDAP directory integration
- [ ] Slack/Discord user linking
- [ ] Audit logging to central system
- [ ] Web UI for user management
- [ ] Automated backup/restore
- [ ] User provisioning workflows

## Version Information

- **CLI Version**: 1.0 (initial release)
- **NetBird API**: v1 (tested with 0.26.x)
- **Authentik**: v2024.1+ (via Django ORM)
- **Home Assistant**: 2024.1+ (API stable)
- **Docker**: 20.10+ (for Authentik integration)
- **Python**: 3.8+ (for CLI and scripts)
