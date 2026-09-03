output "vm_id" {
  description = "Machine ID (VMID)."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "hostname" {
  description = "Guest hostname."
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
