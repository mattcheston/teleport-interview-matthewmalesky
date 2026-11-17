# DNS records for the demo, derived from the cluster rather than typed in.
#
# The addresses belong to LoadBalancer Services that Argo CD creates (Teleport's
# proxy, Traefik), so the cluster Terraform module cannot know them. This root
# module reads them from the Kubernetes API and writes the A records at
# DNSimple. It is applied after Argo has converged (scripts/dns-apply.sh waits
# for the addresses) and destroyed before the cluster (scripts/kubeadm-down.sh).

locals {
  kubeconfig_path = coalesce(var.kubeconfig_path, "${path.module}/../kubeconfig")
}

# A list query rather than a single-object lookup: it returns an empty result,
# instead of an error, when the Service (or its namespace) does not exist yet.
data "kubernetes_resources" "lb" {
  for_each = var.load_balancers

  api_version    = "v1"
  kind           = "Service"
  namespace      = each.value.namespace
  field_selector = "metadata.name=${each.value.service}"
}

locals {
  # Label -> external IP, or null while the Service or its address is missing.
  lb_ip = {
    for k, lb in var.load_balancers :
    k => try(data.kubernetes_resources.lb[k].objects[0].status.loadBalancer.ingress[0].ip, null)
  }

  # One record per name whose address is known. Keyed "label/name" for stable
  # resource addresses.
  records = merge([
    for k, lb in var.load_balancers : {
      for name in lb.names :
      "${k}/${name}" => { name = name, ip = local.lb_ip[k] }
    } if local.lb_ip[k] != null
  ]...)

  pending = flatten([
    for k, lb in var.load_balancers :
    [for name in lb.names : "${name}.${var.zone_name} (waiting for ${lb.namespace}/${lb.service})"]
    if local.lb_ip[k] == null
  ])
}

resource "dnsimple_zone_record" "a" {
  for_each = local.records

  zone_name = var.zone_name
  name      = each.value.name
  type      = "A"
  value     = each.value.ip
  ttl       = var.ttl
}
