# One control plane + N workers on DigitalOcean droplets, prepared for kubeadm
# by cloud-init. kubeadm init/join and the cluster add-ons are run afterwards
# by scripts/kubeadm-up.sh; nothing here talks to the Kubernetes API.

data "digitalocean_ssh_key" "admin" {
  name = var.ssh_key_name
}

locals {
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    kubernetes_minor = var.kubernetes_minor
  })
}

resource "digitalocean_tag" "cluster" {
  name = var.cluster_name
}

resource "digitalocean_tag" "control_plane" {
  name = "${var.cluster_name}-control-plane"
}

# The cloud controller manager applies its load balancer firewall to this tag.
resource "digitalocean_tag" "worker" {
  name = "${var.cluster_name}-worker"
}

resource "digitalocean_vpc" "this" {
  name     = var.cluster_name
  region   = var.region
  ip_range = var.vpc_cidr
}

resource "digitalocean_droplet" "control_plane" {
  name      = "${var.cluster_name}-cp-1"
  region    = var.region
  size      = var.control_plane_size
  image     = var.image
  vpc_uuid  = digitalocean_vpc.this.id
  ssh_keys  = [data.digitalocean_ssh_key.admin.id]
  user_data = local.user_data
  tags      = [digitalocean_tag.cluster.name, digitalocean_tag.control_plane.name]
}

resource "digitalocean_droplet" "worker" {
  count = var.worker_count

  name      = "${var.cluster_name}-worker-${count.index + 1}"
  region    = var.region
  size      = var.worker_size
  image     = var.image
  vpc_uuid  = digitalocean_vpc.this.id
  ssh_keys  = [data.digitalocean_ssh_key.admin.id]
  user_data = local.user_data
  tags      = [digitalocean_tag.cluster.name, digitalocean_tag.worker.name]
}

# Groups the droplets in their own DigitalOcean project. Resources the cluster
# creates for itself later (the Teleport load balancer via the cloud controller
# manager, volumes via the CSI driver) land in the account's default project.
resource "digitalocean_project" "this" {
  name        = var.cluster_name
  description = "kubeadm cluster for the Teleport interview demo"
  purpose     = "Web Application"
  environment = "Development"
  resources = concat(
    [digitalocean_droplet.control_plane.urn],
    digitalocean_droplet.worker[*].urn,
  )
}

# Cloud firewalls filter the private interface too, so node-to-node traffic
# (kubelet, etcd, Cilium's VXLAN overlay, health checks) is allowed by VPC
# range. SSH and the API server are open to the operator only. Load balancer
# traffic is deliberately not handled here: the cloud controller manager
# manages a second firewall (PUBLIC_ACCESS_FIREWALL_NAME, set by
# scripts/kubeadm-up.sh) and opens each Service's ports plus the health-check
# port for exactly the load balancer it created.
resource "digitalocean_firewall" "nodes" {
  name = "${var.cluster_name}-nodes"
  tags = [digitalocean_tag.cluster.name]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.admin_cidrs
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "6443"
    source_addresses = var.admin_cidrs
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "1-65535"
    source_addresses = [var.vpc_cidr]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "1-65535"
    source_addresses = [var.vpc_cidr]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = [var.vpc_cidr]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
