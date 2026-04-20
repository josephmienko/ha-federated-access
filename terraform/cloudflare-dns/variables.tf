# Cloudflare Configuration
variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API Token with DNS Edit permissions"
  sensitive   = true
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for the managed DNS zone"
}

variable "cloudflare_zone_name" {
  type        = string
  description = "Authoritative DNS zone name for the project"
}

variable "server_public_ip" {
  type        = string
  description = "The static public IP of your NetBird host"
}

variable "netbird_domain" {
  type        = string
  description = "Canonical public FQDN used by the NetBird dashboard, management API, signal server, and TURN/STUN lookups"

  validation {
    condition     = can(regex("\\.${replace(var.cloudflare_zone_name, ".", "\\.")}$", var.netbird_domain)) || var.netbird_domain == var.cloudflare_zone_name
    error_message = "netbird_domain must live inside cloudflare_zone_name."
  }
}

variable "netbird_proxy_domain" {
  type        = string
  description = "Base domain used by the NetBird reverse proxy service for browser-accessible apps"
  default     = null

  validation {
    condition = (
      var.netbird_proxy_domain == null ||
      can(regex("\\.${replace(var.cloudflare_zone_name, ".", "\\.")}$", var.netbird_proxy_domain)) ||
      var.netbird_proxy_domain == var.cloudflare_zone_name
    )
    error_message = "netbird_proxy_domain must live inside cloudflare_zone_name when set."
  }
}

variable "authentik_domain" {
  type        = string
  description = "Public FQDN used by the optional Authentik broker"
  default     = null

  validation {
    condition = (
      var.authentik_domain == null ||
      can(regex("\\.${replace(var.cloudflare_zone_name, ".", "\\.")}$", var.authentik_domain)) ||
      var.authentik_domain == var.cloudflare_zone_name
    )
    error_message = "authentik_domain must live inside cloudflare_zone_name when set."
  }
}

variable "netbird_dns_ttl" {
  type        = number
  description = "TTL to use for the direct NetBird A record"
  default     = 300
}
