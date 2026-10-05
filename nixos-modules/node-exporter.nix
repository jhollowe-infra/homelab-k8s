# Prometheus node_exporter, run NixOS-native rather than as the
# kube-prometheus-stack chart's DaemonSet (homelab-apps's Prometheus scrapes
# these directly via additionalScrapeConfigs) - see
# TODO/monitoring-alerting.md section 1 for why: this keeps reporting
# host-level metrics (disk, CPU, memory, systemd unit state) even if
# k3s/containerd itself is the thing that's broken, which a DaemonSet
# running inside the cluster can't do.
#
# services.prometheus.exporters.node options verified against nixpkgs
# source (nixos/modules/services/monitoring/prometheus/exporters/node.nix
# + the shared exporter framework in exporters.nix): port defaults to 9100,
# listenAddress/openFirewall/enabledCollectors/disabledCollectors/extraFlags
# are all real options; enabledCollectors/disabledCollectors are additive/
# subtractive on top of node_exporter's own default collector set, not a
# full replacement of it. openFirewall adds its own firewall rule directly
# (not via networking.firewall.allowedTCPPorts), scoped to this exporter's
# port only.
{
  services.prometheus.exporters.node = {
    enable = true;
    # "systemd" isn't in node_exporter's own default collector set; enable
    # it explicitly since systemd unit state is one of the host-level
    # signals this module exists to report (see comment above).
    enabledCollectors = [ "systemd" ];
    openFirewall = true;
  };
}
