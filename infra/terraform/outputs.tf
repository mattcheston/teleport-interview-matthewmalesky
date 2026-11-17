output "control_plane_public_ip" {
  value = digitalocean_droplet.control_plane.ipv4_address
}

output "control_plane_private_ip" {
  value = digitalocean_droplet.control_plane.ipv4_address_private
}

output "worker_public_ips" {
  description = "Space separated, for shell loops."
  value       = join(" ", digitalocean_droplet.worker[*].ipv4_address)
}

output "node_names" {
  description = "Droplet names double as Kubernetes node names; the cloud controller manager relies on that."
  value       = join(" ", concat([digitalocean_droplet.control_plane.name], digitalocean_droplet.worker[*].name))
}

output "worker_tag" {
  description = "Tag the cloud controller manager applies its load balancer firewall to (PUBLIC_ACCESS_FIREWALL_TAGS)."
  value       = digitalocean_tag.worker.name
}

output "vpc_cidr" {
  value = digitalocean_vpc.this.ip_range
}

output "vpc_id" {
  description = "Passed to the cloud controller manager as DO_CLUSTER_VPC_ID so load balancers are created in the nodes' VPC."
  value       = digitalocean_vpc.this.id
}
