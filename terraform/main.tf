terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  # DIGITALOCEAN_TOKEN is exported by the Makefile.
}

variable "droplet_name" {
  type    = string
  default = "zapptunnel"
}

variable "region" {
  type        = string
  default     = "nyc3"
  description = "DigitalOcean region for the public relay."
}

variable "size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Droplet size for Zaptunnel, Prometheus, and remote Nix builds."
}

variable "ssh_key_fingerprint" {
  type        = string
  description = "Fingerprint of the SSH key to install on the relay droplet. Set by the Makefile from SSH_PUBLIC_KEY."

  validation {
    condition     = length(var.ssh_key_fingerprint) > 0
    error_message = "ssh_key_fingerprint must be set; run OpenTofu through the repository Makefile."
  }
}

variable "nix_channel" {
  type        = string
  default     = "nixos-25.05"
  description = "NixOS channel used by nixos-infect for the initial bootstrap."
}

variable "nixos_infect_revision" {
  type        = string
  default     = "40f62a680bb0e8f2f607d79abfaaecd99d59401c"
  description = "Audited nixos-infect Git revision used for the root bootstrap script."
}

variable "dns_domain" {
  type        = string
  default     = "zapptunnel.com"
  description = "Existing DigitalOcean-managed DNS zone."
}

resource "digitalocean_droplet" "zapptunnel" {
  name     = var.droplet_name
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.size
  ssh_keys = [var.ssh_key_fingerprint]
  ipv6     = true

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    nix_channel           = var.nix_channel
    nixos_infect_revision = var.nixos_infect_revision
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }

  tags = ["zapptunnel", "nixos"]
}

resource "digitalocean_firewall" "zapptunnel" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.zapptunnel.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_record" "apex_a" {
  domain = var.dns_domain
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.zapptunnel.ipv4_address
  ttl    = 300
}

resource "digitalocean_record" "apex_aaaa" {
  domain = var.dns_domain
  type   = "AAAA"
  name   = "@"
  value  = digitalocean_droplet.zapptunnel.ipv6_address
  ttl    = 300
}

resource "digitalocean_record" "relay_a" {
  domain = var.dns_domain
  type   = "A"
  name   = "relay"
  value  = digitalocean_droplet.zapptunnel.ipv4_address
  ttl    = 300
}

resource "digitalocean_record" "relay_aaaa" {
  domain = var.dns_domain
  type   = "AAAA"
  name   = "relay"
  value  = digitalocean_droplet.zapptunnel.ipv6_address
  ttl    = 300
}

output "ipv4" {
  value       = digitalocean_droplet.zapptunnel.ipv4_address
  description = "Public IPv4 address of the relay."
}

output "ipv6" {
  value       = digitalocean_droplet.zapptunnel.ipv6_address
  description = "Public IPv6 address of the relay."
}

output "website_url" {
  value       = "https://${var.dns_domain}"
  description = "Public website URL."
}

output "relay_url" {
  value       = "https://relay.${var.dns_domain}"
  description = "SDK and tunnel relay URL."
}

output "deploy_command" {
  value       = "nixos-rebuild switch --flake .#zapptunnel --target-host root@${digitalocean_droplet.zapptunnel.ipv4_address} --build-host root@${digitalocean_droplet.zapptunnel.ipv4_address}"
  description = "Command used by make deploy."
}
