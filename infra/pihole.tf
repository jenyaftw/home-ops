resource "proxmox_virtual_environment_container" "pihole" {
  node_name = "serenity-pve"

  unprivileged = true
  features {
    nesting = true
  }

  initialization {
    hostname = "pihole"

    ip_config {
      ipv4 {
        address = "10.0.10.30/24"
        gateway = "10.0.10.1"
      }
    }

    user_account {
      keys = [
        trimspace(tls_private_key.pihole_container_key.public_key_openssh)
      ]
      password = random_password.pihole_container_password.result
    }
  }

  network_interface {
    name    = "veth0"
    vlan_id = 10
  }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_trixie_lxc_img.id
    type             = "debian"
  }

  startup {
    order      = "3"
    up_delay   = "30"
    down_delay = "30"
  }
}

resource "proxmox_download_file" "debian_trixie_lxc_img" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = "serenity-pve"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
}

resource "tls_private_key" "pihole_container_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "random_password" "pihole_container_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "pihole_container_private_key" {
  value     = tls_private_key.pihole_container_key.private_key_pem
  sensitive = true
}

output "pihole_container_public_key" {
  value = tls_private_key.pihole_container_key.public_key_openssh
}
