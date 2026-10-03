# Grow the Longhorn disk if the underlying virtual disk has been enlarged
# since the partition was created: grow the partition + ext4 filesystem
# online, every 15 minutes. This is what makes "bump the size in
# terraform.tfvars, tofu apply" sufficient on its own - no manual in-VM
# step. Usage alerting on this same disk is a separate module/service
# (homelab-longhorn-disk-alert, see longhorn-disk-alert.nix) - split out so
# growing and alerting can be reasoned about/tested independently.
#
# Why not disko for the resize: disko only runs at initial install
# (nixos-anywhere); it has no "reapply and grow existing partitions" mode,
# so a later virtual-disk enlargement needs this separate growpart step.
#
# cloud-utils/growpart usage verified against nixpkgs source
# (pkgs/by-name/cl/cloud-utils/package.nix and nixpkgs' own built-in
# nixos/modules/system/boot/grow-partition.nix module): growpart is
# packaged in cloud-utils (available via both the `out` and `guest`
# outputs), and nixpkgs' own growpart systemd unit sets
# `SuccessExitStatus = "0 1"` with the comment "growpart returns 1 if the
# partition is already grown" - directly confirming the 0/1 exit-code
# handling used below. `e2fsprogs` (providing `resize2fs`) is confirmed
# to exist as a package in nixpkgs; resize2fs itself is not a NixOS
# module API, so there's nothing further to verify there against nixpkgs.
# Still worth testing manually (`systemctl start
# homelab-longhorn-disk-grow`) after a real Terraform disk resize before
# trusting the unattended timer.
{ pkgs, ... }:
{
  systemd.services.homelab-longhorn-disk-grow = {
    description = "Grow the Longhorn disk/filesystem if the underlying virtual disk was enlarged";

    path = [
      pkgs.cloud-utils
      pkgs.e2fsprogs
      pkgs.util-linux
    ];

    serviceConfig.Type = "oneshot";

    script = ''
      set -e

      partition="/dev/disk/by-partlabel/disk-longhorn-longhorn"
      partition=$(readlink -f "$partition")

      # Get the kernel device name, e.g.:
      #   /dev/sda1       -> sda1
      #   /dev/nvme0n1p1  -> nvme0n1p1
      partname=$(basename "$partition")

      # Get the parent disk, e.g.:
      #   sda1       -> sda
      #   nvme0n1p1  -> nvme0n1
      parent=$(lsblk -no PKNAME "$partition")
      disk="/dev/$parent"

      # Remove the parent disk name from the partition name.
      # This leaves the partition number:
      #   sda1       -> 1
      #   nvme0n1p1  -> p1
      partnum="''${partname#''${parent}}"

      # NVMe/MMC partition names have a 'p' separator.
      partnum="''${partnum#p}"

      echo "Growing partition $partition on disk $disk (partition $partnum)"

      set +e
      growpart "$disk" "$partnum"
      status=$?
      set -e

      # growpart:
      #   0 = partition was grown
      #   1 = partition is already at maximum size
      if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
        echo "growpart failed with exit code $status" >&2
        exit "$status"
      fi

      resize2fs "$partition"
    '';
  };

  systemd.timers.homelab-longhorn-disk-grow = {
    description = "Periodic Longhorn disk growpart + filesystem resize";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
      Unit = "homelab-longhorn-disk-grow.service";
    };
  };
}
