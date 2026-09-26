# Config shared by every k8s node.
{ pkgs, ... }:
{
  imports = [
    ./disko.nix
    ../../nixos-modules/k3s.nix
    ../../nixos-modules/network.nix
    ../../nixos-modules/auto-upgrade.nix
    ../../nixos-modules/longhorn-disk-growth.nix
  ];

  system.stateVersion = "26.05";

  # Combined with each host's `networking.hostName`, gives FQDNs like
  # k8s-node-1.kube-nodes.johnhollowell.internal - used below (flake.nix
  # Colmena targetHost, homelabK3s.serverAddr).
  networking.domain = "kube-nodes.johnhollowell.internal";

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
    # homelab-auto-upgrade (nixos-modules/auto-upgrade.nix) relies on
    # `nixos-rebuild switch --rollback` being able to fall back to the
    # previous generation - keep several around, and make sure GC (below)
    # never collects them out from under it.
    configurationLimit = 10;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  networking.firewall.enable = true;
  # k3s/flannel/kubelet ports; tighten this once the cluster is stable
  # and you know exactly what needs to cross node boundaries.
  networking.firewall.allowedTCPPorts = [
    22
    6443
    10250
  ];
  networking.firewall.allowedUDPPorts = [ 8472 ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILjyoZakOhGPmzJx3zH8vEizvfMbM5Aa8iTuP5VAk+QK 3:jhollowe@JOHN-DESKTOP.internal.johnhollowell.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDr9lnRhfAPce+yYxNMIL9EWa7dOl2u0vjq5qVM5P17i jhollowe@JOHN-LAPTOP.internal.johnhollowell.com"
  ];

  environment.systemPackages = with pkgs; [
    vim
    git
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
