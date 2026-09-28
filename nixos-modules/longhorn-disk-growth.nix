# Two-step routine for "start the Longhorn disk small, grow it as it fills
# up", run together every 15 minutes:
#
#   1. Grow: check whether the underlying virtual disk (/dev/vdb) has been
#      enlarged since the partition was created, and if so grow the
#      partition + ext4 filesystem online. This is what makes "bump the
#      size in terraform.tfvars, tofu apply" sufficient on its own - no
#      manual in-VM step.
#   2. Alert: check /var/lib/longhorn usage: if it's crossed 80%, post to a
#      Discord webhook (deduped - only on first crossing, then at most once
#      a day while still over threshold).
#
# Why not disko for the resize: disko only runs at initial install
# (nixos-anywhere); it has no "reapply and grow existing partitions" mode,
# so a later virtual-disk enlargement needs this separate growpart step.
#
# cloud-utils/growpart usage verified against nixpkgs source
# (pkgs/by-name/cl/cloud-utils/package.nix and nixpkgs' own built-in
# nixos/modules/system/boot/grow-partition.nix module): growpart is
# packaged in cloud-utils (available via both the `out` and `guest`
# outputs), and nixpkgs' own growpart systemd unit sets
# `SuccessExitStatus = "0 1"` with the comment "growpart returns 1 if the
# partition is already grown" - directly confirming the 0/1 exit-code
# handling used below. `e2fsprogs` (providing `resize2fs`) is confirmed
# to exist as a package in nixpkgs; resize2fs itself is not a NixOS
# module API, so there's nothing further to verify there against nixpkgs.
# The alert/dedup logic and 80%-threshold policy are this repo's own
# design, not sourced from nixpkgs - still worth testing manually
# (`systemctl start homelab-longhorn-disk-growth`) after a real Terraform
# disk resize before trusting the unattended timer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelabLonghornDiskGrowth;
in
{
  options.homelabLonghornDiskGrowth = {
    thresholdPercent = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = "Usage percent of /var/lib/longhorn that triggers a Discord alert.";
    };
  };

  config = {
    sops.secrets.discord-webhook-url = {
      sopsFile = ../secrets/secrets.sops.yaml;
      owner = "root";
      mode = "0400";
    };

    systemd.services.homelab-longhorn-disk-growth = {
      description = "Grow the Longhorn disk if enlarged, then alert on high usage";
      path = [
        pkgs.cloud-utils
        pkgs.e2fsprogs
        pkgs.curl
        pkgs.coreutils
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        set +e
        growpart /dev/vdb 1
        status=$?
        set -e
        # growpart: 0 = grew it, 1 = already at max size (both fine)
        if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
          echo "growpart failed with exit code $status" >&2
          exit "$status"
        fi
        resize2fs /dev/vdb1

        webhook="$(cat ${config.sops.secrets.discord-webhook-url.path})"
        state_file=/var/lib/homelab-longhorn-alert-state
        used_pct=$(df --output=pcent /var/lib/longhorn | tail -1 | tr -dc '0-9')
        hostname=$(hostname)

        should_alert=false
        if [ "$used_pct" -ge ${toString cfg.thresholdPercent} ]; then
          last_alert_day=""
          [ -f "$state_file" ] && last_alert_day=$(cat "$state_file")
          today=$(date +%F)
          # Alert on first crossing, then at most once/day while still over.
          if [ "$last_alert_day" != "$today" ]; then
            should_alert=true
            echo "$today" > "$state_file"
          fi
        else
          rm -f "$state_file"
        fi

        if [ "$should_alert" = true ]; then
          echo "Longhorn disk on $hostname at ''${used_pct}%, alerting."
          curl -sf -X POST "$webhook" \
            -H "Content-Type: application/json" \
            -d "{\"content\": \":warning: **$hostname**: Longhorn disk (/var/lib/longhorn) is at ''${used_pct}% used. Grow it: bump longhorn_disk_gb for this node in terraform.tfvars and run tofu apply - this node auto-grows into the new space within 15 minutes.\"}"
        fi
      '';
    };

    systemd.timers.homelab-longhorn-disk-growth = {
      description = "Periodic Longhorn disk growpart + usage alert";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
        Unit = "homelab-longhorn-disk-growth.service";
      };
    };
  };
}
