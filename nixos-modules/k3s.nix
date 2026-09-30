# k3s + Longhorn wiring shared by all nodes. Per-node specifics (which one
# does `clusterInit`, node labels) are set in hosts/<node>/default.nix via
# these options.
#
# services.k3s options below verified against nixpkgs source
# (nixos/modules/services/cluster/rancher/{default,k3s}.nix): role is
# enum ["server" "agent"] (default "server"), clusterInit is a k3s-specific
# bool option (default false, only meaningful on a server not joining
# another server), tokenFile is nullOr path, extraFlags is str or [str]
# appended verbatim to the k3s command line.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelabK3s;
in
{
  options.homelabK3s = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to run k3s (+ its Longhorn prerequisites) on this node.";
    };
    role = lib.mkOption {
      type = lib.types.enum [
        "server"
        "agent"
      ];
      default = "server";
      description = "All 3 nodes run as 'server' (control-plane + worker) for etcd HA.";
    };
    clusterInit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set true on exactly the first node when bootstrapping a new cluster.";
    };
    serverAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "https://<first-node>:6443 - set on every node except the bootstrap node.";
    };
    nodeLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra kubelet --node-label entries, e.g. { \"homelab/gpu\" = \"true\"; }";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.age.keyFile = "/var/lib/sops-nix/key.txt";

    # k3s/flannel/kubelet ports
    networking.firewall.allowedTCPPorts = [
      6443 # k8s API
      10250 # kublet API
    ];
    networking.firewall.allowedUDPPorts = [
      8472 # VXLAN
    ];

    # k3s join token: generated once (scripts/bootstrap-nodes.sh) and
    # stored encrypted via sops-nix, decrypted to this path at activation.
    sops.secrets.k3s-token = {
      sopsFile = ../secrets/secrets.sops.yaml;
      owner = "root";
      mode = "0400";
    };

    services.k3s = {
      enable = true;
      role = cfg.role;
      tokenFile = config.sops.secrets.k3s-token.path;
      clusterInit = cfg.clusterInit;
      serverAddr = lib.mkIf (cfg.serverAddr != null) cfg.serverAddr;
      extraFlags = lib.concatStringsSep " " (
        [
          # Longhorn needs its own replication/HA; disable k3s's built-in
          # single-node local-path-provisioner and Traefik/ServiceLB, which
          # you don't want fighting with your own ingress/storage choices.
          "--disable=local-storage"
          "--disable=traefik"
          "--disable=servicelb"
        ]
        ++ (lib.mapAttrsToList (k: v: "--node-label=${k}=${v}") cfg.nodeLabels)
      );
    };

    # Longhorn's prerequisites: iscsi + nfs client utils, open-iscsi running.
    environment.systemPackages = with pkgs; [
      openiscsi
      nfs-utils
      cryptsetup
    ];
    services.openiscsi = {
      enable = true;
      # TODO make this unique per host
      name = "iqn.2026-01.lan.homelab:initiator";
    };

    boot.kernelModules = [ "iscsi_tcp" ];
  };
}
