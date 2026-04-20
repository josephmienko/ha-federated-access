# User Management CLI - Setup Checklist

Use this checklist to ensure the user management CLI is properly configured and ready to use.

## Pre-Setup Phase

- [ ] All three systems are running (NetBird, Authentik, Home Assistant)
- [ ] You have command-line access to the Home Assistant Federated Access Pi (SSH or local)
- [ ] Python 3.8+ is available on the system
- [ ] Docker and docker-compose are installed (for Authentik access)
- [ ] Your `.env` file is properly configured (most variables already exist!)

## Existing Configuration

✅ The following variables are **already set** in your `.env`:
- `NETBIRD_DOMAIN` ✓
- `NETBIRD_MGMT_API_PORT` ✓
- `NETBIRD_API_TOKEN` ✓
- `AUTHENTIK_ENABLED` ✓
- `AUTHENTIK_DOMAIN` ✓
- `NETBIRD_STACK_ROOT` ✓ (with standard default)

🔶 You only need to add **ONE** new variable:
- `HA_TOKEN` — Home Assistant long-lived access token

## NetBird Configuration

✅ Already configured in `.env`:
- [ ] Verify `NETBIRD_API_TOKEN` is set: `grep NETBIRD_API_TOKEN .env`
- [ ] If missing, get it from NetBird Dashboard → Settings → API Keys
- [ ] Verify token works:
  ```bash
  source .env
  curl -s -H "Authorization: Token $NETBIRD_API_TOKEN" \
    http://localhost:33073/api/instance | python3 -m json.tool
  # Should return instance information without errors
  ```

## Authentik Configuration

✅ Already configured in `.env`:
- [ ] Verify `AUTHENTIK_ENABLED=true` is set
- [ ] Verify `AUTHENTIK_DOMAIN` is set
- [ ] Verify Authentik containers are running:
  ```bash
  docker ps | grep authentik
  # Should show: authentik-server, authentik-worker, authentik-postgresql, authentik-redis
  ```

## Home Assistant Configuration

✅ Container is already running (from stage 2 setup)

Only need to add **one** variable: `HA_TOKEN`

- [ ] Start Home Assistant if not running:
  ```bash
  cd /opt/ha-federated-access
  docker compose up -d home-assistant
  ```

- [ ] Access Home Assistant web UI
  - [ ] Navigate to `http://localhost:8123`
  - [ ] Log in with your account

- [ ] Create long-lived access token
  - [ ] Click profile icon (bottom left corner)
  - [ ] Scroll down to "Long-Lived Access Tokens" section
  - [ ] Click "Create Token"
  - [ ] Give it a name: `"Home Assistant Federated Access User Management"`
  - [ ] Click "Create"
  - [ ] **Copy the token immediately** (it won't be shown again!)

- [ ] Add token to `.env`
  ```bash
  echo 'HA_TOKEN=eyJ...<your-long-token>...' >> /path/to/ha-federated-access/.env
  ```

- [ ] Verify it works
  ```bash
  source .env
  curl -s -H "Authorization: Bearer $HA_TOKEN" \
    http://localhost:8123/api/ | python3 -m json.tool
  # Should return API information without errors
  ```

## CLI Installation

- [ ] Scripts are in place
  ```bash
  ls -la /path/to/ha-federated-access/scripts/users-cli.py
  ls -la /path/to/ha-federated-access/scripts/users.sh
  # Both should exist and be executable
  ```

- [ ] Make scripts executable
  ```bash
  chmod +x /path/to/ha-federated-access/scripts/users-cli.py
  chmod +x /path/to/ha-federated-access/scripts/users.sh
  ```

- [ ] Documentation is available
  ```bash
  ls /path/to/ha-federated-access/docs/USER-MANAGEMENT-CLI.md
  ls /path/to/ha-federated-access/docs/USER-MANAGEMENT-INTEGRATION.md
  # Should both exist
  ```

## Functional Testing

### Test 1: List Users

```bash
cd /path/to/ha-federated-access
./scripts/users.sh list
```

- [ ] Command completes without errors
- [ ] Shows table with user counts from all systems
- [ ] Status symbols (✓, ✗, !) display correctly

### Test 2: Show Existing User

```bash
./scripts/users.sh show admin@example.com
# (adjust email to actual admin user)
```

- [ ] Displays user information
- [ ] Shows user status in each system
- [ ] No authentication errors

### Test 3: Create Test User

```bash
./scripts/users.sh add test-user@example.com
# When prompted:
# - Name: Test User (or press Enter)
# - Password: TestPassword123!
# - Confirm: TestPassword123!
```

- [ ] User creation completes
- [ ] All three systems show "✓" (created successfully)
- [ ] Can verify in web dashboards

### Test 4: Verify Test User

```bash
./scripts/users.sh show test-user@example.com
```

- [ ] Shows ✓ in all three systems
- [ ] User ID and details visible

### Test 5: Verify Web UI Access

- [ ] NetBird dashboard
  - [ ] New user appears in Users list
  - [ ] Check user details
  
- [ ] Authentik dashboard
  - [ ] Navigate to Users
  - [ ] Find new user in list
  - [ ] Verify email and status
  
- [ ] Home Assistant
  - [ ] Settings → People
  - [ ] New user appears in list

### Test 6: Debug Mode

```bash
./scripts/users.sh --debug list
```

- [ ] Shows detailed logging output
- [ ] Displays API calls and responses
- [ ] No sensitive information leaked in logs

## Security Hardening

- [ ] `.env` file has restrictive permissions
  ```bash
  chmod 600 /path/to/ha-federated-access/.env
  ls -l /path/to/ha-federated-access/.env
  # Should show: -rw------- (600)
  ```

- [ ] `.env` is in `.gitignore`
  ```bash
  grep "\.env" /path/to/ha-federated-access/.gitignore
  # Should be present
  ```

- [ ] Test user is deleted after verification
  ```bash
  # Option 1: Use web UI to delete from each system
  # Option 2: Manual deletion (if delete feature added)
  ```

- [ ] Tokens are rotated periodically
  - [ ] Set calendar reminder for 90 days
  - [ ] Document token rotation process

## Documentation Review

- [ ] Read USER-MANAGEMENT-CLI.md
  - [ ] Understand all available commands
  - [ ] Know how to troubleshoot common issues
  
- [ ] Read USER-MANAGEMENT-INTEGRATION.md
  - [ ] Understand how each system is integrated
  - [ ] Know error codes and what they mean

- [ ] Create admin runbook
  - [ ] Document your specific setup
  - [ ] Include your domain names and ports
  - [ ] Store securely (encrypted or shared drive)

## Ops Integration

- [ ] Add to team documentation/wiki
- [ ] Create admin training guide
- [ ] Add to disaster recovery procedures
- [ ] Set up logs rotation (if logging to file)
  ```bash
  # Optional: Log all user management operations
  alias users-cli-log='./scripts/users.sh >> /var/log/ha-federated-access/user-mgmt.log 2>&1'
  ```

## Backup and Recovery

- [ ] Document where API tokens are stored
  - [ ] `.env` file (ensure backed up)
  - [ ] Secure password manager (copy tokens there)
  
- [ ] Establish user backup procedure
  - [ ] Export user lists periodically
  - [ ] Store in secure location
  
- [ ] Document recovery procedure
  - [ ] How to restore if all systems go down
  - [ ] How to re-create users if needed

## Going Live

- [ ] All tests pass ✓
- [ ] Team is trained ✓
- [ ] Documentation is complete ✓
- [ ] Backup procedures in place ✓
- [ ] Security measures verified ✓

- [ ] Create admin rotation schedule
- [ ] Schedule token rotation dates
- [ ] Schedule security review (quarterly)
- [ ] Plan feature enhancement requests

## Self-Hosted Network Setup (Optional)

If you want to run the CLI from your Mac/development machine:

- [ ] SSH tunnel to NetBird API
  ```bash
  ssh -L 33073:localhost:33073 pi@homeassistant.local &
  ```

- [ ] SSH tunnel to Home Assistant API
  ```bash
  ssh -L 8123:localhost:8123 pi@homeassistant.local &
  ```

- [ ] For Authentik: Must run on Pi or set up Docker socket tunneling
  
- [ ] Update `.env` to use localhost
  ```bash
  NETBIRD_DOMAIN=localhost  # or set to Pi IP
  HA_PORT=8123
  AUTHENTIK_DOMAIN=localhost
  ```

- [ ] Test from remote machine
  ```bash
  ./scripts/users-cli.py --debug list
  ```

## Troubleshooting the Setup

### If "NETBIRD_API_TOKEN not found"
- [ ] Verify `.env` file exists: `cat .env | grep NETBIRD_API_TOKEN`
- [ ] Check permissions: `chmod 600 .env`
- [ ] Source the file: `source .env && echo $NETBIRD_API_TOKEN`

### If "Connection refused"
- [ ] Check services running: `docker ps`
- [ ] Check ports: `netstat -an | grep LISTEN`
- [ ] Verify URLs in `.env`

### If "authentication failed"
- [ ] Verify tokens/passwords are correct: `source .env && echo $NETBIRD_API_TOKEN`
- [ ] Tokens may have expired - regenerate them

### If Docker exec fails
- [ ] Check Docker socket permissions: `docker ps`
- [ ] Ensure user is in docker group: `groups $USER`
- [ ] Try with sudo: `sudo ./scripts/users.sh list`

## Support Resources

- **Quick Start**: `docs/USER-MANAGEMENT-CLI.md`
- **Technical Details**: `docs/USER-MANAGEMENT-INTEGRATION.md`
- **Example Usage**: `./scripts/users-cli-examples.sh`
- **Debug Mode**: `./scripts/users.sh --debug`
- **Python Source**: `./scripts/users-cli.py` (fully commented)

## Post-Setup Operations

### Daily/Weekly
- [ ] Monitor for failed user creations
- [ ] Check audit logs (if logging enabled)

### Monthly
- [ ] Review user access
- [ ] Update team on new policies

### Quarterly
- [ ] Rotate API tokens
- [ ] Security audit
- [ ] Review and update documentation

### Annually
- [ ] Full security review
- [ ] Disaster recovery test
- [ ] System capacity review

## Checklist Notes

- Add custom notes specific to your setup:
  ```
  
  
  
  
  ```

---

**Date Completed**: _______________
**Completed By**: _______________
**Next Review Date**: _______________
