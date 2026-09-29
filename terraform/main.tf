module "node" {
  source = "./modules/vm"
  providers = {
    proxmox = proxmox
  }

  for_each = var.nodes

  hostname             = each.key
  proxmox_node         = each.value.proxmox_node
  vm_id                = each.value.vm_id
  cloud_init_password  = var.cloud_init_password
  cloud_init_datastore = var.cloud_init_datastore
  template_id          = var.template_id
  cores                = each.value.cores
  memory_mb            = each.value.memory_mb
  longhorn_disk_gb     = each.value.longhorn_disk_gb
  quicksync_pci_id     = each.value.quicksync_pci_id
  nvidia_pci_id        = each.value.nvidia_pci_id
  ip_address           = each.value.ip_address
}

output "node_ips" {
  value = { for k, m in module.node : k => m.ipv4_address }
}
