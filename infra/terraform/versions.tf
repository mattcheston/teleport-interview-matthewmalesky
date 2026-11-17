terraform {
  required_version = ">= 1.5.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.107"
    }
  }
}

# Credentials come from DIGITALOCEAN_TOKEN in the environment.
# scripts/kubeadm-up.sh exports it from `doctl auth token`.
provider "digitalocean" {}
