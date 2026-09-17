# Dedicated, least-privilege Proxmox API credential for the in-cluster
# Proxmox CSI plugin - separate from the admin-level token Terraform itself
# uses, so a compromised CSI plugin can only allocate/attach disks, not
# manage the whole Proxmox environment.
resource "proxmox_virtual_environment_role" "csi" {
  role_id = "Kubernetes-CSI"

  privileges = [
    "VM.Audit",
    "VM.Config.Disk",
    "Datastore.Allocate",
    "Datastore.AllocateSpace",
    "Datastore.Audit",
  ]
}

resource "proxmox_virtual_environment_user" "csi" {
  user_id = "kubernetes-csi@pve"
  comment = "Proxmox CSI plugin"

  acl {
    path      = "/"
    propagate = true
    role_id   = proxmox_virtual_environment_role.csi.role_id
  }
}

resource "proxmox_virtual_environment_user_token" "csi" {
  user_id    = proxmox_virtual_environment_user.csi.user_id
  token_name = "csi"
}

output "csi_token_id" {
  description = "Proxmox CSI plugin API token ID"
  value       = "${proxmox_virtual_environment_user.csi.user_id}!${proxmox_virtual_environment_user_token.csi.token_name}"
  sensitive   = true
}

output "csi_token_secret" {
  description = "Proxmox CSI plugin API token secret"
  value       = proxmox_virtual_environment_user_token.csi.value
  sensitive   = true
}
