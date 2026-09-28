variable "hostname" {
  type = string
}

variable "proxmox_node" {
  description = "Which physical Proxmox host this VM lives on."
  type        = string
}

variable "vm_id" {
  type = number
}

variable "template_id" {
  type = number
}

variable "cores" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "boot_disk_gb" {
  type    = number
  default = 32
}

variable "longhorn_disk_gb" {
  description = "Size of the 2nd disk given entirely to Longhorn. Start small: nixos-modules/longhorn-disk-alert.nix alerts (Discord) at 80% used, and nixos-modules/longhorn-disk-grow.nix auto-grows the in-VM partition/filesystem once you increase this value and re-apply - shrinking is NOT supported (Proxmox/ext4 can't safely shrink this way), so it's fine to be conservative here."
  type        = number
  default     = 4
}

variable "boot_datastore" {
  type    = string
  default = "local-zfs"
}

variable "longhorn_datastore" {
  description = "Ideally a different physical disk/datastore than boot_datastore, so Longhorn I/O doesn't contend with the OS disk."
  type        = string
  default     = "local-zfs"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the node's network_device (VLAN 100, the servers VLAN)."
  type        = number
  default     = 100
}

variable "ip_address" {
  description = "This node's static IPv4 address in CIDR form, e.g. \"10.10.100.10/16\". Matches homelabNetwork.address in the corresponding hosts/<name>/default.nix, so the IP is identical before and after the nixos-anywhere install."
  type        = string
}

variable "gateway" {
  description = "Default gateway for the node's VLAN."
  type        = string
  default     = "10.10.0.1"
}

variable "quicksync_pci_id" {
  description = "PCI address of this host's iGPU (from `lspci -nn | grep VGA` on the Proxmox host), e.g. \"0000:00:02.0\". Leave null for nodes without iGPU passthrough."
  type        = string
  default     = null
}

variable "nvidia_pci_id" {
  description = "PCI address of the discrete NVIDIA GPU on this host, if any (e.g. the P620). Leave null for nodes without one."
  type        = string
  default     = null
}
