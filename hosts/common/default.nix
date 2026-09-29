# Config shared by every k8s node.
{ pkgs, ... }:
{
  imports = [
    ./disko.nix
    ../../nixos-modules/k3s.nix
    ../../nixos-modules/network.nix
    ../../nixos-modules/auto-upgrade.nix
    # ../../nixos-modules/longhorn-disk-grow.nix
    # ../../nixos-modules/longhorn-disk-alert.nix
  ];

  system.stateVersion = "26.05";

  # make sure the initramfs has the modules needed to use virtio devices/disks
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
  ];

  # Combined with each host's `networking.hostName`, gives FQDNs like
  # hl01-kube01.kube-nodes.johnhollowell.internal - used below (flake.nix
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
  networking.firewall.allowedTCPPorts = [ 22 ];

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
