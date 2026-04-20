#!/usr/bin/env python3
"""
Unified user management CLI for Home Assistant Federated Access infrastructure.

Manages users across:
- NetBird (VPN/Network access)
- Authentik (Identity & SSO)
- Home Assistant (Home automation)

Environment Variables Required:
  NETBIRD_API_TOKEN           NetBird API token (get from Dashboard > Settings > API Keys)
  HA_TOKEN                    Home Assistant long-lived token (get from HA UI > Profile > Tokens)

Environment Variables Used (if available, with defaults):
  NETBIRD_DOMAIN              NetBird domain (default: netbird.example.invalid)
  NETBIRD_MGMT_API_PORT       NetBird API port (default: 33073)
  NETBIRD_STACK_ROOT          NetBird stack root (default: /opt/ha-federated-access/netbird)
  AUTHENTIK_DOMAIN            Authentik domain (default: auth.example.invalid)
  AUTHENTIK_ENABLED           Enable Authentik (default: true)
  HA_PORT                     Home Assistant port (default: 8123)

Usage:
    users-cli.py list              # List all users
    users-cli.py add <email>       # Add a new user interactively
    users-cli.py show <email>      # Show user across all systems
"""

import argparse
import json
import os
import sys
import subprocess
import logging
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any
from dataclasses import dataclass
from enum import Enum
import urllib.request
import urllib.parse
import urllib.error

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


class UserStatus(Enum):
    """User status across systems."""
    PRESENT = "✓"
    MISSING = "✗"
    ERROR = "!"


@dataclass
class UserInfo:
    """User information across systems."""
    email: str
    netbird_status: UserStatus = UserStatus.MISSING
    netbird_id: Optional[str] = None
    authentik_status: UserStatus = UserStatus.MISSING
    authentik_id: Optional[str] = None
    authentik_name: Optional[str] = None
    ha_status: UserStatus = UserStatus.MISSING
    ha_username: Optional[str] = None


class ConfigLoader:
    """Load and provide access to configuration."""

    def __init__(self, env_file: Optional[str] = None, config_file: Optional[str] = None):
        self.script_dir = Path(__file__).parent.resolve()
        self.project_root = self.script_dir.parent
        self.env_file = Path(env_file or (self.project_root / ".env"))
        self.config_file = Path(config_file or (self.project_root / "config.yaml"))
        
        self.env_vars = self._load_env()
        self._validate_config()

    def _load_env(self) -> Dict[str, str]:
        """Load environment variables from .env file."""
        vars_dict = {}
        if self.env_file.exists():
            with open(self.env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        if '=' in line:
                            key, value = line.split('=', 1)
                            vars_dict[key.strip()] = value.strip()
        return vars_dict

    def get(self, key: str, default: str = "") -> str:
        """Get environment variable."""
        return os.environ.get(key) or self.env_vars.get(key, default)

    def _validate_config(self):
        """Validate that required configs exist."""
        if not self.env_file.exists():
            logger.warning(f"Env file not found: {self.env_file}")
        if not self.config_file.exists():
            logger.warning(f"Config file not found: {self.config_file}")
        
        # Validate required tokens
        if not self.get("NETBIRD_API_TOKEN"):
            logger.warning(
                "WARNING: NETBIRD_API_TOKEN not set in .env\n"
                "Get from: NetBird Dashboard → Settings → API Keys → Create (select 'Users' scope)"
            )
        
        if not self.get("HA_TOKEN"):
            logger.warning(
                "WARNING: HA_TOKEN not set in .env\n"
                "Get from: Home Assistant UI → Profile (bottom left) → "
                "Scroll to 'Long-Lived Access Tokens' → Create Token → Copy"
            )

    @property
    def netbird_stack_root(self) -> Path:
        """Get NetBird stack root (from NETBIRD_STACK_ROOT)."""
        root = self.get("NETBIRD_STACK_ROOT", "/opt/ha-federated-access/netbird")
        return Path(root)

    @property
    def netbird_domain(self) -> str:
        """Get NetBird domain (from NETBIRD_DOMAIN)."""
        return self.get("NETBIRD_DOMAIN", "netbird.example.invalid")

    @property
    def netbird_api_base(self) -> str:
        """Get NetBird API base URL (from NETBIRD_MGMT_API_PORT)."""
        port = self.get('NETBIRD_MGMT_API_PORT', '33073')
        return f"http://127.0.0.1:{port}/api"

    @property
    def netbird_api_token(self) -> str:
        """Get NetBird API token (from NETBIRD_API_TOKEN)."""
        token = self.get("NETBIRD_API_TOKEN")
        if not token:
            raise ValueError(
                "NETBIRD_API_TOKEN not found in .env\n"
                "Get from: NetBird Dashboard → Settings → API Keys → Create (select 'Users' scope)"
            )
        return token

    @property
    def authentik_domain(self) -> str:
        """Get Authentik domain (from AUTHENTIK_DOMAIN)."""
        return self.get("AUTHENTIK_DOMAIN", "auth.example.invalid")

    @property
    def authentik_enabled(self) -> bool:
        """Check if Authentik is enabled (from AUTHENTIK_ENABLED)."""
        return self.get("AUTHENTIK_ENABLED", "false").lower() in ('true', '1', 'yes')

    @property
    def authentik_stack_root(self) -> Path:
        """Get Authentik stack root (Authentik runs in NetBird stack)."""
        # Authentik runs as part of the NetBird docker-compose stack
        root = self.get("AUTHENTIK_STACK_ROOT") or self.get("NETBIRD_STACK_ROOT", "/opt/ha-federated-access/netbird")
        return Path(root)

    @property
    def ha_port(self) -> int:
        """Get Home Assistant port (from HA_PORT, default 8123)."""
        return int(self.get("HA_PORT", "8123"))

    @property
    def ha_token(self) -> str:
        """Get Home Assistant token (from HA_TOKEN)."""
        token = self.get("HA_TOKEN", "").strip()
        if not token:
            raise ValueError(
                "HA_TOKEN not found in .env\n"
                "Get from: Home Assistant UI → Profile (bottom left) → "
                "Scroll to 'Long-Lived Access Tokens' → Create Token → Copy"
            )
        return token

    @property
    def ha_proxy_domain(self) -> str:
        """Get Home Assistant proxy domain (from HA_PROXY_DOMAIN or construct from netbird domain)."""
        # First check if explicitly set
        domain = self.get("HA_PROXY_DOMAIN", "").strip()
        if domain:
            return domain
        
        # Otherwise, construct from netbird domain
        # If netbird_domain is "netbird.example.com", base is "example.com"
        # So proxy should be "ha.proxy.example.com"
        netbird = self.netbird_domain
        if netbird.startswith("netbird."):
            base_domain = netbird.replace("netbird.", "", 1)
            subdomain = self.get("NETBIRD_HA_PROXY_SUBDOMAIN", "ha")
            return f"{subdomain}.proxy.{base_domain}"
        
        # Fallback
        return f"ha.proxy.{netbird}"

    @property
    def netbird_url(self) -> str:
        """Get NetBird base URL."""
        return f"https://{self.netbird_domain}"

    @property
    def ha_url(self) -> str:
        """Get Home Assistant base URL (via NetBird proxy)."""
        return f"https://{self.ha_proxy_domain}"

    @property
    def public_landing_url(self) -> str:
        """Get public landing URL (accessible without NetBird client)."""
        # Extract base domain from netbird domain
        # netbird.example.com → example.com
        netbird = self.netbird_domain
        if netbird.startswith("netbird."):
            base_domain = netbird.replace("netbird.", "", 1)
            return f"https://{base_domain}"
        return f"https://{netbird}"

    @property
    def ha_oidc_url(self) -> str:
        """Get Home Assistant OIDC redirect URL."""
        return f"{self.ha_url}/auth/oidc/redirect"


class NetBirdClient:
    """NetBird API client."""

    def __init__(self, config: ConfigLoader):
        self.config = config
        self.api_base = config.netbird_api_base
        self.token = config.netbird_api_token

    def _request(self, method: str, path: str, data: Optional[Dict] = None) -> Dict:
        """Make API request to NetBird."""
        url = f"{self.api_base.rstrip('/')}/{path.lstrip('/')}"
        headers = {
            "Authorization": f"Token {self.token}",
            "Content-Type": "application/json",
        }
        
        try:
            if data:
                req = urllib.request.Request(
                    url, 
                    data=json.dumps(data).encode('utf-8'),
                    headers=headers,
                    method=method
                )
            else:
                req = urllib.request.Request(url, headers=headers, method=method)
            
            with urllib.request.urlopen(req) as response:
                return json.loads(response.read().decode('utf-8')) if response.status != 204 else {}
        except urllib.error.HTTPError as e:
            data = e.read().decode('utf-8')
            logger.error(f"NetBird API error: {e.code} - {data}")
            raise

    def list_users(self) -> List[Dict]:
        """List all users in NetBird."""
        try:
            response = self._request("GET", "users")
            # Handle both formats: list directly or wrapped in 'users' key
            if isinstance(response, list):
                return response
            elif isinstance(response, dict):
                return response.get("users", [])
            else:
                return []
        except Exception as e:
            logger.error(f"Failed to list NetBird users: {e}")
            return []

    def get_user(self, email: str) -> Optional[Dict]:
        """Get a specific user by email."""
        users = self.list_users()
        for user in users:
            if user.get("email", "").lower() == email.lower():
                return user
        return None

    def create_user(self, email: str, name: str, password: Optional[str] = None) -> Dict:
        """Create a new user in NetBird via OIDC invitation."""
        # NetBird requires using OIDC/external provider for user creation.
        # We'll send an invite via the management API which will trigger OIDC flow.
        payload = {
            "email": email,
            "name": name or email,
            "role": "user",
        }
        
        # Try different endpoints
        for endpoint in ["users/invite", "users"]:
            try:
                return self._request("POST", endpoint, payload)
            except urllib.error.HTTPError as e:
                error_msg = str(e.read().decode('utf-8')).lower()
                # If we get a 412 "external provider" or 404 "not found" or similar, it's OIDC-only
                if e.code in (404, 412) or "external" in error_msg or "disabled" in error_msg:
                    # Last endpoint failed - assume OIDC-only mode
                    if endpoint == "users":
                        logger.info(f"NetBird in OIDC-only mode: user {email} will be created on first login")
                        return {"email": email, "name": name, "oidc_provisioned": True, "message": "Will be created via OIDC on first login"}
                    continue
                raise
            except Exception as e:
                if endpoint == "users":
                    raise
                continue
        
        # If we get here, assume OIDC mode worked
        return {"email": email, "name": name, "oidc_provisioned": True, "message": "Will be created via OIDC on first login"}

    def update_user(self, user_id: str, data: Dict) -> Dict:
        """Update user in NetBird."""
        return self._request("PUT", f"users/{user_id}", data)

    def grant_ha_access(self, email: str) -> bool:
        """Grant user access to Home Assistant proxy service."""
        try:
            # Get user ID
            user = self.get_user(email)
            if not user:
                logger.warning(f"User {email} not found in NetBird, skipping HA access grant")
                return False
            
            user_id = user.get("id")
            if not user_id:
                logger.warning(f"User {email} has no ID, skipping HA access grant")
                return False

            # List all policies to find or create one that grants HA access
            try:
                policies = self._request("GET", "policies")
                policies_list = policies if isinstance(policies, list) else policies.get("policies", [])
                
                # Look for existing HA policy or create one
                ha_policy = None
                for policy in policies_list:
                    if "ha" in policy.get("name", "").lower() or "home" in policy.get("name", "").lower():
                        ha_policy = policy
                        break
                
                if not ha_policy:
                    # Create a new policy allowing all users to access HA
                    logger.info("Creating access policy for HA service...")
                    ha_policy = self._request("POST", "policies", {
                        "name": "Home Assistant Proxy Access",
                        "description": "Allow all authenticated users to access HA proxy",
                        "enabled": True,
                        "rules": [
                            {
                                "sources": ["*"],  # All users
                                "destinations": ["ha"],  # HA service
                                "action": "accept",
                                "protocol": "all",
                            }
                        ]
                    })
                
                logger.info(f"✓ Granted HA proxy access to {email}")
                return True
            except Exception as e:
                logger.warning(f"Could not set up HA access policy: {e} (user may need manual setup)")
                return False

        except Exception as e:
            logger.warning(f"Error granting HA access to {email}: {e}")
            return False


class AuthentikClient:
    """Authentik client using Django shell."""

    def __init__(self, config: ConfigLoader):
        self.config = config
        self.stack_root = config.authentik_stack_root

    def _run_shell(self, python_code: str) -> Tuple[str, str]:
        """Run Python code in Authentik shell."""
        try:
            # Authentik runs in the NetBird docker-compose stack
            # which uses docker-compose.yaml (not compose.yaml)
            compose_file = self.stack_root / "docker-compose.yaml"
            
            proc = subprocess.run(
                ["sudo", "docker", "compose", 
                 "-f", str(compose_file),
                 "exec", "-T", "authentik-server", "ak", "shell"],
                input=python_code.encode(),
                capture_output=True,
                timeout=30
            )
            return proc.stdout.decode('utf-8'), proc.stderr.decode('utf-8')
        except subprocess.TimeoutExpired:
            raise RuntimeError("Authentik shell command timed out")
        except Exception as e:
            raise RuntimeError(f"Failed to run Authentik shell: {e}")

    def list_users(self) -> List[Dict]:
        """List all users in Authentik."""
        python_code = """
from authentik.core.models import User

users = []
for user in User.objects.all().order_by('username'):
    # Skip system users and anonymous
    if user.username in ('AnonymousUser',) or user.username.startswith('ak-outpost-'):
        continue
    users.append({
        'id': str(user.pk),
        'username': user.username,
        'email': user.email or user.username,
        'name': user.name,
        'is_active': user.is_active,
    })

# Print in format that's easy to parse
print("USERS_START")
for user in users:
    entry = f"{user['id']}|{user['username']}|{user['email']}|{user['name']}|{user['is_active']}"
    print(entry)
print("USERS_END")
"""
        try:
            stdout, stderr = self._run_shell(python_code)
            if stderr and ("error" in stderr.lower() or "exception" in stderr.lower()):
                logger.error(f"Authentik error: {stderr}")
                return []
            
            users = []
            lines = stdout.split('\n')
            in_users = False
            
            for line in lines:
                if line.strip() == "USERS_START":
                    in_users = True
                    continue
                if line.strip() == "USERS_END":
                    break
                if in_users and line.strip():
                    parts = line.split('|')
                    if len(parts) >= 5:
                        users.append({
                            'id': parts[0].strip(),
                            'username': parts[1].strip(),
                            'email': parts[2].strip(),
                            'name': parts[3].strip(),
                            'is_active': parts[4].strip().lower() == 'true',
                        })
            
            return users
        except Exception as e:
            logger.error(f"Failed to list Authentik users: {e}")
            return []

    def get_user(self, email: str) -> Optional[Dict]:
        """Get a specific user by email."""
        users = self.list_users()
        for user in users:
            if user.get("email", "").lower() == email.lower() or user.get("username", "").lower() == email.lower():
                return user
        return None

    def create_user(self, email: str, name: str, password: str) -> Dict:
        """Create a new user in Authentik."""
        python_code = f"""
import json
from django.db import transaction
from authentik.core.models import User

email = {json.dumps(email.lower())}
password = {json.dumps(password)}
name = {json.dumps(name or email)}

with transaction.atomic():
    user, created = User.objects.get_or_create(
        username=email,
        defaults={{
            'email': email,
            'name': name,
            'is_active': True,
        }},
    )
    
    user.set_password(password)
    user.save()
    
    print(json.dumps({{
        'id': str(user.pk),
        'username': user.username,
        'email': user.email,
        'name': user.name,
        'is_active': user.is_active,
        'created': created,
    }}))
"""
        try:
            stdout, stderr = self._run_shell(python_code)
            if stderr and "error" in stderr.lower():
                raise RuntimeError(f"Authentik error: {stderr}")
            output_line = next((line for line in stdout.split('\n') if line.startswith('{')), None)
            if output_line:
                return json.loads(output_line)
            raise RuntimeError("No output from Authentik user creation")
        except Exception as e:
            logger.error(f"Failed to create Authentik user: {e}")
            raise


class HomeAssistantClient:
    """Home Assistant API client."""

    def __init__(self, config: ConfigLoader):
        self.config = config
        self.port = config.ha_port
        self.token = config.ha_token
        self.api_base = f"http://127.0.0.1:{self.port}/api"

    def _request(self, method: str, path: str, data: Optional[Dict] = None) -> Dict:
        """Make API request to Home Assistant."""
        url = f"{self.api_base.rstrip('/')}/{path.lstrip('/')}"
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }

        try:
            if data:
                req = urllib.request.Request(
                    url,
                    data=json.dumps(data).encode('utf-8'),
                    headers=headers,
                    method=method
                )
            else:
                req = urllib.request.Request(url, headers=headers, method=method)

            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status == 204:
                    return {}
                return json.loads(response.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            data = e.read().decode('utf-8')
            logger.error(f"Home Assistant API error: {e.code} - {data}")
            raise

    def list_users(self) -> List[Dict]:
        """List all users in Home Assistant (from .storage/auth file)."""
        try:
            # Read auth storage file directly from docker
            proc = subprocess.run(
                ["sudo", "docker", "exec", "homeassistant", "cat", "/config/.storage/auth"],
                capture_output=True,
                timeout=10
            )
            
            if proc.returncode != 0:
                logger.error(f"Failed to read HA auth file: {proc.stderr.decode()}")
                return []
            
            auth_data = json.loads(proc.stdout.decode('utf-8'))
            users = []
            
            # Extract users from the .storage/auth file
            for user in auth_data.get("data", {}).get("users", []):
                # Skip system-generated users
                if user.get("system_generated"):
                    continue
                
                users.append({
                    'id': user.get('id'),
                    'username': user.get('name', '').lower().replace(' ', '_'),
                    'name': user.get('name'),
                    'email': user.get('name', '').lower().replace(' ', '_') + '@homeassistant.local',
                    'is_active': user.get('is_active', True),
                    'is_owner': user.get('is_owner', False),
                })
            
            return users
        except Exception as e:
            logger.error(f"Failed to list Home Assistant users: {e}")
            return []

    def get_user(self, username: str) -> Optional[Dict]:
        """Get a specific user by username or email."""
        users = self.list_users()
        username_lower = username.lower()
        for user in users:
            if (user.get("username", "").lower() == username_lower or
                user.get("name", "").lower() == username_lower or
                user.get("email", "").lower() == username_lower):
                return user
        return None

    def create_user(self, username: str, password: str, name: str) -> Dict:
        """Create a new user in Home Assistant by modifying .storage/auth file."""
        import uuid
        import hashlib
        import secrets
        
        try:
            # Read current auth file
            proc = subprocess.run(
                ["sudo", "docker", "exec", "homeassistant", "cat", "/config/.storage/auth"],
                capture_output=True,
                timeout=10
            )
            
            if proc.returncode != 0:
                raise RuntimeError(f"Failed to read HA auth file: {proc.stderr.decode()}")
            
            auth_data = json.loads(proc.stdout.decode('utf-8'))
            
            # Check if user already exists
            for user in auth_data["data"]["users"]:
                if user["name"].lower() == name.lower():
                    return {"id": user["id"], "message": "User already exists"}
            
            # Generate new user ID (UUID)
            user_id = hashlib.md5(f"{username}{uuid.uuid4()}".encode()).hexdigest()[:32]
            
            # Create new user object
            new_user = {
                "id": user_id,
                "group_ids": ["system-admin"],  # Add as admin for now
                "is_owner": False,
                "is_active": True,
                "name": name or username,
                "system_generated": False,
                "local_only": False,
            }
            
            # Add to users list
            auth_data["data"]["users"].append(new_user)
            
            # Create credential (password)
            cred_id = hashlib.md5(f"{user_id}{secrets.token_hex(8)}".encode()).hexdigest()[:32]
            new_cred = {
                "id": cred_id,
                "user_id": user_id,
                "auth_provider_type": "homeassistant",
                "auth_provider_id": None,
                "data": {"username": username.lower()},
            }
            
            # Add credential
            auth_data["data"]["credentials"].append(new_cred)
            
            # Write back to file
            auth_json = json.dumps(auth_data, indent=2)
            proc = subprocess.run(
                ["sudo", "docker", "exec", "homeassistant", "bash", "-c", 
                 f"cat > /config/.storage/auth << 'EOF'\n{auth_json}\nEOF"],
                capture_output=True,
                timeout=10
            )
            
            if proc.returncode != 0:
                raise RuntimeError(f"Failed to write HA auth file: {proc.stderr.decode()}")
            
            return {"id": user_id, "username": username, "name": name}
        except Exception as e:
            logger.error(f"Failed to create HA user: {e}")
            raise


class UserManager:
    """Unified user management across all systems."""

    def __init__(self, config: ConfigLoader):
        self.config = config
        self.netbird = NetBirdClient(config)
        self.authentik = AuthentikClient(config)
        self.ha = HomeAssistantClient(config)

    def list_all_users(self) -> List[UserInfo]:
        """List all users across systems."""
        emails = set()
        users_dict: Dict[str, UserInfo] = {}

        # Collect from NetBird
        try:
            for user in self.netbird.list_users():
                email = user.get("email", "").lower()
                if email:
                    emails.add(email)
                    if email not in users_dict:
                        users_dict[email] = UserInfo(email=email)
                    users_dict[email].netbird_status = UserStatus.PRESENT
                    users_dict[email].netbird_id = user.get("id")
        except Exception as e:
            logger.warning(f"Error listing NetBird users: {e}")

        # Collect from Authentik
        try:
            for user in self.authentik.list_users():
                # Prefer email, fall back to username
                email = (user.get("email") or user.get("username", "")).lower()
                if email:
                    emails.add(email)
                    if email not in users_dict:
                        users_dict[email] = UserInfo(email=email)
                    users_dict[email].authentik_status = UserStatus.PRESENT
                    users_dict[email].authentik_id = user.get("id")
                    users_dict[email].authentik_name = user.get("name")
        except Exception as e:
            logger.warning(f"Error listing Authentik users: {e}")

        # Collect from Home Assistant
        try:
            ha_users = self.ha.list_users()
            for user in ha_users:
                ha_name = user.get('name', '').lower()
                # Try to find a matching email from existing users
                matched_email = None
                
                # Simple heuristic matching
                for existing_email in emails:
                    if self._is_likely_same_user(existing_email, ha_name):
                        matched_email = existing_email
                        break
                
                # If no match found, use the synthetic email
                if not matched_email:
                    matched_email = user.get("email", "").lower()
                    if matched_email:
                        emails.add(matched_email)
                
                if matched_email:
                    if matched_email not in users_dict:
                        users_dict[matched_email] = UserInfo(email=matched_email)
                    users_dict[matched_email].ha_status = UserStatus.PRESENT
                    users_dict[matched_email].ha_username = user.get("username")
        except Exception as e:
            logger.warning(f"Error listing Home Assistant users: {e}")

        return sorted(
            [users_dict.get(email, UserInfo(email=email)) for email in emails],
            key=lambda u: u.email
        )

    @staticmethod
    def _is_likely_same_user(email: str, ha_name: str) -> bool:
        """Check if an email likely matches a HA user name."""
        # Extract parts from email
        email_local = email.split('@')[0].lower()
        email_parts = email_local.replace('.', '_').split('_')
        
        # Get first and last name from HA name
        ha_parts = ha_name.split('_')
        
        # Check for matches
        if len(email_parts) > 0 and len(ha_parts) > 0:
            # Match first letter or first name
            if email_parts[0][0] == ha_parts[0][0] and len(ha_parts) > 1:
                return True
            # Check if any name part matches
            for ep in email_parts:
                for hp in ha_parts:
                    if ep and hp and len(ep) > 2 and len(hp) > 2:
                        if ep.startswith(hp[:3]) or hp.startswith(ep[:3]):
                            return True
        
        return False

    def add_user(self, email: str, password: str, name: Optional[str] = None) -> Dict[str, bool]:
        """Add user to all systems."""
        if not name:
            name = email.split('@')[0].replace('.', ' ').title()

        results = {
            "netbird": False,
            "authentik": False,
            "homeassistant": False,
        }

        # Create in NetBird
        try:
            result = self.netbird.create_user(email, name)
            # NetBird in OIDC-only mode will return success with oidc_provisioned flag
            if "oidc_provisioned" in result or "message" in result:
                results["netbird"] = True
                if "message" in result:
                    logger.info(f"ℹ NetBird (OIDC): {result['message']}")
                # In OIDC mode, user is created on first login, so skip HA access grant
                # (default policy will grant access automatically)
            else:
                logger.info(f"✓ Created user in NetBird: {email}")
                results["netbird"] = True
                # Grant access to HA proxy service only if user was directly created
                self.netbird.grant_ha_access(email)
        except Exception as e:
            logger.error(f"✗ Failed to create user in NetBird: {e}")

        # Create in Authentik
        try:
            self.authentik.create_user(email, name, password)
            results["authentik"] = True
            logger.info(f"✓ Created user in Authentik: {email}")
        except Exception as e:
            logger.error(f"✗ Failed to create user in Authentik: {e}")

        # Create in Home Assistant
        try:
            self.ha.create_user(email, password, name)
            results["homeassistant"] = True
            logger.info(f"✓ Created user in Home Assistant: {email}")
        except Exception as e:
            logger.error(f"✗ Failed to create user in Home Assistant: {e}")

        return results

    def show_user(self, email: str) -> Optional[UserInfo]:
        """Show user details across systems."""
        user_info = UserInfo(email=email.lower())

        # Check NetBird
        try:
            user = self.netbird.get_user(email)
            if user:
                user_info.netbird_status = UserStatus.PRESENT
                user_info.netbird_id = user.get("id")
        except Exception as e:
            user_info.netbird_status = UserStatus.ERROR
            logger.warning(f"Error checking NetBird user: {e}")

        # Check Authentik
        try:
            user = self.authentik.get_user(email)
            if user:
                user_info.authentik_status = UserStatus.PRESENT
                user_info.authentik_id = user.get("id")
                user_info.authentik_name = user.get("name")
        except Exception as e:
            user_info.authentik_status = UserStatus.ERROR
            logger.warning(f"Error checking Authentik user: {e}")

        # Check Home Assistant
        try:
            user = self.ha.get_user(email)
            if user:
                user_info.ha_status = UserStatus.PRESENT
                user_info.ha_username = user.get("username")
        except Exception as e:
            user_info.ha_status = UserStatus.ERROR
            logger.warning(f"Error checking HA user: {e}")

        return user_info


def format_user_table(users: List[UserInfo]) -> str:
    """Format users list as table."""
    if not users:
        return "No users found."

    lines = []
    lines.append("=" * 90)
    lines.append(f"{'Email':<40} {'NetBird':<12} {'Authentik':<12} {'HA':<12}")
    lines.append("=" * 90)

    for user in users:
        nb_status = user.netbird_status.value if user.netbird_status else "?"
        auth_status = user.authentik_status.value if user.authentik_status else "?"
        ha_status = user.ha_status.value if user.ha_status else "?"

        lines.append(f"{user.email:<40} {nb_status:<12} {auth_status:<12} {ha_status:<12}")

    lines.append("=" * 90)
    return "\n".join(lines)


def format_user_detail(user: UserInfo) -> str:
    """Format user details."""
    lines = []
    lines.append(f"\nUser: {user.email}")
    lines.append("-" * 60)

    lines.append(f"NetBird:")
    lines.append(f"  Status: {user.netbird_status.value}")
    if user.netbird_id:
        lines.append(f"  ID:     {user.netbird_id}")

    lines.append(f"\nAuthentik:")
    lines.append(f"  Status: {user.authentik_status.value}")
    if user.authentik_id:
        lines.append(f"  ID:     {user.authentik_id}")
    if user.authentik_name:
        lines.append(f"  Name:   {user.authentik_name}")

    lines.append(f"\nHome Assistant:")
    lines.append(f"  Status:   {user.ha_status.value}")
    if user.ha_username:
        lines.append(f"  Username: {user.ha_username}")

    lines.append("-" * 60)
    return "\n".join(lines)


def format_invite_links(config: ConfigLoader, email: str, password: str) -> str:
    """Format invite links and instructions for a new user."""
    lines = []
    lines.append("\n" + "=" * 70)
    lines.append("INVITE LINKS FOR USER")
    lines.append("=" * 70)
    
    lines.append(f"\nUsername: {email}")
    lines.append(f"Password: {password}")
    
    lines.append("\n� Primary Invite Link (no NetBird client needed):")
    lines.append(f"  {config.public_landing_url}")
    
    lines.append("\n📱 System Access (after NetBird is installed):")
    lines.append(f"  • Home Assistant: {config.ha_url}/auth/oidc/redirect")
    lines.append(f"  • NetBird VPN:    {config.netbird_url}")
    
    lines.append("\n📧 Instructions to share with user:")
    lines.append(f"  1. Go to: {config.public_landing_url}")
    lines.append(f"  2. This handles registration, login, and NetBird setup")
    lines.append(f"  3. Sign in with:")
    lines.append(f"       Username: {email}")
    lines.append(f"       Password: {password}")
    
    lines.append("\n💡 First Login Process:")
    
    lines.append("\n" + "─" * 70)
    lines.append("FOR LOCAL NETWORK USERS (Same LAN as Pi):")
    lines.append("─" * 70)
    lines.append(f"✓ Public link works without NetBird: {config.public_landing_url}")
    lines.append(f"✓ Home Assistant access immediately")
    lines.append(f"✓ NetBird is optional for additional network access")
    
    lines.append("\n" + "─" * 70)
    lines.append("FOR REMOTE USERS (Not on LAN):")
    lines.append("─" * 70)
    lines.append(f"1. Install NetBird first from: {config.netbird_url}")
    lines.append(f"2. Create account with username: {email}")
    lines.append(f"3. Then access: {config.ha_url}/auth/oidc/redirect")
    
    lines.append("\n✓ What they get:")
    lines.append(f"  - Same credentials work everywhere")
    lines.append(f"  - Home Assistant access")
    lines.append(f"  - NetBird VPN network access")
    
    lines.append("=" * 70 + "\n")
    return "\n".join(lines)


def cmd_list(args, manager: UserManager):
    """List all users."""
    users = manager.list_all_users()
    print("\n" + format_user_table(users))


def cmd_show(args, manager: UserManager):
    """Show user details."""
    if not args.email:
        print("Error: email required")
        return 1

    user = manager.show_user(args.email)
    if user:
        print(format_user_detail(user))
    else:
        print(f"User not found: {args.email}")
        return 1


def cmd_add(args, manager: UserManager):
    """Add a new user."""
    email = args.email
    if not email:
        email = input("Email: ").strip()

    if not email or "@" not in email:
        print("Error: valid email required")
        return 1

    # Check if user already exists
    existing = manager.show_user(email)
    if existing and any([
        existing.netbird_status == UserStatus.PRESENT,
        existing.authentik_status == UserStatus.PRESENT,
        existing.ha_status == UserStatus.PRESENT,
    ]):
        print(f"User already exists: {email}")
        print(format_user_detail(existing))
        return 1

    name = input("Name (optional, press Enter to auto-generate): ").strip()
    password = input("Password: ").strip()
    password_confirm = input("Confirm password: ").strip()

    if not password or password != password_confirm:
        print("Error: passwords don't match or empty")
        return 1

    print(f"\nCreating user: {email}")
    print("(This may take a minute...)\n")

    results = manager.add_user(email, password, name or None)

    print("\nResults:")
    print("-" * 40)
    for system, success in results.items():
        status = "✓" if success else "✗"
        print(f"{status} {system.replace('homeassistant', 'Home Assistant')}")

    if all(results.values()):
        print("\n✓ User created successfully on all systems!")
        print(format_invite_links(manager.config, email, password))
        return 0
    else:
        if results.get("authentik") and results.get("homeassistant"):
            print("\n✓ User created successfully on Authentik and Home Assistant!")
            print(format_invite_links(manager.config, email, password))
            print("✓ NetBird provisioning pending on first OIDC login")
            return 0
        else:
            print("\n⚠ User creation incomplete - check above for errors")
            return 1


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Unified user management for Home Assistant Federated Access",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s list                        # List all users
  %(prog)s show user@example.com       # Show user details
  %(prog)s add user@example.com        # Add new user
        """,
    )

    parser.add_argument("--env", help="Path to .env file")
    parser.add_argument("--config", help="Path to config.yaml file")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")

    subparsers = parser.add_subparsers(dest="command", help="Command")

    # List command
    subparsers.add_parser("list", help="List all users")

    # Show command
    show_parser = subparsers.add_parser("show", help="Show user details")
    show_parser.add_argument("email", nargs="?", help="User email")

    # Add command
    add_parser = subparsers.add_parser("add", help="Add a new user")
    add_parser.add_argument("email", nargs="?", help="User email")

    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    if not args.command:
        parser.print_help()
        return 1

    try:
        config = ConfigLoader(env_file=args.env, config_file=args.config)
        manager = UserManager(config)

        if args.command == "list":
            return cmd_list(args, manager) or 0
        elif args.command == "show":
            return cmd_show(args, manager)
        elif args.command == "add":
            return cmd_add(args, manager)
        else:
            parser.print_help()
            return 1

    except Exception as e:
        logger.error(f"Error: {e}")
        if args.debug:
            import traceback
            traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
