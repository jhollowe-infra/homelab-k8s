{ ... }:
{
  networking.hostName = "hl01-kube03";

  homelabNetwork.address = "10.10.100.13/16";

  homelabK3s = {
    enable = true;
    role = "server";
    clusterInit = false;
    serverAddr = "https://k8s-api-vip.kube-nodes.johnhollowell.internal:6443";
  };

  homelabAutoUpgrade.dates = "07:00";

  # make sure to update terraform and apply to have the PCIe passthrough before adding imports for hardware modules
  imports = [
    # ../../nixos-modules/gpu-intel-quicksync.nix
    # ../../nixos-modules/gpu-nvidia.nix
  ];
}
