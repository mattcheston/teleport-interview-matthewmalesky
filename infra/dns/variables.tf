variable "zone_name" {
  description = "DNS zone at DNSimple that the records are created in."
  type        = string
  default     = "mattcheston.com"
}

variable "kubeconfig_path" {
  description = "Kubeconfig for the cluster whose LoadBalancer Services provide the addresses. Defaults to the one scripts/kubeadm-up.sh writes."
  type        = string
  default     = null
}

variable "ttl" {
  description = "TTL in seconds for every record. Short, so a rebuilt load balancer is picked up quickly."
  type        = number
  default     = 300
}

variable "load_balancers" {
  description = <<-EOT
    LoadBalancer Services to publish, keyed by a short label. Each gets one A
    record per entry in `names` (relative to zone_name; "*" prefixes make
    wildcards). A Service that does not exist yet, or has no address yet, is
    skipped and reported in the `pending` output; re-apply once it is there.
  EOT
  type = map(object({
    namespace = string
    service   = string
    names     = list(string)
  }))
  default = {
    # Teleport proxy: the cluster name and the wildcard every published app
    # (nginx, argocd, ...) lives under.
    teleport = {
      namespace = "teleport"
      service   = "teleport-cluster"
      names     = ["teleport", "*.teleport"]
    }
    # Traefik: the Ingress for the landing page (nginx/values.yaml ingress.host).
    traefik = {
      namespace = "traefik"
      service   = "traefik"
      names     = ["nginx"]
    }
  }
}
