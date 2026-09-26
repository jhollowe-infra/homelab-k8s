{
  description = "homelab-k8s: NixOS + k3s cluster config and Proxmox VM tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      colmena,
      sops-nix,
      nixos-anywhere,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      mkHost =
        hostName: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit self; };
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./hosts/common
            ./hosts/${hostName}
          ]
          ++ extraModules;
        };
    in
    {
      # Plain NixOS configs, used by nixos-anywhere for first install
      # (nixos-anywhere --flake .#<hostName>) and available for
      # `nixos-rebuild --flake .#<hostName>` if you ever want to run that
      # directly against a node instead of going through Colmena.
      nixosConfigurations = {
        k8s-node-1 = mkHost "k8s-node-1" [ ];
        k8s-node-2 = mkHost "k8s-node-2" [ ];
        k8s-node-3 = mkHost "k8s-node-3" [ ];
      };

      # Colmena hive for day-2 config deploys across all nodes at once.
      # See: https://colmena.cli.rs/
      colmenaHive = colmena.lib.makeHive self.outputs.colmena;
      colmena = {
        meta = {
          inherit nixpkgs;
          specialArgs = { inherit self; };
        };
        defaults = { ... }: {
          imports = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./hosts/common
          ];
        };
        k8s-node-1 = { ... }: {
          deployment.targetHost = "k8s-node-1.kube-nodes.johnhollowell.internal";
          imports = [ ./hosts/k8s-node-1 ];
        };
        k8s-node-2 = { ... }: {
          deployment.targetHost = "k8s-node-2.kube-nodes.johnhollowell.internal";
          imports = [ ./hosts/k8s-node-2 ];
        };
        k8s-node-3 = { ... }: {
          deployment.targetHost = "k8s-node-3.kube-nodes.johnhollowell.internal";
          imports = [ ./hosts/k8s-node-3 ];
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.opentofu
          colmena.packages.${system}.colmena
          nixos-anywhere.packages.${system}.default
          pkgs.sops
          pkgs.age
          pkgs.ssh-to-age
          pkgs.kubectl
          pkgs.kubernetes-helm
          pkgs.jq
          pkgs.openssh
        ];
        shellHook = ''
          echo "homelab-k8s dev shell: tofu, colmena, nixos-anywhere, sops, age, kubectl, helm available."
        '';
      };
    };
}
