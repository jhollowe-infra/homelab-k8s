{ ... }:
{
  networking.hostName = "k8s-node-3";

  homelabNetwork.address = "10.10.100.12/16";

  homelabK3s = {
    role = "server";
    clusterInit = false;
    serverAddr = "https://k8s-node-1.kube-nodes.johnhollowell.internal:6443";
  };

  homelabAutoUpgrade.dates = "07:00";

  # make sure to update terraform and apply to have the PCIe passthrough before adding imports for hardware modules
  imports = [
    # ../../nixos-modules/gpu-intel-quicksync.nix
    # ../../nixos-modules/gpu-nvidia.nix
  ];
}
