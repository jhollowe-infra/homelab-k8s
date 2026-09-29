# Proxmox host prerequisites for GPU passthrough

This is one-time, manual setup **on each physical Proxmox host**, done
before Terraform can attach `hostpci` devices to a VM. It's not managed by
this repo — Proxmox's host OS isn't Nix — so it's documented here instead.

Needed on every host (for the iGPU/QuickSync passthrough) and additionally
on whichever host carries the discrete NVIDIA GPU (the P620).

The VFIO setup steps below are checked against Proxmox VE's "PCI(e)
Passthrough" wiki page.

## 1. Enable IOMMU

Edit `/etc/kernel/cmdline` (Proxmox 8+, using systemd-boot) or
`/etc/default/grub` (GRUB), adding:

- Intel CPUs: `intel_iommu=on iommu=pt`
- AMD CPUs: `amd_iommu=on iommu=pt`

Then update the bootloader (`proxmox-boot-tool refresh` or
`update-grub`, depending on which one the host uses) and reboot.

## 2. Load VFIO modules

Add to `/etc/modules-load.d/vfio.conf`:
```
vfio
vfio_iommu_type1
vfio_pci
```

## 3. Find the device(s) and bind them to vfio-pci

```
lspci -nn | grep -Ei 'vga|3d|display'
```

Note the PCI address (e.g. `00:02.0` for the iGPU, `01:00.0` for the P620)
and the vendor:device ID pair (e.g. `[8086:9bc8]`).

Blacklist the host's own driver for that device so it doesn't grab it
before VFIO can, and bind it to vfio-pci instead. In
`/etc/modprobe.d/vfio.conf`:
```
options vfio-pci ids=8086:9bc8,10de:1cb6
# only if you don't need the iGPU on the Proxmox host itself
blacklist i915
blacklist nouveau
blacklist nvidia
```

Regenerate initramfs (`update-initramfs -u -k all`) and reboot.

## 4. Verify

```
lspci -nnk -s 00:02.0
```
The `Kernel driver in use:` line should read `vfio-pci`, not `i915` (or
`nouveau`/`nvidia` for the discrete card).

## 5. Record the PCI IDs for Terraform

Put the full-domain form (`0000:00:02.0`, `0000:01:00.0`) into
`terraform/terraform.tfvars` as `quicksync_pci_id` / `nvidia_pci_id` for
that node.

## Caveat: Proxmox loses the device too

Once bound to vfio-pci, the Proxmox host itself can no longer use that
GPU (e.g. for its own console output on the iGPU, if that's the machine's
only GPU). Make sure each host has another way to get video output
(onboard secondary graphics, serial console, or IPMI/BMC) before doing this
on a machine you don't have physical/remote-console access to.
