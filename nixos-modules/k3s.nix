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
    tlsSan = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional subject alternative names for the k3s API server certificate.";
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
      2379 # embedded etcd client
      2380 # embedded etcd peer
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

    # this might be needed for NAS support?
    # boot.supportedFilesystems = [ "nfs" ];
    # services.rpcbind.enable = true;

    services.k3s = {
      enable = true;
      role = cfg.role;
      tokenFile = config.sops.secrets.k3s-token.path;
      clusterInit = cfg.clusterInit;
      serverAddr = lib.mkIf (cfg.serverAddr != null) cfg.serverAddr;
      extraFlags = lib.concatStringsSep " " (
        [
          # Longhorn needs its own replication/HA; disable k3s's built-in
          # single-node local-path-provisioner. Traefik/ServiceLB are also
          # disabled: homelab-apps's Flux-managed MetalLB + separately
          # Helm-managed Traefik (see README's "External ingress & load
          # balancing") replace them, and ServiceLB would otherwise race
          # MetalLB for the same `type: LoadBalancer` Services.
          "--disable=local-storage"
          "--disable=traefik"
          "--disable=servicelb"
        ]
        ++ (map (san: "--tls-san=${san}") cfg.tlsSan)
        ++ (lib.mapAttrsToList (k: v: "--node-label=${k}=${v}") cfg.nodeLabels)
      );
    };

    # Longhorn's prerequisites: iscsi + nfs client utils, open-iscsi running.
    environment.systemPackages = with pkgs; [
      openiscsi # used by longhorn
      nfs-utils
      cryptsetup
    ];

    # used by longhorn
    services.openiscsi = {
      enable = true;
      name = "${config.networking.hostName}-initiatorhost";
    };

    # TODO look into implementing /usr/local/bin/k3s-killall.sh on shutdown to actually kill containers

    systemd.services.drain-k3s-on-shutdown = {
      description = "Drain K3s node before shutdown";

      # Ensure it runs AFTER k3s is fully operational during boot,
      # which means systemd will stop it BEFORE k3s stops during shutdown.
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      # Ensure this service stops before shutdown.target (i.e., during the
      # normal service shutdown phase, not during the final "unmount everything"
      # phase). Without this, DefaultDependencies=no breaks shutdown ordering.
      before = [ "shutdown.target" ];

      unitConfig = {
        # Keep DefaultDependencies=no to avoid pulling in unnecessary deps,
        # but we must explicitly order against shutdown.target
        DefaultDependencies = "no";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        # Environment pointing to the default K3s kubeconfig location in NixOS
        Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";

        # Do nothing on startup
        ExecStart = "${pkgs.coreutils}/bin/true";

        # The actual drain action triggered strictly on shutdown/reboot
        ExecStop = ''
          ${pkgs.k3s}/bin/kubectl drain %H \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --force \
            --grace-period=60
        '';
        # TODO this drains the node, but containers are still left running after shutdown.service

        # Give the drain command enough time to evict pods gracefully
        TimeoutStopSec = 300;
      };

      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.uncordon-k3s-on-startup = {
      description = "Uncordon K3s node after API server is ready";

      # Run after the k3s service has initialized
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Ensure kubectl can find the correct config file path
        Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";

        ExecStart = pkgs.writeShellScript "k3s-uncordon-node" ''
          NODE_NAME="${config.networking.hostName}"

          echo "Waiting for K3s API server and node '$NODE_NAME' to become ready..."
          # Loop until kubectl can successfully reach the API and see the node
          until ${pkgs.k3s}/bin/kubectl get node "$NODE_NAME" &>/dev/null; do
            echo -n "."
            sleep 2
          done

          echo "Node found. Uncordoning '$NODE_NAME'..."
          ${pkgs.k3s}/bin/kubectl uncordon "$NODE_NAME"
        '';
      };
    };

    boot.kernelModules = [ "iscsi_tcp" ];
  };
}
