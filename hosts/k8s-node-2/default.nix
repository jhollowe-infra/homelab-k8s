{ ... }:
{
  networking.hostName = "k8s-node-2";

  homelabNetwork.address = "10.10.100.11/16";

  homelabK3s = {
    enable = false;
    role = "server";
    clusterInit = false;
    serverAddr = "https://k8s-node-1.kube-nodes.johnhollowell.internal:6443";
  };

  # Staggered 2h after node-1, so node-1's homelab-auto-upgrade rollback
  # (see nixos-modules/auto-upgrade.nix) has time to happen, and so this
  # node's own pre-check will see node-1 as NotReady and skip if node-1's
  # upgrade broke something it couldn't self-heal.
  homelabAutoUpgrade.dates = "05:00";

  # make sure to update terraform and apply to have the PCIe passthrough before adding imports for hardware modules
  imports = [
    # ../../nixos-modules/gpu-intel-quicksync.nix
    # ../../nixos-modules/gpu-nvidia.nix
  ];
}
