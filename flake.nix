{
  description = "homelab-k8s: NixOS + k3s cluster config and Proxmox VM tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    colmena = {
      url = "github:nix-community/colmena/v0.5.0";
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
    nixos-common = {
      url = "github:jhollowe-infra/nixos-common";
      flake = false;
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
      nixos-common,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      nixosCommonModules = map (module: nixos-common + module) [
        "/env/qemu.nix"
        "/fs/swapfile.nix"
        "/env/ny_time.nix"
        "/env/en_us_utf8.nix"
        "/net/default.nix"
        "/workloads/ssh.nix"
        "/workloads/flakes.nix"
      ];

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
          ++ nixosCommonModules
          ++ extraModules;
        };

      bootstrapIso = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./image/bootstrap-iso.nix ];
      };
    in
    {
      # Plain NixOS configs, used by nixos-anywhere for first install
      # (nixos-anywhere --flake .#<hostName>) and available for
      # `nixos-rebuild --flake .#<hostName>` if you ever want to run that
      # directly against a node instead of going through Colmena.
      nixosConfigurations = {
        bootstrap-iso = bootstrapIso;
        hl01-kube01 = mkHost "hl01-kube01" [ ];
        hl01-kube02 = mkHost "hl01-kube02" [ ];
        hl01-kube03 = mkHost "hl01-kube03" [ ];
      };

      # Colmena hive for day-2 config deploys across all nodes at once.
      # See: https://colmena.cli.rs/
      colmenaHive = colmena.lib.makeHive self.outputs.colmena;
      colmena = {
        meta = {
          nixpkgs = pkgs;
          specialArgs = { inherit self; };
        };
        defaults = { ... }: {
          imports = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./hosts/common
          ]
          ++ nixosCommonModules;
        };
        hl01-kube01 = { ... }: {
          deployment.targetHost = "hl01-kube01.kube-nodes.johnhollowell.internal";
          imports = [ ./hosts/hl01-kube01 ];
        };
        hl01-kube02 = { ... }: {
          deployment.targetHost = "hl01-kube02.kube-nodes.johnhollowell.internal";
          imports = [ ./hosts/hl01-kube02 ];
        };
        hl01-kube03 = { ... }: {
          deployment.targetHost = "hl01-kube03.kube-nodes.johnhollowell.internal";
          imports = [ ./hosts/hl01-kube03 ];
        };
      };

      packages.${system} = {
        bootstrap-iso = bootstrapIso.config.system.build.isoImage;
        default = pkgs.buildEnv {
          name = "homelab-k8s-devshell";
          paths = [
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
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = self.packages.${system}.default;
        shellHook = ''
          echo "homelab-k8s dev shell: tofu, colmena, nixos-anywhere, sops, age, kubectl, helm available."
        '';
      };
    };
}
