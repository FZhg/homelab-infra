output "nodes" {
  description = "VM name => IP (role)"
  value       = { for name, n in local.nodes : name => "${n.ip} (${n.role})" }
}
