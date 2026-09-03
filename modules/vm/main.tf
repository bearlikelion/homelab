# A full KVM guest, for the one workload an LXC cannot host.
#
# Everything else on this node is a container, deliberately. This module exists
# because Pelican's Wings daemon is unsupported under LXC: it hands cgroup and
# memory limits to a Docker daemon it expects to own, and a nested unprivileged
# container owns neither. The panel alone would run happily in a container; the
# daemon is what forces a real machine.
#
# Booted from a cloud image rather than an installer ISO, so the guest is built
# the same way a container is: no console, no clicking, root reachable over SSH
# on first boot with the key cloud-init planted.

locals {
  # One list so the root disk and any extras go through the same block. scsi0
  # sorts first, which keeps disk[0] stable for the lifecycle rule below.
  disks = concat(
    [{
      interface    = "scsi0"
      datastore_id = var.datastore_id
      size         = var.disk_size
      import_from  = var.cloud_image_file_id
      backup       = true
      serial       = "root"
    }],
    [for name in sort(keys(var.extra_disks)) : {
      interface    = var.extra_disks[name].interface
      datastore_id = var.extra_disks[name].datastore_id
      size         = var.extra_disks[name].size
      import_from  = null
      backup       = var.extra_disks[name].backup
      serial       = name
    }]
  )
}

resource "proxmox_virtual_environment_vm" "this" {
  node_name = var.node_name
  vm_id     = var.vm_id
  name      = var.hostname
  tags      = var.tags

  on_boot = var.start_on_boot

  # Without the agent PVE cannot ask the guest to shut itself down, and a
  # destroy would otherwise wait out the ACPI timeout on every run.
  stop_on_destroy = true

  agent {
    enabled = true

    # The generic cloud image ships without qemu-guest-agent; the common role
    # installs it on the first deploy. Until then the agent reports nothing, so
    # waiting on it for an address would hang every apply. The address is
    # static and already known here anyway.
    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
  }

  dynamic "disk" {
    for_each = local.disks
    content {
      datastore_id = disk.value.datastore_id
      interface    = disk.value.interface
      size         = disk.value.size
      import_from  = disk.value.import_from
      backup       = disk.value.backup

      # Labels the disk for anyone reading lsblk in the guest. It does NOT name
      # the by-id link: udev builds that from the drive name, so scsi1 arrives
      # as scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 and the serial only reaches
      # ID_SCSI_SERIAL. Mount by interface, not by this.
      serial = disk.value.serial

      # ZFS is thin-provisioned, so discard is what actually returns freed
      # blocks to the pool. iothread keeps a busy disk off the main event loop.
      discard  = "on"
      ssd      = true
      iothread = true
    }
  }

  initialization {
    datastore_id = var.datastore_id

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

    # root rather than a named user, to match how Ansible reaches every
    # container on this node.
    dynamic "user_account" {
      for_each = length(var.ssh_public_keys) > 0 ? [1] : []
      content {
        username = "root"
        keys     = var.ssh_public_keys
      }
    }
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  # Cloud images expect a serial console and print their boot log to it.
  serial_device {}

  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [1]
    content {
      order = var.startup_order
    }
  }

  lifecycle {
    # import_from is read once, at create. Bumping the pinned image should show
    # up as a decision to rebuild, not as a plan that silently reimages a
    # machine that is already running.
    ignore_changes = [disk[0].import_from]
  }
}
