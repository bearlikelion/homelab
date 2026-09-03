variable "node_name" {
  description = "Proxmox node the machine runs on."
  type        = string
}

variable "vm_id" {
  description = "Machine ID (VMID). ForceNew."
  type        = number
}

variable "hostname" {
  description = "Guest hostname, also used as the Name in the PVE UI."
  type        = string
}

variable "cloud_image_file_id" {
  description = "Volume ID of an uncompressed cloud image with content type import, e.g. local:import/debian-13-genericcloud-amd64.qcow2."
  type        = string
}

variable "datastore_id" {
  description = "Datastore holding the root disk and the cloud-init drive."
  type        = string
  default     = "local-zfs"
}

variable "disk_size" {
  description = "Root disk size in GB. The cloud image is grown to this on import; shrinking is not possible."
  type        = number
  default     = 32
}

variable "extra_disks" {
  description = "Additional blank disks, keyed by name. The key becomes the disk serial, which labels it in the guest's lsblk; the guest mounts it by interface, as /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-<interface>. Set backup false for anything a nightly vzdump should skip."
  type = map(object({
    interface    = string
    size         = number
    datastore_id = optional(string, "local-zfs")
    backup       = optional(bool, true)
  }))
  default = {}
}

variable "cores" {
  description = "vCPU cores."
  type        = number
  default     = 2
}

variable "cpu_type" {
  description = "Emulated CPU. x86-64-v2-AES is the widest baseline that still exposes AES-NI, which Docker image pulls lean on."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "memory" {
  description = "RAM in MB."
  type        = number
  default     = 2048
}

variable "bridge" {
  description = "Network bridge to attach to."
  type        = string
  default     = "vmbr0"
}

variable "ipv4_address" {
  description = "Static address in CIDR form (e.g. 192.168.1.220/24), or \"dhcp\"."
  type        = string
}

variable "ipv4_gateway" {
  description = "Default gateway. Empty when ipv4_address is dhcp."
  type        = string
  default     = ""
}

variable "dns_servers" {
  description = "DNS servers written into the cloud-init drive."
  type        = list(string)
  default     = []
}

variable "ssh_public_keys" {
  description = "Authorized keys for root. PVE writes disable_root: False whenever the cloud-init user is root, so key auth works."
  type        = list(string)
  default     = []
}

variable "start_on_boot" {
  description = "Start the machine when the host boots."
  type        = bool
  default     = true
}

variable "startup_order" {
  description = "Boot order. Lower starts first; leave null for no explicit ordering."
  type        = number
  default     = null
}

variable "tags" {
  description = "PVE tags applied to the machine."
  type        = list(string)
  default     = []
}
