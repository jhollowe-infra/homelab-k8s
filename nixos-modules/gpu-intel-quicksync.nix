# Intel iGPU hardware video accel. Imported by every node (hosts/common)
# since all 3 physical hosts have it passed through via Terraform hostpci.
#
# Pinned for i7-10700 (Comet Lake, 10th gen -> UHD Graphics 630, Gen9.5).
# This generation is accessed via VA-API (intel-media-driver), NOT via
# Intel's QSV/oneVPL API. Verified against nixpkgs source
# (nixos/doc/manual/configuration/gpu-accel.chapter.md,
# pkgs/by-name/in/intel-media-driver/package.nix): the iHD/intel-media-driver
# VA-API path is nixpkgs' documented way to get hardware accel on "modern
# Intel GPUs", and its package metadata explicitly covers "Broadwell+
# iGPUs" (Gen8+), which includes this Gen9.5 part.
# `intel-media-sdk` (the QSV/MSDK runtime) still exists in nixpkgs as of
# this checkout, but is marked with `knownVulnerabilities` (unpatched EOL
# CVEs) in its meta, which makes it "insecure" and excluded from a normal
# build unless explicitly allow-listed via
# `nixpkgs.config.permittedInsecurePackages` - it has not been outright
# removed, contrary to what an earlier draft of this comment claimed.
# Using VA-API instead of QSV/MSDK for this generation is not a capability
# loss - it's the same physical encode/decode hardware block, just exposed
# through a different API. In Jellyfin (or any app), pick "VA-API" as the
# acceleration method, not "QuickSync", and point it at /dev/dri/renderD128.
#
# If a host's CPU is ever swapped for a Gen12+ one, `vpl-gpu-rt` (the
# current nixpkgs attribute name - the old `onevpl-intel-gpu` alias now
# throws, per pkgs/top-level/aliases.nix) is the oneVPL/QSV runtime to add
# to extraPackages instead, and the Intel device-plugin values in the app
# repo can additionally advertise QSV. Confirmed via the upstream
# intel/vpl-gpu-rt README (System Requirements section): it supports
# "Intel platforms supported by the Intel Media Driver for VAAPI starting
# with Tiger Lake" - i.e. Gen12+, so this generation (Gen9.5) is correctly
# excluded and stays on VA-API/intel-media-driver only.
#
# Prerequisite (on the Proxmox host, not managed by this repo): the iGPU
# must be bound to vfio-pci and passed to the VM as a PCI device. See
# docs/proxmox-host-setup.md (TODO).
#
# `hardware.graphics.enable`/`.extraPackages` verified against nixpkgs
# source (nixos/modules/hardware/graphics.nix): `hardware.opengl.enable`
# and `.package` are handled by mkRenamedOptionModule to
# `hardware.graphics.{enable,package}`, so the option names below are current.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot.initrd.kernelModules = [ "i915" ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # VA-API (iHD) driver, Broadwell (Gen8)+, covers Comet Lake
    ];
  };

  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  homelabK3s.nodeLabels."homelab/quicksync" = "true";
}
