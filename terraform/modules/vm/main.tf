# One k8s node VM: cloned from the shared base template (image/build-base-template.sh),
# with a 2nd disk for Longhorn and PCI passthrough for the iGPU (every node)
# and optionally a discrete NVIDIA GPU.
#
# bpg/proxmox resource/argument names below verified against the provider
# source (proxmoxtf/resource/vm/vm.go, disk/schema.go) and
# docs/resources/virtual_environment_vm.md: `machine = "q35"` is required for
# PCIe passthrough (hostpci.pcie is only honored on q35), and
# `discard = "on"` is a valid disk enum value (`on`/`ignore`).
resource "proxmox_virtual_environment_vm" "this" {
  name      = var.hostname
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  machine = "q35" # required for PCIe passthrough
  bios    = "ovmf"

  agent {
    enabled = true
  }

  clone {
    vm_id = var.template_id
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  efi_disk {
    datastore_id = var.boot_datastore
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.boot_datastore
    interface    = "scsi0"
    size         = var.boot_disk_gb
    iothread     = true
    discard      = "on"
  }

  disk {
    datastore_id = var.longhorn_datastore
    interface    = "scsi1"
    size         = var.longhorn_disk_gb
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  # Intel iGPU (QuickSync/VA-API), only on nodes that pass one through.
  dynamic "hostpci" {
    for_each = var.quicksync_pci_id == null ? [] : [var.quicksync_pci_id]
    content {
      device = "hostpci0"
      id     = hostpci.value
      pcie   = true
    }
  }

  # Discrete NVIDIA GPU, only on nodes that have one.
  dynamic "hostpci" {
    for_each = var.nvidia_pci_id == null ? [] : [var.nvidia_pci_id]
    content {
      device = "hostpci1"
      id     = hostpci.value
      pcie   = true
      rombar = true
    }
  }

  # NixOS is installed by nixos-anywhere after this VM boots the cloned
  # template once; Proxmox cloud-init here just gets us SSH access for
  # nixos-anywhere to connect and kexec from.
  initialization {
    datastore_id = var.boot_datastore
    interface    = "ide2"
    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [
      network_device[0].mac_address,
      initialization,
    ]
  }
}

output "ipv4_address" {
  value = proxmox_virtual_environment_vm.this.ipv4_addresses
}
