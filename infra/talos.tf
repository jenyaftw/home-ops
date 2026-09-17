variable "cluster" {
  description = "Talos cluster and node configuration"

  type = object({
    name     = string
    endpoint = string

    nodes = list(object({
      type         = string
      hostname     = string
      ip           = string
      cores        = number
      memory       = number
      boot_disk    = number
      install_disk = string

      data_disks = optional(map(object({
        datastore_id = string
        size         = number
      })), {})
    }))
  })
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
}

variable "talos_image_factory_id" {
  description = "Talos Image Factory schematic ID"
  type        = string
}

locals {
  nodes = {
    for node in var.cluster.nodes :
    node.hostname => node
  }

  control_planes = {
    for node in var.cluster.nodes :
    node.ip => node
    if node.type == "control-plane"
  }

  workers = {
    for node in var.cluster.nodes :
    node.ip => node
    if node.type == "worker"
  }
}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.nodes

  name            = each.value.hostname
  tags            = ["terraform", "talos"]
  node_name       = "serenity-pve"
  on_boot         = true
  stop_on_destroy = true

  agent {
    enabled = true
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_download_file.talos_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.boot_disk
  }

  dynamic "disk" {
    for_each = each.value.data_disks

    content {
      datastore_id = disk.value.datastore_id
      interface    = disk.key
      size         = disk.value.size
      iothread     = true
      discard      = "on"
    }
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "10.0.10.1"
      }
    }
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
    floating  = each.value.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 10
  }

  operating_system {
    type = "l26"
  }
}

resource "proxmox_download_file" "talos_image" {
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = "serenity-pve"
  url                     = "https://factory.talos.dev/image/${var.talos_image_factory_id}/v${var.talos_version}/nocloud-amd64.raw.xz"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-nocloud-amd64.img"
  overwrite               = false
}

resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster.name
  cluster_endpoint = var.cluster.endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  # Proxmox NoCloud handles the unattended installation.
  config_patches = [
    yamlencode({
      machine = {
        install = null
      }
    }),

    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"

      taints = {
        "node-role.kubernetes.io/control-plane" = {
          "$patch" = "delete"
        }
      }
    }),

    # Cilium replaces kube-proxy and the built-in Flannel CNI.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      enabled    = false
    }),

    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    }),

    # Format and mount the extra data disk (not the boot disk) for Longhorn.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "longhorn"
      volumeType = "disk"
      provisioning = {
        diskSelector = {
          match = "disk.size > 100u * GiB"
        }
      }
      filesystem = {
        type = "ext4"
      }
    }),

    # Create an LVM volume group on the second data disk for OpenEBS
    # LVM-LocalPV to consume.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LVMVolumeGroupConfig"
      name       = "openebs"
      provisioning = {
        volumeSelector = {
          match = "disk.size > 68u * GiB && disk.size < 100u * GiB"
        }
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster.name
  cluster_endpoint = var.cluster.endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  # Proxmox NoCloud handles the unattended installation.
  config_patches = [
    yamlencode({
      machine = {
        install = null
      }
    }),

    # Cilium replaces kube-proxy and the built-in Flannel CNI.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      enabled    = false
    }),

    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    }),

    # Format and mount the extra data disk (not the boot disk) for Longhorn.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "longhorn"
      volumeType = "disk"
      provisioning = {
        diskSelector = {
          match = "disk.size > 100u * GiB"
        }
      }
      filesystem = {
        type = "ext4"
      }
    }),

    # Create an LVM volume group on the second data disk for OpenEBS
    # LVM-LocalPV to consume.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LVMVolumeGroupConfig"
      name       = "openebs"
      provisioning = {
        volumeSelector = {
          match = "disk.size > 68u * GiB && disk.size < 100u * GiB"
        }
      }
    })
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster.name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = keys(local.control_planes)
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.control_planes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.key

  depends_on = [
    proxmox_virtual_environment_vm.talos
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = local.workers

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.key

  depends_on = [
    proxmox_virtual_environment_vm.talos
  ]
}

locals {
  bootstrap_node = sort(keys(local.control_planes))[0]
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.bootstrap_node
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_configuration_apply.controlplane
  ]
}

data "talos_cluster_kubeconfig" "this" {
  node                 = local.bootstrap_node
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_bootstrap.this
  ]
}

output "kubeconfig" {
  description = "Kubernetes kubeconfig"
  value       = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
