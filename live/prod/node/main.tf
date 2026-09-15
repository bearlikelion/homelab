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

variable "cloud_image_url" {
  description = "Uncompressed cloud image for the KVM guests. Pinned to a dated Debian build rather than latest/, so a rebuild produces the machine that was tested."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/20260831-2587/debian-13-genericcloud-amd64-20260831-2587.qcow2"
}

variable "cloud_image_checksum" {
  description = "SHA512 of cloud_image_url, from the SHA512SUMS file alongside it."
  type        = string
  default     = "8ea9faae810043a0b35b0149f05014f26705c2339ffb11ead308f33e844a87cc3ef46ec81d5262b38817b6a88af404874d48a5857ebe072ef6a31dfb6e371f50"
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

variable "clips_root" {
  description = "Host path holding the game clip library. Its own dataset, so it can be snapshotted and shared separately from the media library."
  type        = string
  default     = "/tank/clips"
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

  # Quadro P400 (GP107) at 83:00.0, driver 580.178.04 on the host. The kernel
  # module stays on the host; a container only ever gets the character devices
  # plus a matching userspace driver installed with --no-kernel-module.
  #
  # These nodes are created on first use rather than at boot, so a container
  # starting before anything has touched the GPU finds nothing to pass through.
  # The systemd unit in scripts/pve-nvidia-prep.sh creates them early.
  nvidia_devices = {
    nvidia0   = { path = "/dev/nvidia0", mode = "0666" }
    nvidiactl = { path = "/dev/nvidiactl", mode = "0666" }
    # NVENC runs through a CUDA context, so uvm is required, not optional.
    nvidia_uvm       = { path = "/dev/nvidia-uvm", mode = "0666" }
    nvidia_uvm_tools = { path = "/dev/nvidia-uvm-tools", mode = "0666" }
  }
}

# --- Plex -------------------------------------------------------------------
# Plex only ever reads the library, so it gets a read-only mount and does not
# need to share a filesystem with the *arr apps. Keeping it in its own
# container also isolates GPU passthrough, when a card is added later.
#
# The Quadro P400 is passed in, but plex_gpu in group_vars still gates whether
# the compose file asks for it. Flip that flag to move transcoding onto NVENC.

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

  device_passthrough = local.nvidia_devices

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

# --- Darkfall ---------------------------------------------------------------
# Game server, written down after the fact: it was applied from a working copy
# that never landed in this file, so tofu had it in state with no configuration
# to match and planned a destroy on every run.
#
# Every value here is copied from the live container rather than chosen. The
# mount point in particular names the allocated volume in full, not just the
# datastore: mount_point is ForceNew, and "fast-vm" alone reads as a change and
# would take the 128G disk with it.

module "darkfall" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 180
  hostname         = "darkfall"
  template_file_id = var.template_file_id

  cores     = 8
  memory    = 32768
  disk_size = 32

  ipv4_address = "192.168.1.180/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    data = {
      volume = "fast-vm:subvol-180-disk-0"
      path   = "/srv/darkfall"
      size   = "128G"
      backup = false
    }
  }

  # The container doubles as the build rack and joins the headscale mesh, which
  # is WireGuard. An unprivileged LXC cannot create the device itself.
  #
  # Applied 2026-09-02, and it cost an outage worth writing down. Two
  # hand-written lines in /etc/pve/lxc/180.conf predated this block:
  #   lxc.cgroup2.devices.allow: c 10:200 rwm
  #   lxc.mount.entry: /dev/net dev/net none bind,create=dir
  # Adding dev0 alongside them left PVE's autodev hook creating /dev/net/tun
  # under a dev/net the raw bind had already mounted over, so the container
  # stopped and would not start: "Failed to run autodev hooks", status 17.
  # Deleting both lines and starting it fixed it. Nothing here is stale now, but
  # any future raw lxc.* line for a device this module also manages will do the
  # same thing again.
  device_passthrough = {
    tun = {
      path = "/dev/net/tun"
      mode = "0666"
    }
  }

  tags          = ["game", "tofu"]
  startup_order = 35
}

# --- Clips ------------------------------------------------------------------
# Fireshare, for sharing game clips by link. Its own container rather than a
# service on media: this one is published to the internet, and the *arr stack
# has read-write access to the whole library.
#
# The clip library is a bind mount from its own dataset. Only /data (the sqlite
# database) stays in the rootfs, so vzdump captures the state that cannot be
# regenerated and skips the videos that can be re-scanned. Posters and
# transcodes live on the same dataset as the videos: a full transcode pass over
# the library runs to roughly 90G, well past anything the rootfs can hold.

module "clips" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 200
  hostname         = "clips"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 4096
  disk_size = 16

  ipv4_address = "192.168.1.200/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    clips = {
      volume    = var.clips_root
      path      = "/srv/clips"
      read_only = false
    }
  }

  # NVENC on the P400, so a shared clip is transcoded to 720p/1080p variants
  # without burning cores the build box wants. GP107 encodes H.264 and HEVC;
  # AV1 needs Ada or newer, so Fireshare falls back to h264_nvenc.
  device_passthrough = local.nvidia_devices

  idmap = local.media_idmap

  # 180 and 35 both belong to darkfall.
  tags          = ["clips", "tofu"]
  startup_order = 45
}

# --- Code -------------------------------------------------------------------
# Forgejo, the git server. Its own container rather than a service on build:
# the Actions runner that lives on build drives the host Docker socket, which
# is root-equivalent there, and the git history is the one thing on this host
# that is not regenerable.
#
# Repositories stay in the rootfs rather than on a bind mount, which is the
# opposite of every other container here and deliberate: vzdump skips bind
# mounts, and repositories are exactly what the nightly archive should hold.

module "code" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 210
  hostname         = "code"
  template_file_id = var.template_file_id

  cores     = 2
  memory    = 4096
  disk_size = 32

  ipv4_address = "192.168.1.210/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  # Between clips (45) and build (50): the runner on build registers against
  # this, so it should already be answering when build comes up.
  tags          = ["code", "tofu"]
  startup_order = 48
}

# --- Design -----------------------------------------------------------------
# Penpot, public through the GCP tunnel. PostgreSQL and uploaded assets both live
# in Docker volumes on the rootfs, so the normal vzdump job captures a complete
# restorable instance. The 100G disk follows Penpot's recommended starting
# point for small installations and can grow in place if the workspace does.

module "design" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 230
  hostname         = "design"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 8192
  disk_size = 100

  ipv4_address = "192.168.1.230/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  tags          = ["design", "tofu"]
  startup_order = 42
}

# --- Foundry VTT ------------------------------------------------------------
# Public at foundry.arneman.me through the GCP tunnel, like design. Worlds and
# assets live on fast/foundry, which vzdump skips, so pve-backup.sh restics it.
# Foundry runs as mediauser so files dropped in over Samba are already its own.

module "foundry" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 240
  hostname         = "foundry"
  template_file_id = var.template_file_id

  cores     = 2
  memory    = 4096
  disk_size = 32

  mount_points = {
    data = {
      volume = "/fast/foundry"
      path   = "/opt/foundry/data"
    }
  }

  idmap = local.media_idmap

  ipv4_address = "192.168.1.240/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  tags          = ["vtt", "tofu"]
  startup_order = 43
}

# --- AzerothCore ------------------------------------------------------------
# The WotLK server. Nothing is compiled here: the azerothcore workflow on build
# publishes binaries and extracted map data under the build pool, and this
# container reads them through a read-only bind mount of that same host path.
# The database stays in the rootfs, so vzdump keeps accounts and characters.

module "azcore" {
  source = "../../../modules/lxc"

  node_name        = var.node_name
  vm_id            = 250
  hostname         = "azcore"
  template_file_id = var.template_file_id

  cores     = 4
  memory    = 8192
  disk_size = 32

  ipv4_address = "192.168.1.250/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  mount_points = {
    artifacts = {
      volume    = "${var.build_root}/artifacts/azerothcore"
      path      = "/srv/azerothcore"
      read_only = true
    }
  }

  tags          = ["game", "tofu"]
  startup_order = 46
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
    clips = {
      volume = var.clips_root
      path   = "/srv/samba/tank/clips"
    }
    backup = {
      volume = "/tank/backup"
      path   = "/srv/samba/tank/backup"
    }
    # On fast, not tank, but served inside the tank share so it is one mount away.
    foundry = {
      volume = "/fast/foundry"
      path   = "/srv/samba/tank/foundry"
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

# --- Pelican ----------------------------------------------------------------
# Game server hosting: the Pelican panel plus its Wings daemon, which is what
# actually starts a SteamCMD server in a container.
#
# The only KVM guest on this node, and not a preference. Wings is documented as
# unsupported under LXC: it sets cgroup, memory and swap limits on the Docker
# containers it launches, which an unprivileged container is not allowed to do
# for containers of its own. Everything else here stays an LXC.
#
# Server files live on a second disk on the fast pool, excluded from vzdump the
# way darkfall's is. A SteamCMD library is tens of gigabytes per title and all
# of it is re-downloadable; the panel's own database is on the root disk, which
# the nightly archive does capture.

resource "proxmox_virtual_environment_download_file" "debian_cloud_image" {
  node_name    = var.node_name
  datastore_id = "local"

  # import, not iso: only that content type can be handed to a disk's
  # import_from, and only uncompressed images qualify.
  content_type = "import"
  url          = var.cloud_image_url
  file_name    = "debian-13-genericcloud-amd64.qcow2"

  checksum           = var.cloud_image_checksum
  checksum_algorithm = "sha512"
}

module "pelican" {
  source = "../../../modules/vm"

  node_name           = var.node_name
  vm_id               = 220
  hostname            = "pelican"
  cloud_image_file_id = proxmox_virtual_environment_download_file.debian_cloud_image.id

  cores     = 8
  memory    = 16384
  disk_size = 32

  extra_disks = {
    volumes = {
      interface    = "scsi1"
      size         = 300
      datastore_id = "fast-vm"
      backup       = false
    }
  }

  ipv4_address = "192.168.1.220/24"
  ipv4_gateway = var.gateway
  dns_servers  = var.dns_servers

  ssh_public_keys = var.ssh_public_keys

  # Last of the services, ahead of build only. A game server nobody is on is
  # not worth booting before the media stack.
  tags          = ["game", "tofu"]
  startup_order = 49
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
    clips = {
      vm_id    = module.clips.vm_id
      hostname = module.clips.hostname
      ip       = module.clips.ip
    }
    darkfall = {
      vm_id    = module.darkfall.vm_id
      hostname = module.darkfall.hostname
      ip       = module.darkfall.ip
    }
    build = {
      vm_id    = module.build.vm_id
      hostname = module.build.hostname
      ip       = module.build.ip
    }
    code = {
      vm_id    = module.code.vm_id
      hostname = module.code.hostname
      ip       = module.code.ip
    }
    design = {
      vm_id    = module.design.vm_id
      hostname = module.design.hostname
      ip       = module.design.ip
    }
    foundry = {
      vm_id    = module.foundry.vm_id
      hostname = module.foundry.hostname
      ip       = module.foundry.ip
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
    pelican = {
      vm_id    = module.pelican.vm_id
      hostname = module.pelican.hostname
      ip       = module.pelican.ip
    }
    azcore = {
      vm_id    = module.azcore.vm_id
      hostname = module.azcore.hostname
      ip       = module.azcore.ip
    }
  }
}
