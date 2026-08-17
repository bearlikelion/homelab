# The container layer: every LXC that runs a Docker Compose stack.
#
# Authentication is root@pam rather than an API token, because host bind mounts
# and any feature flag other than nesting are root-only operations (a token
# gets HTTP 403). SSH is also required: idmap entries are written as lxc.idmap
# lines in the container config, which the Proxmox API cannot set.
#
# Media lives on the local ZFS pool at /tank/media, one dataset with plain
# subdirectories. It is deliberately NOT split into child datasets: hardlinks
# only work within a single filesystem, and the *arr import path depends on
# them. See docs/storage.md.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111.1"
    }
  }
}

provider "proxmox" {
  endpoint = var.pve_endpoint
  username = var.pve_username
  password = var.pve_password
  insecure = true # PVE ships a self-signed certificate

  ssh {
    username    = "root"
    agent       = false
    private_key = file(var.pve_ssh_private_key)
  }
}

# --- Inputs -----------------------------------------------------------------

variable "pve_endpoint" {
  type    = string
  default = "https://192.168.1.99:8006/"
}

variable "pve_username" {
  type    = string
  default = "root@pam"
}

variable "pve_password" {
  type      = string
  sensitive = true
}

variable "pve_ssh_private_key" {
  description = "Path to the private key authorized on the PVE host."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "node_name" {
  type    = string
  default = "pve"
}

variable "template_file_id" {
  type    = string
  default = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
}

variable "gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.1.1", "1.1.1.1"]
}

variable "ssh_public_keys" {
  description = "Seeded onto root at create time. ForceNew, so Ansible manages keys after first boot."
  type        = list(string)
}

variable "media_root" {
  description = "Host path holding the media library. One filesystem, no child datasets."
  type        = string
  default     = "/tank/media"
}

variable "build_root" {
  description = "Host path for build source, artifacts and ccache. On the fast pool, not tank, to keep compile IO off the spindles the media stack uses."
  type        = string
  default     = "/fast/build"
}

# --- Shared values ----------------------------------------------------------

locals {
  # The media user exists on the host and inside every container. Mapping it
  # straight through means files written in a container land on the host owned
  # by the same UID, instead of being shifted into the 100000+ range.
  media_uid = 13000
  media_gid = 13000

  # Punch one ID through the unprivileged container's 100000 offset: everything
  # below stays shifted, 13000 maps 1:1, everything above stays shifted.
  media_idmap = [
    { type = "uid", container_id = 0, host_id = 100000, size = local.media_uid },
    { type = "uid", container_id = local.media_uid, host_id = local.media_uid, size = 1 },
    { type = "uid", container_id = local.media_uid + 1, host_id = 100000 + local.media_uid + 1, size = 65536 - local.media_uid - 1 },
    { type = "gid", container_id = 0, host_id = 100000, size = local.media_gid },
    { type = "gid", container_id = local.media_gid, host_id = local.media_gid, size = 1 },
    { type = "gid", container_id = local.media_gid + 1, host_id = 100000 + local.media_gid + 1, size = 65536 - local.media_gid - 1 },
  ]
}

# --- Plex -------------------------------------------------------------------
# Plex only ever reads the library, so it gets a read-only mount and does not
# need to share a filesystem with the *arr apps. Keeping it in its own
# container also isolates GPU passthrough, when a card is added later.
#
# No device_passthrough yet: the only display adapter is the BMC's Matrox
# G200eW, which has no video engine. Transcoding is CPU-only until a GPU is
# installed. Adding one later does NOT recreate the container.

module "plex" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 120
  hostname         = "plex"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 4096
  disk_size = 16

  ipv4_address = "192.168.1.120/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    media = {
      volume    = var.media_root
      path      = "/data"
      read_only = true
    }
  }

  idmap = local.media_idmap

  tags          = ["media", "tofu"]
  startup_order = 20
}

# --- Media ------------------------------------------------------------------
# The *arr stack plus the download client. This is the only container with
# read-write access to the library, and it gets ONE mount at /data so that
# /data/torrents and /data/movies sit on the same filesystem. Hardlinking an
# import is then instant and costs no extra disk; split mounts would silently
# degrade to a full copy.

module "media" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 110
  hostname         = "media"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 6144
  disk_size = 16

  ipv4_address = "192.168.1.110/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    media = {
      volume    = var.media_root
      path      = "/data"
      read_only = false
    }
  }

  idmap = local.media_idmap

  tags          = ["media", "tofu"]
  startup_order = 10
}

# --- Edge -------------------------------------------------------------------
# Caddy terminates TLS for *.arneman.me and reverse-proxies to the other
# containers, plus cloudflare-ddns to keep the home record current. No media
# mount: it only ever proxies HTTP.

module "edge" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 130
  hostname         = "edge"
  template_file_id = var.template_file_id

  cores     = 2
  memory    = 1024
  disk_size = 8

  ipv4_address = "192.168.1.130/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  tags          = ["edge", "tofu"]
  startup_order = 5
}

# --- VPN --------------------------------------------------------------------
# Pritunl (OpenVPN protocol, so the stock OpenVPN Connect client works and
# profiles sit alongside any others you already have). Chosen over OpenVPN
# Access Server because the free AS tier caps at 2 simultaneous connections.
#
# Needs /dev/net/tun to build the tunnel interface, and ip_forward on the host
# so VPN clients can reach the other containers.

module "vpn" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 140
  hostname         = "vpn"
  template_file_id = var.template_file_id

  cores     = 2
  memory    = 2048
  disk_size = 12

  ipv4_address = "192.168.1.140/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  device_passthrough = {
    tun = {
      path = "/dev/net/tun"
      mode = "0666"
    }
  }

  tags          = ["vpn", "tofu"]
  startup_order = 15
}

# --- Social -----------------------------------------------------------------
# Postiz, for scheduling and cross-posting. Bluesky and Mastodon work with no
# approval at all; YouTube needs only an API key. Instagram requires Meta App
# Review, and TikTok restricts unaudited clients to private-only posts, so
# treat that one as upload-then-publish-by-hand.

module "social" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 160
  hostname         = "social"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 8192
  disk_size = 20

  ipv4_address = "192.168.1.160/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  tags          = ["social", "tofu"]
  startup_order = 30
}

# --- Build ------------------------------------------------------------------
# C++ build box, so compiling Godot stops tying up a laptop. The host is a
# dual E5-2690 (32 threads), and the containers above only ever reserve 16
# cores between them, so 24 here still leaves headroom for Plex.
#
# Everything large lives on the fast pool via a bind mount rather than in the
# rootfs: source checkouts, build artifacts and the ccache. vzdump skips bind
# mounts, so the nightly archive stays small.

module "build" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 150
  hostname         = "build"
  template_file_id = var.template_file_id

  cores     = 24
  memory    = 32768
  disk_size = 32

  ipv4_address = "192.168.1.150/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    build = {
      volume    = var.build_root
      path      = "/build"
      read_only = false
    }
  }

  # Last to boot and first to lose the CPU: a build is never more important
  # than the services people actually use.
  tags          = ["build", "tofu"]
  startup_order = 50
}

# --- Files ------------------------------------------------------------------
# Samba, so Windows and Linux desktops can mount tank directly. SMB rather than
# NFS because it is the only protocol both speak natively; Linux mounts it with
# cifs-utils.
#
# Named files, not nas: 192.168.1.11 is already a Synology.

module "files" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 190
  hostname         = "files"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 4096
  disk_size = 8

  ipv4_address = "192.168.1.190/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  # One mount per dataset, all landing under a single parent so Samba can serve
  # them as one share. A bind mount of /tank itself does NOT work: PVE binds
  # rather than rbinds, so each child dataset would appear as an empty dir.
  mount_points = {
    media = {
      volume = var.media_root
      path   = "/srv/samba/tank/media"
    }
    documents = {
      volume = "/tank/documents"
      path   = "/srv/samba/tank/documents"
    }
    bulk = {
      volume = "/tank/bulk"
      path   = "/srv/samba/tank/bulk"
    }
    backup = {
      volume = "/tank/backup"
      path   = "/srv/samba/tank/backup"
    }
  }

  idmap = local.media_idmap

  tags          = ["files", "tofu"]
  startup_order = 25
}

# --- Backup -----------------------------------------------------------------
# Backrest, a web UI over the restic repositories. The actual backup jobs run on
# the PVE host, not here: the container disks are LVM-thin volumes owned by the
# host, and an unprivileged container cannot read them. This box only browses
# and restores what the host already wrote.
#
# /tank is mounted read-only for the same reason a UI should not be able to
# delete a repository by accident.

module "backup" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 170
  hostname         = "backup"
  template_file_id = var.template_file_id

  cores     = 2
  memory    = 2048
  disk_size = 8

  ipv4_address = "192.168.1.170/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    tank = {
      volume    = "/tank"
      path      = "/tank"
      read_only = true
    }
  }

  tags          = ["backup", "tofu"]
  startup_order = 40
}

# --- Outputs ----------------------------------------------------------------

output "containers" {
  description = "Container facts, consumed when generating the Ansible inventory."
  value = {
    media = {
      vm_id    = module.media.vm_id
      hostname = module.media.hostname
      ip       = module.media.ip
    }
    plex = {
      vm_id    = module.plex.vm_id
      hostname = module.plex.hostname
      ip       = module.plex.ip
    }
    edge = {
      vm_id    = module.edge.vm_id
      hostname = module.edge.hostname
      ip       = module.edge.ip
    }
    vpn = {
      vm_id    = module.vpn.vm_id
      hostname = module.vpn.hostname
      ip       = module.vpn.ip
    }
    social = {
      vm_id    = module.social.vm_id
      hostname = module.social.hostname
      ip       = module.social.ip
    }
    build = {
      vm_id    = module.build.vm_id
      hostname = module.build.hostname
      ip       = module.build.ip
    }
    backup = {
      vm_id    = module.backup.vm_id
      hostname = module.backup.hostname
      ip       = module.backup.ip
    }
    files = {
      vm_id    = module.files.vm_id
      hostname = module.files.hostname
      ip       = module.files.ip
    }
  }
}
