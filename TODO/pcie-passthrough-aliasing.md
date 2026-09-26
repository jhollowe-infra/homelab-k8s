# TODO: Investigate PCIe resource mapping (IDs) for more reliable GPU passthrough

Currently `terraform/modules/vm/main.tf` passes GPUs through by raw PCI
address (`quicksync_pci_id`, `nvidia_pci_id`, e.g. `"0000:00:02.0"`), one
literal string per physical host in `terraform.tfvars`. Proxmox has a
"Resource Mapping" feature (PCI(e) device IDs, under Datacenter -> Resource
Mappings, sometimes called PCI aliasing) that lets you give a PCI device a
stable logical name shared across the cluster, instead of hardcoding each
host's raw bus address.

> NOTE on sourcing: not yet researched from primary docs in this
> environment - this file only exists to flag the idea. Before implementing,
> read the actual Proxmox docs (PVE Resource Mapping /
> `/etc/pve/mapping/pci`) and the `bpg/proxmox` Terraform provider's
> support for it (if any) rather than trusting this description.

## Why this might matter here

- Every node's PCI address for its iGPU is currently assumed to be the same
  (`"0000:00:02.0"` in the example tfvars) across all 3 physical Proxmox
  hosts - that's fragile if any host's BIOS/board enumerates PCI slots
  differently, or if a host's PCI layout shifts after a hardware change
  (e.g. adding another card), silently breaking passthrough on next VM
  (re)create rather than failing loudly.
- A resource-mapping layer would let each physical host register "the
  iGPU" / "the P620" under one logical name, with Proxmox resolving the
  actual bus address per-host - Terraform/this repo would then reference
  the logical name instead of a raw address, removing the assumption above.

## Open questions to research before implementing

- Does resource mapping require identical hardware config across hosts, or
  does it explicitly exist to paper over per-host differences (the case
  that would actually help here)?
- Does the `bpg/proxmox` Terraform provider expose resource-mapped PCI
  devices as a `hostpci` target, or only raw bus addresses - if not
  supported, this may need to stay a manual Proxmox-side config with
  Terraform none the wiser.
- Does a resource-mapping change require a VM reboot/re-clone the same way
  a raw `hostpci_id` change does, or is it hot-swappable?
- Interaction with `lifecycle.ignore_changes` on `network_device[0].mac_address`
  and `initialization` in `terraform/modules/vm/main.tf` - would a mapped
  device need similar `ignore_changes` handling to avoid spurious diffs?
