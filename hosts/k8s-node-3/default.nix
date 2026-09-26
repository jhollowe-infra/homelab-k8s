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

  # Example: this is the node with the GPU passed through by Terraform.
  # Uncomment once terraform/modules/vm gpu_pci_id is set for this node
  # and you've re-run tofu apply.
  # imports = [ ../../nixos-modules/gpu-nvidia.nix ];
}
