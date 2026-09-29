{ ... }:
{
  networking.hostName = "hl01-kube01";

  homelabNetwork.address = "10.10.100.10/16";

  # First node: initializes the k3s/etcd cluster.
  homelabK3s = {
    enable = false;
    role = "server";
    clusterInit = true;
  };

  # Auto-upgrade windows staggered 2h apart across the 3 nodes so a bad
  # commit fails on one node before it reaches the others.
  homelabAutoUpgrade.dates = "03:00";

  # make sure to update terraform and apply to have the PCIe passthrough before adding imports for hardware modules
  imports = [
    # ../../nixos-modules/gpu-intel-quicksync.nix
    # ../../nixos-modules/gpu-nvidia.nix
  ];
}
