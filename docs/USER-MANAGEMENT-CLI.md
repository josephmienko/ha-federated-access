# User Management CLI - Quick Start Guide

Unified user management interface for administering users across NetBird, Authentik, and Home Assistant.

## Overview

The `users-cli.py` tool provides a single command-line interface to:
- **List** all users across NetBird, Authentik, and Home Assistant
- **Show** user details and their status in each system
- **Add** new users to all three systems with a single command
- **Remove** users from all systems (future enhancement)

## Installation & Setup

### Prerequisites

Your `.env` file should already have most variables set:

✅ **Already configured**:
- `NETBIRD_DOMAIN`
- `NETBIRD_MGMT_API_PORT`
- `NETBIRD_API_TOKEN`
- `AUTHENTIK_ENABLED`
- `AUTHENTIK_DOMAIN`

🔶 **You need to add**:
- `HA_TOKEN` — Home Assistant long-lived access token

### Getting the HA_TOKEN

This is the **only** new variable you need to add:

1. **Login to Home Assistant**
   - Navigate to `http://localhost:8123`
   - Log in with your admin account

2. **Create long-lived token**
   - Click your profile icon (bottom left corner)
   - Scroll to "Long-Lived Access Tokens" section
   - Click "Create Token"
   - Name it: `"Crooked Sentry User Management"`
   - Click "Create"
   - Copy the token (won't be shown again!)

3. **Add to .env**
   ```bash
   echo 'HA_TOKEN=eyJ...' >> /path/to/crooked-sentry/.env
   ```

4. **Verify**
   ```bash
   source .env
   ./scripts/users.sh list
   ```

## Usage

### List All Users

Shows all users across all three systems with their sync status.

```bash
./scripts/users-cli.py list
```

Output:
```
==============================================================================================
Email                                    NetBird      Authentik    HA          
==============================================================================================
user1@example.com                        ✓            ✓            ✓           
user2@example.com                        ✓            ✓            ✗           
==============================================================================================
```

Status symbols:
- `✓` - User exists in system
- `✗` - User missing from system
- `!` - Error checking user

### Show User Details

Display detailed information about a specific user across all systems.

```bash
./scripts/users-cli.py show user@example.com
```

Output:
```
User: user@example.com
------------------------------------------------------------
NetBird:
  Status: ✓
  ID:     e2d3c4b5-a1f2-4c5d-8e9f-a1b2c3d4e5f6

Authentik:
  Status: ✓
  ID:     3
  Name:   User Example

Home Assistant:
  Status: ✓
  Username: user@example.com

------------------------------------------------------------
```

### Add New User

Create a new user interactively across all three systems.

```bash
./scripts/users-cli.py add user@example.com
```

Or without specifying email:

```bash
./scripts/users-cli.py add
```

The script will prompt for:
1. Email address (if not provided)
2. Display name (optional - auto-generated from email if blank)
3. Password
4. Password confirmation

Example session:
```
$ ./scripts/users-cli.py add
Email: alice@example.com
Name (optional, press Enter to auto-generate): Alice Smith
Password: ••••••••••
Confirm password: ••••••••••

Creating user: alice@example.com
(This may take a minute...)

✓ Created user in NetBird: alice@example.com
✓ Created user in Authentik: alice@example.com
✓ Created user in Home Assistant: alice@example.com

Results:
----------------------------------------
✓ NetBird
✓ Authentik
✓ Home Assistant

✓ User created successfully on all systems
```

### Additional Options

```bash
# Enable debug logging
./scripts/users-cli.py --debug list

# Use custom environment file
./scripts/users-cli.py --env /path/to/.env list

# Use custom config file
./scripts/users-cli.py --config /path/to/config.yaml list
```

## Error Handling

If a user is only partially created (e.g., created in NetBird and Authentik but not HA):

1. **Check logs**: The CLI shows which systems failed
2. **Retry**: Running `add` again for the same email will skip existing users in successful systems
3. **Manual fix**: Access individual system dashboards to manually resolve issues

Common issues:

| Error | Solution |
|-------|----------|
| `NETBIRD_API_TOKEN not found` | Add `NETBIRD_API_TOKEN` to `.env` |
| `HA_TOKEN not found` | Add `HA_TOKEN` to `.env` |
| `Authentik shell command timed out` | Ensure Authentik containers are running: `docker compose -f netbird/docker-compose.yaml --profile authentik up -d` |
| `NetBird API error: 401` | Check NETBIRD_API_TOKEN is valid |
| `Connection refused` | Check services are running and accessible |

## Architecture

### System Integration

#### NetBird
- Uses REST API at `http://localhost:33073/api`
- Creates users with email and name
- User activation is automatic
- Tokens managed via NetBird settings

#### Authentik
- Uses Django ORM via `ak shell` (Docker)
- Sets user password at creation
- Creates user with email as username
- Supports additional attributes like `email_verified`

#### Home Assistant
- Uses REST API at `http://localhost:8123/api`
- Supports user creation via auth endpoint
- Requires password at creation (users don't self-register)
- Uses bearer token authentication

### Data Flow

```
┌─────────────────────────────────────────────────────┐
│              users-cli.py                           │
│  (Unified User Management Interface)                │
└────┬──────────────────┬──────────────────┬──────────┘
     │                  │                  │
     ▼                  ▼                  ▼
┌──────────────┐  ┌───────────────┐  ┌──────────────┐
│  NetBird     │  │   Authentik   │  │ Home         │
│  API Client  │  │   Django ORM  │  │ Assistant    │
│              │  │   (via Docker)│  │ API Client   │
└──────┬───────┘  └───────┬───────┘  └──────┬───────┘
       │                  │                  │
       ▼                  ▼                  ▼
    REST API         Django Shell      REST API
    (curl)         (docker compose)     (urllib)
    :33073          :auto (exec)        :8123

```

## Advanced Configuration

### Running from Pi

If you want to run this from the Raspberry Pi itself:

```bash
# SSH into the Pi
ssh pi@crookedsentry.local

# Navigate to project
cd /home/pi/crooked-sentry

# Set environment from .env
export $(cat .env | xargs)

# Run CLI
./scripts/users-cli.py list
```

### Running from Remote Machine

To run from a remote machine (e.g., your Mac), you'll need to proxy the APIs:

```bash
# SSH tunnel to NetBird API
ssh -L 33073:localhost:33073 pi@crookedsentry.local

# SSH tunnel to Home Assistant API
ssh -L 8123:localhost:8123 pi@crookedsentry.local

# Then run on local machine
./scripts/users-cli.py list
```

### Integration with Scripts

Run user creation as part of automated workflows:

```bash
#!/bin/bash

# Create multiple users from a CSV file
while IFS=, read email name password; do
  echo "Creating user: $email"
  echo -e "$email\n$name\n$password\n$password" | \
    ./scripts/users-cli.py add
done < users.csv
```

## Troubleshooting

### Check Service Status

```bash
# Check if NetBird API is responding
curl -H "Authorization: Token $NETBIRD_API_TOKEN" \
  http://localhost:33073/api/users

# Check if Authentik is running
docker ps | grep authentik

# Check if Home Assistant is responding
curl -H "Authorization: Bearer $HA_TOKEN" \
  http://localhost:8123/api/
```

### Enable Debug Logging

```bash
./scripts/users-cli.py --debug list
```

This will print detailed logging of all API calls and errors.

### Manual API Testing

```bash
# NetBird - list users
curl -s -H "Authorization: Token $NETBIRD_API_TOKEN" \
  http://localhost:33073/api/users | python3 -m json.tool

# Authentik - run Django shell
cd netbird && docker compose --profile authentik exec -T \
  authentik-server ak shell

# Home Assistant - list users
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  http://localhost:8123/api/auth/users | python3 -m json.tool
```

## Future Enhancements

Potential additions:
- Remove/delete users across systems
- Update user details (name, email)
- Bulk import from CSV
- User group/team management
- Permission/role assignment
- Audit logging
- Backup/restore functionality
- Web UI alternative to CLI

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review logs with `--debug` flag
3. Check individual system dashboards
4. Review the integration status with `show` command

## Related Commands

If you need to manually manage users in each system:

```bash
# Authentik - create user directly
sudo ./scripts/bootstrap-authentik-user.sh user@example.com password123

# NetBird - configure identity providers
sudo ./scripts/converge-netbird-idps.sh

# Home Assistant - OIDC setup
sudo ./scripts/converge-homeassistant-oidc.sh
```
