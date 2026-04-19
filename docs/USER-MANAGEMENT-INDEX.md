# User Management CLI - Documentation Index

Quick reference and navigation guide for all user management resources.

## 📚 Documentation Structure

```
docs/
├── USER-MANAGEMENT-CLI.md                    [START HERE - User Guide]
├── USER-MANAGEMENT-SETUP-CHECKLIST.md        [Setup Instructions]
├── USER-MANAGEMENT-INTEGRATION.md            [Technical Reference]
├── USER-MANAGEMENT-IMPLEMENTATION-SUMMARY.md [Project Overview]
└── USER-MANAGEMENT-INDEX.md                  [This file]

scripts/
├── users-cli.py                              [Main CLI Application]
├── users.sh                                  [Convenience Wrapper]
└── users-cli-examples.sh                     [Interactive Examples]

root/
└── .env.users-cli.example                    [Configuration Template]
```

## 🚀 Quick Start

### For First-Time Users
1. Read: `USER-MANAGEMENT-CLI.md` - Overview and basic usage
2. Do: Follow `USER-MANAGEMENT-SETUP-CHECKLIST.md` - Complete setup
3. Try: Run `./scripts/users-cli-examples.sh` - See it in action

### For Admins
- **Daily**: `./scripts/users.sh list` - Check all users
- **New User**: `./scripts/users.sh add user@example.com` - Create user
- **Troubleshooting**: Check `USER-MANAGEMENT-CLI.md` troubleshooting section

### For Developers
- Read: `USER-MANAGEMENT-INTEGRATION.md` - API details
- Review: `scripts/users-cli.py` - Source code (700 lines, well-commented)
- Extend: Use client classes to add features

## 📖 Full Documentation

### USER-MANAGEMENT-CLI.md - User Guide
**When to use**: Learning how to use the CLI
**Topics covered**:
- Overview of features
- Installation & setup
- Usage examples for each command
- Error handling
- Troubleshooting common issues
- Advanced configuration
- Integration with scripts

**Start reading**: For immediate usage help

### USER-MANAGEMENT-SETUP-CHECKLIST.md - Setup Guide
**When to use**: Setting up for the first time
**Topics covered**:
- Pre-setup requirements
- NetBird configuration steps
- Authentik configuration steps
- Home Assistant configuration steps
- CLI installation
- Functional testing (6 tests)
- Security hardening
- Ops integration
- Disaster recovery planning

**Start reading**: Before first deployment

### USER-MANAGEMENT-INTEGRATION.md - Technical Reference
**When to use**: Understanding system internals or troubleshooting deep issues
**Topics covered**:
- Architecture and components
- NetBird REST API details
- Authentik Django ORM details
- Home Assistant REST API details
- Data synchronization strategy
- Authentication flows
- Error handling and codes
- Performance considerations
- Security best practices

**Start reading**: For API details or advanced troubleshooting

### USER-MANAGEMENT-IMPLEMENTATION-SUMMARY.md - Project Overview
**When to use**: Understanding what was built and how
**Topics covered**:
- What was created
- Features implemented
- Architecture overview
- Getting started process
- Usage patterns
- Files created/modified
- Known limitations
- Future enhancements
- Performance metrics

**Start reading**: For high-level project understanding

### This File - Documentation Index
**When to use**: Finding the right documentation
**Topics covered**:
- Documentation structure
- Quick navigation guide
- Document summaries
- Command reference
- Feature matrix

**Start reading**: When you're lost or need to find something

---

## 🎯 Common Tasks

### I want to...

**Create a new user**
→ Read: `USER-MANAGEMENT-CLI.md` - "Add New User" section
→ Run: `./scripts/users.sh add user@example.com`

**List all users**
→ Read: `USER-MANAGEMENT-CLI.md` - "List All Users" section
→ Run: `./scripts/users.sh list`

**Check user status**
→ Read: `USER-MANAGEMENT-CLI.md` - "Show User Details" section
→ Run: `./scripts/users.sh show user@example.com`

**Set up the CLI**
→ Read: `USER-MANAGEMENT-SETUP-CHECKLIST.md` - Follow all steps
→ Time: ~30 minutes

**Fix a problem**
→ Read: `USER-MANAGEMENT-CLI.md` - "Troubleshooting" section
→ Run: `./scripts/users.sh --debug list`

**Understand how it works**
→ Read: `USER-MANAGEMENT-INTEGRATION.md` - "Architecture" section
→ Read: `USER-MANAGEMENT-IMPLEMENTATION-SUMMARY.md` - "How It Works"

**Add a new feature**
→ Read: `USER-MANAGEMENT-INTEGRATION.md` - API details for your system
→ Edit: `scripts/users-cli.py` - Source code (well commented)
→ Test: Use debug mode and API testing section

**Integrate with automation**
→ Read: `USER-MANAGEMENT-CLI.md` - "Integration with Scripts" section
→ Read: `USER-MANAGEMENT-IMPLEMENTATION-SUMMARY.md` - "Usage Patterns"

**Run examples**
→ Run: `./scripts/users-cli-examples.sh`
→ Interactive menu with 5 examples

---

## 📋 Command Reference

### users-cli.py / users.sh

```bash
# List all users across all systems
./scripts/users.sh list

# Show user details
./scripts/users.sh show user@example.com

# Add new user (interactive)
./scripts/users.sh add
./scripts/users.sh add user@example.com

# Options
./scripts/users.sh --env /path/to/.env list      # Use custom env file
./scripts/users.sh --config /path/to/config.yaml # Use custom config
./scripts/users.sh --debug list                  # Enable debug logging
./scripts/users.sh --help                        # Show help (Python only)
```

### users-cli-examples.sh

```bash
# Interactive menu
./scripts/users-cli-examples.sh

# Specific examples
./scripts/users-cli-examples.sh list              # Example: list users
./scripts/users-cli-examples.sh show              # Example: show user
./scripts/users-cli-examples.sh create            # Example: create user
./scripts/users-cli-examples.sh check             # Example: bulk check
./scripts/users-cli-examples.sh debug             # Example: debug mode
```

---

## 🔧 Configuration

### Environment Variables (.env)

| Variable | Required | Purpose |
|----------|----------|---------|
| `NETBIRD_API_TOKEN` | Yes | NetBird API token for authentication |
| `HA_TOKEN` | Yes | Home Assistant long-lived access token |
| `NETBIRD_DOMAIN` | No | NetBird domain (default: netbird.example.invalid) |
| `NETBIRD_MGMT_API_PORT` | No | NetBird API port (default: 33073) |
| `AUTHENTIK_DOMAIN` | No | Authentik domain (default: auth.example.invalid) |
| `AUTHENTIK_ENABLED` | No | Enable Authentik (default: true) |
| `HA_PORT` | No | Home Assistant port (default: 8123) |

### Configuration Sources

1. **Environment**: System environment variables
2. **.env file**: Local credentials and settings
3. **config.yaml**: System configuration (read-only for discovery)
4. **Defaults**: Built-in defaults if not specified

See: `.env.users-cli.example` for template

---

## 💡 Feature Matrix

| Feature | Support | Location |
|---------|---------|----------|
| List users | ✓ | `users-cli.py list` |
| Show user details | ✓ | `users-cli.py show` |
| Create users | ✓ | `users-cli.py add` |
| Update users | ✗ | Planned |
| Delete users | ✗ | Planned |
| Bulk import | ✗ | Planned |
| Export to CSV | ✗ | Planned |
| LDAP sync | ✗ | Planned |
| Audit logging | ~ | Debug mode only |
| Web UI | ✗ | Future |

---

## 🔍 Troubleshooting Quick Links

### By Error Message

| Error | Documentation |
|-------|---|
| "NETBIRD_API_TOKEN not found" | USER-MANAGEMENT-CLI.md → Troubleshooting |
| "Connection refused" | USER-MANAGEMENT-CLI.md → Troubleshooting |
| "Authentik shell timeout" | USER-MANAGEMENT-CLI.md → Troubleshooting |
| "401 Unauthorized" | USER-MANAGEMENT-INTEGRATION.md → Error Handling |
| "409 Conflict" | USER-MANAGEMENT-INTEGRATION.md → Error Handling |

### By System

| System | Deep Dive |
|--------|-----------|
| NetBird | USER-MANAGEMENT-INTEGRATION.md → NetBird REST API |
| Authentik | USER-MANAGEMENT-INTEGRATION.md → Authentik Django ORM |
| Home Assistant | USER-MANAGEMENT-INTEGRATION.md → Home Assistant REST API |

---

## 📦 System Requirements

### Software
- Python 3.8+
- Docker & docker-compose (for Authentik)
- curl (for manual API testing)
- bash (for wrapper scripts)

### Network
- Access to NetBird API (localhost:33073 or via SSH tunnel)
- Access to Authentik (Docker on same machine)
- Access to Home Assistant (localhost:8123 or via SSH tunnel)

### Credentials
- NetBird API token
- Home Assistant long-lived token
- (Authentik access via Docker)

---

## 🎓 Learning Paths

### Path 1: Quick User
**Goal**: Learn how to use the CLI (15 minutes)
1. USER-MANAGEMENT-CLI.md - Read overview
2. Run: `./scripts/users-cli-examples.sh`
3. Try: `./scripts/users.sh list`

### Path 2: System Setup
**Goal**: Deploy and configure from scratch (1 hour)
1. USER-MANAGEMENT-SETUP-CHECKLIST.md - Follow step-by-step
2. Run: All 6 functional tests
3. Verify: `./scripts/users.sh list` works

### Path 3: Developer/Advanced
**Goal**: Understand internals and extend (2 hours)
1. USER-MANAGEMENT-IMPLEMENTATION-SUMMARY.md - High-level view
2. USER-MANAGEMENT-INTEGRATION.md - Deep technical dive
3. scripts/users-cli.py - Review source code
4. Modify as needed for your use case

### Path 4: Troubleshooting Expert
**Goal**: Diagnose and fix issues (varies)
1. USER-MANAGEMENT-CLI.md - Troubleshooting section
2. USER-MANAGEMENT-INTEGRATION.md - API specifics
3. Run with `--debug` flag
4. Manual API testing procedures

---

## 📞 Support Workflow

1. **Check if documented**
   - Search for error message in troubleshooting sections
   - Check feature matrix for supported features

2. **Enable debug mode**
   ```bash
   ./scripts/users.sh --debug list
   ```

3. **Review relevant docs**
   - For CLI issues: USER-MANAGEMENT-CLI.md
   - For setup issues: USER-MANAGEMENT-SETUP-CHECKLIST.md
   - For API issues: USER-MANAGEMENT-INTEGRATION.md

4. **Test manually**
   - Follow API testing procedures in USER-MANAGEMENT-INTEGRATION.md
   - Test each system independently

5. **Check system status**
   - Are containers running? `docker ps`
   - Are tokens valid? Compare with dashboards
   - Are services accessible? Test URLs directly

---

## 📅 Maintenance Schedule

| Task | Frequency | Documentation |
|------|-----------|---|
| Review users | Weekly | USER-MANAGEMENT-CLI.md |
| Rotate tokens | Quarterly | USER-MANAGEMENT-SETUP-CHECKLIST.md |
| Security audit | Quarterly | USER-MANAGEMENT-INTEGRATION.md |
| Disaster recovery test | Annually | USER-MANAGEMENT-SETUP-CHECKLIST.md |
| Update documentation | As-needed | This file |

---

## 🔗 Cross References

- **Main README**: `../../README.md` (references user management CLI)
- **Project Setup**: `../../scripts/` (wrapper scripts)
- **Configuration**: `../../.env.users-cli.example` (template)

---

## 📝 Version Information

- **CLI Version**: 1.0
- **Last Updated**: 2024-01-15
- **Maintained By**: Crooked Sentry Project
- **Python Version**: 3.8+
- **Status**: Production Ready

---

## 🎯 Next Steps

**New to the project?**
→ Start with: `USER-MANAGEMENT-CLI.md`

**Setting up?**
→ Follow: `USER-MANAGEMENT-SETUP-CHECKLIST.md`

**Need help?**
→ Check: Troubleshooting section of relevant doc

**Want to extend?**
→ Read: `USER-MANAGEMENT-INTEGRATION.md` + review source code

---

**Happy user managing! 👤**
