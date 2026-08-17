# Unprivileged LXC running Docker. Bind mounts and non-nesting feature flags
# require root@pam; an API token gets 403.

resource "proxmox_virtual_environment_container" "this" {
  node_name    = var.node_name
  vm_id        = var.vm_id
  unprivileged = var.unprivileged

  start_on_boot = var.start_on_boot
  started       = true
  tags          = var.tags

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  features {
    nesting = var.nesting
    keyctl  = var.keyctl
    fuse    = var.fuse
  }

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_address == "dhcp" ? null : var.ipv4_gateway
      }
    }

    dynamic "dns" {
      for_each = length(var.dns_servers) > 0 ? [1] : []
      content {
        servers = var.dns_servers
      }
    }

    # ForceNew: rotating keys rebuilds the container.
    dynamic "user_account" {
      for_each = length(var.ssh_public_keys) > 0 ? [1] : []
      content {
        keys = var.ssh_public_keys
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.bridge
  }

  # Absolute volume path with no size = host bind mount. A datastore ID with a
  # size = a volume PVE allocates and owns.
  dynamic "mount_point" {
    for_each = var.mount_points
    content {
      volume    = mount_point.value.volume
      path      = mount_point.value.path
      size      = mount_point.value.size
      backup    = mount_point.value.backup
      read_only = mount_point.value.read_only
    }
  }

  dynamic "device_passthrough" {
    for_each = var.device_passthrough
    content {
      path = device_passthrough.value.path
      gid  = device_passthrough.value.gid
      mode = device_passthrough.value.mode
    }
  }

  dynamic "idmap" {
    for_each = var.idmap
    content {
      type         = idmap.value.type
      container_id = idmap.value.container_id
      host_id      = idmap.value.host_id
      size         = idmap.value.size
    }
  }

  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [1]
    content {
      order = var.startup_order
    }
  }

  lifecycle {
    # mount_point and initialization.user_account are ForceNew; editing them
    # recreates the container.
    ignore_changes = [operating_system[0].template_file_id]
  }
}
