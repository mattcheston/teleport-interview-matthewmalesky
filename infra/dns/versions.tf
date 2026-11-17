terraform {
  required_version = ">= 1.5.0"
  required_providers {
    dnsimple = {
      source  = "dnsimple/dnsimple"
      version = "~> 2.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
  }
}

# Credentials come from DNSIMPLE_TOKEN and DNSIMPLE_ACCOUNT in the environment.
# scripts/dns-apply.sh checks for them (and derives the account from the token).
provider "dnsimple" {}

# Reads the load balancer addresses from the cluster the records point at.
provider "kubernetes" {
  config_path = local.kubeconfig_path
}
