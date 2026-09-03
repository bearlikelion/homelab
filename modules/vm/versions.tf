terraform {
  required_version = ">= 1.10.0"
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Pre-1.0 provider: pin to the patch line, breaking changes land in minors.
      version = "~> 0.111.1"
    }
  }
}
