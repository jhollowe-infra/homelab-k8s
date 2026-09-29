{ lib, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  networking.hostName = "nixos-bootstrap";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  users.users.root.initialHashedPassword = lib.mkForce null;
  users.users.root.initialPassword = "nixos";

  services.qemuGuest.enable = true;

  boot.zfs.forceImportRoot = false;

  image.baseName = lib.mkForce "nixos-bootstrap";
  image.fileName = "nixos-bootstrap.iso";
}
