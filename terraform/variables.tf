variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_insecure" {
  type    = bool
  default = false
}

variable "bootstrap_iso_path" {
  description = "Path to the ISO built by `nix build path:.#bootstrap-iso`."
  type        = string
  default     = "../result/iso/nixos-bootstrap.iso"
}

variable "iso_datastore" {
  description = "Proxmox datastore with ISO image content enabled."
  type        = string
  default     = "local"
}

variable "nodes" {
  description = "One entry per k8s node VM."
  type = map(object({
    proxmox_node     = string
    vm_id            = number
    quicksync_pci_id = optional(string)
    nvidia_pci_id    = optional(string)
    # Installed NixOS static IPv4 in CIDR form; must match this node's
    # homelabNetwork.address in hosts/<name>/default.nix.
    ip_address = string
    cores      = optional(number, 4)
    memory_mb  = optional(number, 8192)
    # Start small (see nixos-modules/longhorn-disk-alert.nix - the node
    # alerts at 80% used - and nixos-modules/longhorn-disk-grow.nix, which
    # auto-grows into whatever you bump this to).
    longhorn_disk_gb = optional(number, 4)
  }))
}
