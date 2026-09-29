# One k8s node VM: boots a NixOS installer ISO, with a 2nd disk for Longhorn
# and PCI passthrough for the iGPU (every node) and optionally a discrete NVIDIA GPU.
#
# bpg/proxmox resource/argument names below verified against the provider
# source (proxmoxtf/resource/vm/vm.go, disk/schema.go) and
# docs/resources/virtual_environment_vm.md: `machine = "q35"` is required for
# PCIe passthrough (hostpci.pcie is only honored on q35), and
# `discard = "on"` is a valid disk enum value (`on`/`ignore`).
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.hostname
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  machine    = "q35" # required for PCIe passthrough
  bios       = "ovmf"
  boot_order = ["scsi0", "ide2"]

  agent {
    enabled = true
  }

  cdrom {
    file_id   = proxmox_virtual_environment_file.bootstrap_iso.id
    interface = "ide2"
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
    discard      = "on"
    ssd          = true
  }

  disk {
    datastore_id = var.longhorn_datastore
    interface    = "scsi1"
    size         = var.longhorn_disk_gb
    discard      = "on"
    ssd          = true
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

  lifecycle {
    ignore_changes = [
      network_device[0].mac_address,
    ]
  }
}

resource "proxmox_virtual_environment_file" "bootstrap_iso" {
  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = var.proxmox_node

  source_file {
    path      = var.bootstrap_iso_path
    file_name = "nixos-bootstrap.iso"
    # file_name = "${var.hostname}-bootstrap.iso"
  }
}

output "ipv4_address" {
  value = proxmox_virtual_environment_vm.this.ipv4_addresses
}
