variable "node_name" {
  description = "Proxmox node the container runs on."
  type        = string
}

variable "vm_id" {
  description = "Container ID (CTID). ForceNew."
  type        = number
}

variable "hostname" {
  description = "Container hostname, also used as the Name in the PVE UI."
  type        = string
}

variable "template_file_id" {
  description = "LXC template volume ID. Fetch with pveam download first."
  type        = string
}

variable "os_type" {
  description = "Guest OS family, used by PVE to pick the right setup hooks."
  type        = string
  default     = "debian"
}

variable "datastore_id" {
  description = "Datastore holding the container rootfs. local-zfs since the host was reinstalled on a ZFS root; the old LVM-thin install called it local-lvm."
  type        = string
  default     = "local-zfs"
}

variable "disk_size" {
  description = "Root disk size in GB. Shrinking recreates the container."
  type        = number
  default     = 16
}

variable "cores" {
  description = "CPU cores."
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM in MB."
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap in MB."
  type        = number
  default     = 512
}

variable "bridge" {
  description = "Network bridge to attach to."
  type        = string
  default     = "vmbr0"
}

variable "ipv4_address" {
  description = "Static address in CIDR form (e.g. 192.168.1.110/24), or \"dhcp\"."
  type        = string
}

variable "ipv4_gateway" {
  description = "Default gateway. Empty when ipv4_address is dhcp."
  type        = string
  default     = ""
}

variable "dns_servers" {
  description = "DNS servers for the container."
  type        = list(string)
  default     = []
}

variable "ssh_public_keys" {
  description = "Authorized keys for root. ForceNew: changes recreate the container."
  type        = list(string)
  default     = []
}

variable "mount_points" {
  description = "An absolute path in volume is a host bind mount; a datastore ID plus size allocates a volume. ForceNew: changes recreate the container."
  type = map(object({
    volume    = string
    path      = string
    size      = optional(string)
    backup    = optional(bool)
    read_only = optional(bool, false)
  }))
  default = {}
}

variable "device_passthrough" {
  description = "Host devices to expose. gid is the group ID inside the container."
  type = map(object({
    path = string
    gid  = optional(number)
    mode = optional(string)
  }))
  default = {}
}

variable "idmap" {
  description = "lxc.idmap entries, written over SSH. Needs matching /etc/subuid and /etc/subgid on the host, and a full pct stop/start to apply."
  type = list(object({
    type         = string # "uid" or "gid"
    container_id = number
    host_id      = number
    size         = number
  }))
  default = []
}

variable "start_on_boot" {
  description = "Start the container when the host boots."
  type        = bool
  default     = true
}

variable "startup_order" {
  description = "Boot order. Lower starts first; leave null for no explicit ordering."
  type        = number
  default     = null
}

variable "tags" {
  description = "PVE tags applied to the container."
  type        = list(string)
  default     = []
}

variable "unprivileged" {
  description = "Run unprivileged. ForceNew."
  type        = bool
  default     = true
}

variable "nesting" {
  description = "Required for Docker inside the container."
  type        = bool
  default     = true
}

variable "keyctl" {
  description = "Required by containerd when unprivileged."
  type        = bool
  default     = true
}

variable "fuse" {
  description = "Needed for fuse-overlayfs."
  type        = bool
  default     = false
}
