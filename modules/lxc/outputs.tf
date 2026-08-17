output "vm_id" {
  description = "Container ID (CTID)."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "hostname" {
  description = "Container hostname."
  value       = var.hostname
}

output "ipv4_address" {
  description = "Configured IPv4 address in CIDR form, or \"dhcp\"."
  value       = var.ipv4_address
}

output "ip" {
  description = "Bare IPv4 address with the prefix stripped, for building the Ansible inventory."
  value       = var.ipv4_address == "dhcp" ? null : split("/", var.ipv4_address)[0]
}
