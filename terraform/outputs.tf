output "node_names" {
  description = "Hostnames of the cluster nodes, in order (primary first)."
  value       = var.node_names
}

output "node_ips" {
  description = "Static IP addresses assigned to each node."
  value       = local.node_ips
}

output "ssh_user" {
  description = "Default SSH user on the Ubuntu cloud image."
  value       = "ubuntu"
}
