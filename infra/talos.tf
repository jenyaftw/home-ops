variable "cluster" {
  description = "Talos cluster and node configuration"

  type = object({
    name = string

    # Floating IP shared across control-plane nodes (Talos built-in VIP) so
    # the cluster endpoint survives any single control-plane node going down.
    vip = string

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

      # Attaches the host's Intel iGPU (see proxmox_hardware_mapping_pci.gpu)
      # for hardware transcoding. Only one node should set this - a physical
      # GPU can only be exclusively passed through to one VM at a time.
      gpu_passthrough = optional(bool, false)
    }))
  })
}

# Named PCI mapping instead of a raw device ID/path directly on the VM,
# because hostpci's `id` field requires root username/password auth - our
# provider is configured with an API token only, which `mapping` supports.
resource "proxmox_hardware_mapping_pci" "gpu" {
  name = "gpu"
  map = [
    {
      node         = "serenity-pve"
      path         = "0000:00:02.0"
      id           = "8086:46a6"
      subsystem_id = "0000:0000"
      iommu_group  = 0
    }
  ]
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
}

# i915 (Intel GPU driver) + intel-ucode are only actually used by
# talos-cp1 (the node with gpu_passthrough), but the schematic is shared
# by the whole cluster image - harmless on the other 2 nodes since they
# have no matching PCI device for the driver to bind to.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/iscsi-tools",
          "siderolabs/qemu-guest-agent",
          "siderolabs/util-linux-tools",
          "siderolabs/i915",
          "siderolabs/intel-ucode",
        ]
      }
    }
  })
}

locals {
  endpoint = "https://${var.cluster.vip}:6443"

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

  dynamic "hostpci" {
    for_each = each.value.gpu_passthrough ? [1] : []

    content {
      device  = "hostpci0"
      mapping = proxmox_hardware_mapping_pci.gpu.name
      pcie    = true
      # No xvga - this shouldn't become the VM's primary display, Talos
      # keeps using its normal virtual display/serial console. It's only
      # attached so /dev/dri exists for VAAPI hardware transcoding.
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

  # PCIe passthrough (hostpci with pcie = true, below) requires the q35
  # chipset - the default `pc` (i440fx) machine type doesn't support it.
  machine = each.value.gpu_passthrough ? "q35" : null
}

resource "proxmox_download_file" "talos_image" {
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = "serenity-pve"
  url                     = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/v${var.talos_version}/nocloud-amd64.raw.xz"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-nocloud-amd64.img"
  overwrite               = false
}

resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  for_each = local.control_planes

  cluster_name     = var.cluster.name
  cluster_endpoint = local.endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  # Proxmox NoCloud handles the unattended installation.
  config_patches = [
    yamlencode({
      machine = {
        install = null
      }
    }),

    # Static address set directly in the Talos config, not left to Proxmox's
    # NoCloud cloud-init alone - that only gets picked up reliably on the
    # very first boot. A `talosctl upgrade` reinstalls onto the other boot
    # partition and boots fresh, and that boot fell back to DHCP instead of
    # re-reading the NoCloud datasource, taking the node off its expected
    # address (and with it the VIP, which depends on this interface being
    # configured).
    #
    # Interface is `ens18`, not `eth0` - switching the VM's machine type to
    # `q35` (for PCIe GPU passthrough, see gpu_passthrough) changes the PCI
    # topology the guest sees, which changes predictable network interface
    # naming. Confirmed via `talosctl get links`; re-check if the machine
    # type or PCI layout changes again.
    #
    # Floating IP for HA control-plane access - whichever control-plane node
    # is elected leader answers on this address, so losing any one node
    # (including the one kubeconfig/talosconfig point at) doesn't take down
    # API access.
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "ens18"
              addresses = ["${each.value.ip}/24"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = "10.0.10.1"
                }
              ]
              vip = {
                ip = var.cluster.vip
              }
            }
          ]
        }
      }
    }),

    # Static hostname, for the same reason as the static address above - by
    # default Talos generates one itself (HostnameConfig's `auto: stable`,
    # a random-looking slug like "talos-061-8eo") whenever nothing else sets
    # it, and that generated name isn't stable across an OS reinstall. The
    # legacy `machine.network.hostname` field and the generated HostnameConfig
    # document conflict if both are present, so the generated one has to be
    # explicitly deleted.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      "$patch"   = "delete"
    }),

    yamlencode({
      machine = {
        network = {
          hostname = each.value.hostname
        }
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

    # Proxmox CSI plugin needs these to know where to place disks - see
    # docs/install.md in sergelogvinov/proxmox-csi-plugin. Only one
    # Proxmox host today, so every node gets the same zone.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      extraArgs = {
        node-labels = "topology.kubernetes.io/region=serenity,topology.kubernetes.io/zone=serenity-pve"
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster.name
  cluster_endpoint = local.endpoint
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

    # Proxmox CSI plugin needs these to know where to place disks - see
    # docs/install.md in sergelogvinov/proxmox-csi-plugin. Only one
    # Proxmox host today, so every node gets the same zone.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      extraArgs = {
        node-labels = "topology.kubernetes.io/region=serenity,topology.kubernetes.io/zone=serenity-pve"
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
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
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
