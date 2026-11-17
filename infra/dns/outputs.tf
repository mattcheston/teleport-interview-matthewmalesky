output "records" {
  description = "A records managed by this module: FQDN -> address."
  value       = { for k, r in dnsimple_zone_record.a : r.qualified_name => r.value }
}

output "pending" {
  description = "Names not created yet because their LoadBalancer has no address; re-apply later."
  value       = local.pending
}
