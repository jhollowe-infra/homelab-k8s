# Static IPv4 addressing per node. Terraform (terraform/modules/vm) assigns
# the same address via cloud-init before NixOS is installed, so a node's IP
# never changes across the nixos-anywhere install.
#
# systemd-networkd option names below verified against nixpkgs source
# (nixos/modules/system/boot/networkd.nix, nixos/lib/systemd-network-units.nix):
# matchConfig.Name -> [Match] Name=; address/gateway/dns (listOf str) each
# render one Address=/Gateway=/DNS= line per entry in [Network];
# networkConfig.DHCP is a valid [Network] key (accepts "no" to fully disable).
{ config, lib, ... }:
let
  cfg = config.homelabNetwork;
in
{
  options.homelabNetwork = {
    address = lib.mkOption {
      type = lib.types.str;
      description = ''This node's static IPv4 address in CIDR form, e.g. "10.10.100.10/16".'';
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.10.0.1";
      description = "Default gateway, shared by all nodes (VLAN 100).";
    };
    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "10.10.0.1" ];
      description = "DNS servers, shared by all nodes (VLAN 100).";
    };
  };

  config = {
    networking.useDHCP = false;
    networking.useNetworkd = true;

    # Matched by name pattern rather than a specific interface name (e.g.
    # "ens18"): Proxmox's predictable-name assignment for the virtio NIC
    # isn't fixed in advance, since these VMs also have GPU(s) passed
    # through via hostpci (terraform/modules/vm/main.tf) which can shift
    # PCI slot numbering. Each VM has exactly one Ethernet NIC (the GPUs
    # aren't network interfaces), so "en*" is unambiguous.
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      address = [ cfg.address ];
      gateway = [ cfg.gateway ];
      dns = cfg.dns;
      networkConfig.DHCP = "no";
    };
  };
}
