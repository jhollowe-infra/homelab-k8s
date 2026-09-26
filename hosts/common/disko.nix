# Declarative disk layout, applied by nixos-anywhere on first install.
# Two virtual disks per VM (see terraform/modules/vm):
#   /dev/vda - boot disk: minimal, just the NixOS system + k3s state
#   /dev/vdb - given whole to Longhorn for replicated fast-local PVCs
{
  disko.devices = {
    disk = {
      boot = {
        device = "/dev/vda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              size = "512M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # Mounted at /var/lib/longhorn; Longhorn (installed via Helm, see
      # cluster-bootstrap/longhorn-values.yaml) treats this path as one of
      # its per-node disks. Sized deliberately small at first - see
      # nixos-modules/longhorn-disk-growth.nix for the alert+auto-grow
      # flow that lets you expand it later without reinstalling.
      longhorn = {
        device = "/dev/vdb";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            longhorn = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/longhorn";
              };
            };
          };
        };
      };
    };
  };
}
