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
    # Undocumented in the plugin's install.md at the version pulled here,
    # but required since v0.16 for GetCapacity's cluster/resources call -
    # confirmed against github.com/sergelogvinov/proxmox-csi-plugin#503.
    "Sys.Audit",
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

  # Without this, the token has none of the user's privileges by default
  # and needs its own separate ACL grant - simpler to just have it inherit
  # the user's permissions directly, matching the plugin's own docs
  # (`pveum user token add ... -privsep 0`).
  privileges_separation = false
}

output "csi_token_id" {
  description = "Proxmox CSI plugin API token ID"
  value       = "${proxmox_virtual_environment_user.csi.user_id}!${proxmox_virtual_environment_user_token.csi.token_name}"
  sensitive   = true
}

output "csi_token_secret" {
  # .value is actually the full "user@realm!token=<uuid>" string, not the
  # bare secret - split it to get just the <uuid> part the plugin's own
  # config.yaml expects as a separate token_secret field.
  description = "Proxmox CSI plugin API token secret"
  value       = split("=", proxmox_virtual_environment_user_token.csi.value)[1]
  sensitive   = true
}
