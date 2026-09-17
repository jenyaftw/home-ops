terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.113.1"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "4.4.1"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }

    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0-rc.0"
    }
  }
}
