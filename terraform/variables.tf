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

variable "cloud_init_password" {
  description = "Temporary password for the VM's cloud-init root account."
  type        = string
  sensitive   = true
}

variable "cloud_init_datastore" {
  description = "Proxmox datastore with Snippets content enabled."
  type        = string
  default     = "local"
}

variable "template_id" {
  description = "ID of the shared base template created by image/build-base-template.sh"
  type        = number
  default     = 9000
}

variable "nodes" {
  description = "One entry per k8s node VM."
  type = map(object({
    proxmox_node     = string
    vm_id            = number
    quicksync_pci_id = optional(string)
    nvidia_pci_id    = optional(string)
    # Static IPv4 in CIDR form, e.g. "10.10.100.10/16" - must match this
    # node's homelabNetwork.address in hosts/<name>/default.nix.
    ip_address = string
    cores      = optional(number, 4)
    memory_mb  = optional(number, 8192)
    # Start small (see nixos-modules/longhorn-disk-alert.nix - the node
    # alerts at 80% used - and nixos-modules/longhorn-disk-grow.nix, which
    # auto-grows into whatever you bump this to).
    longhorn_disk_gb = optional(number, 4)
  }))
}
