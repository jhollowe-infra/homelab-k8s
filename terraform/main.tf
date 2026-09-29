module "node" {
  source = "./modules/vm"
  providers = {
    proxmox = proxmox
  }

  for_each = var.nodes

  hostname           = each.key
  proxmox_node       = each.value.proxmox_node
  vm_id              = each.value.vm_id
  bootstrap_iso_path = var.bootstrap_iso_path
  iso_datastore      = var.iso_datastore
  cores              = each.value.cores
  memory_mb          = each.value.memory_mb
  longhorn_disk_gb   = each.value.longhorn_disk_gb
  quicksync_pci_id   = each.value.quicksync_pci_id
  nvidia_pci_id      = each.value.nvidia_pci_id
}

output "node_ips" {
  value = { for k, m in module.node : k => m.ipv4_address }
}

output "node_installed_ips" {
  description = "Static IPv4 addresses configured by each installed NixOS host."
  value       = { for k, node in var.nodes : k => node.ip_address }
}
