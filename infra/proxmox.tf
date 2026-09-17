variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox Endpoint"
}

variable "proxmox_api_key" {
  type        = string
  description = "Proxmox API Key"
}

variable "proxmox_ssh_key_path" {
  type        = string
  description = "Proxmox SSH Key Path"
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_key

  ssh {
    agent       = true
    username    = "terraform"
    private_key = file(pathexpand(var.proxmox_ssh_key_path))
  }
}
