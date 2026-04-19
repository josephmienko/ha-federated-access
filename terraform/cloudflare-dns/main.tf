terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  netbird_record_name       = var.netbird_domain == var.cloudflare_zone_name ? "@" : trimsuffix(var.netbird_domain, ".${var.cloudflare_zone_name}")
  netbird_proxy_domain      = coalesce(var.netbird_proxy_domain, "proxy.${var.cloudflare_zone_name}")
  netbird_proxy_record_name = local.netbird_proxy_domain == var.cloudflare_zone_name ? "@" : trimsuffix(local.netbird_proxy_domain, ".${var.cloudflare_zone_name}")
  netbird_proxy_wildcard    = local.netbird_proxy_record_name == "@" ? "*" : "*.${local.netbird_proxy_record_name}"
  authentik_domain          = coalesce(var.authentik_domain, "auth.${var.cloudflare_zone_name}")
  authentik_record_name     = local.authentik_domain == var.cloudflare_zone_name ? "@" : trimsuffix(local.authentik_domain, ".${var.cloudflare_zone_name}")
}

# Apex landing hostname for Crooked Sentry. Traefik on the NetBird host owns
# the redirect so the apex remains a single-purpose browser entrypoint.
resource "cloudflare_record" "landing_apex" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = var.server_public_ip
  type    = "A"
  ttl     = var.netbird_dns_ttl
  proxied = false
}

# NetBird uses direct non-proxied DNS records so Let's Encrypt and Traefik TLS
# passthrough work without Cloudflare intercepting the certificate flow.
resource "cloudflare_record" "netbird_direct" {
  zone_id = var.cloudflare_zone_id
  name    = local.netbird_record_name
  content = var.server_public_ip
  type    = "A"
  ttl     = var.netbird_dns_ttl
  proxied = false
}

resource "cloudflare_record" "netbird_proxy_base" {
  zone_id = var.cloudflare_zone_id
  name    = local.netbird_proxy_record_name
  content = var.server_public_ip
  type    = "A"
  ttl     = var.netbird_dns_ttl
  proxied = false
}

resource "cloudflare_record" "netbird_proxy_wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = local.netbird_proxy_wildcard
  content = var.server_public_ip
  type    = "A"
  ttl     = var.netbird_dns_ttl
  proxied = false
}

resource "cloudflare_record" "authentik_direct" {
  zone_id = var.cloudflare_zone_id
  name    = local.authentik_record_name
  content = var.server_public_ip
  type    = "A"
  ttl     = var.netbird_dns_ttl
  proxied = false
}

output "netbird_dashboard_url" {
  value       = "https://${var.netbird_domain}"
  description = "Dashboard URL fronted by Traefik on the NetBird host"
}

output "netbird_management_api_url" {
  value       = "https://${var.netbird_domain}/api"
  description = "Management API URL exposed through Traefik on the NetBird host"
}

output "netbird_proxy_base_url" {
  value       = "https://${local.netbird_proxy_domain}"
  description = "Base NetBird reverse proxy domain for browser-accessible services"
}

output "netbird_proxy_example_ha_url" {
  value       = "https://ha.${local.netbird_proxy_domain}"
  description = "Example Home Assistant URL if you expose it through the NetBird reverse proxy"
}

output "authentik_url" {
  value       = "https://${local.authentik_domain}"
  description = "Public Authentik URL for shared OIDC across NetBird and Home Assistant"
}

output "landing_url" {
  value       = "https://${var.cloudflare_zone_name}"
  description = "Apex landing URL that redirects users into the Home Assistant OIDC entrypoint"
}
