{ ... }:
{
  networking.hostName = "k8s-node-1";

  homelabNetwork.address = "10.10.100.10/16";

  # First node: initializes the k3s/etcd cluster.
  homelabK3s = {
    role = "server";
    clusterInit = true;
  };

  # Auto-upgrade windows staggered 2h apart across the 3 nodes so a bad
  # commit fails on one node before it reaches the others.
  homelabAutoUpgrade.dates = "03:00";
}
