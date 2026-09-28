# Alert (Discord webhook) when /var/lib/longhorn usage crosses a threshold,
# every 15 minutes - deduped, so it only posts on first crossing, then at
# most once a day while still over threshold. Growing the disk itself is a
# separate module/service (homelab-longhorn-disk-grow, see
# longhorn-disk-grow.nix) - split out so growing and alerting can be
# reasoned about/tested independently.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelabLonghornDiskAlert;
in
{
  options.homelabLonghornDiskAlert = {
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

    systemd.services.homelab-longhorn-disk-alert = {
      description = "Alert via Discord when the Longhorn disk crosses the usage threshold";
      path = [
        pkgs.curl
        pkgs.coreutils
      ];
      serviceConfig.Type = "oneshot";
      script = ''
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

    systemd.timers.homelab-longhorn-disk-alert = {
      description = "Periodic Longhorn disk usage check + Discord alert";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
        Unit = "homelab-longhorn-disk-alert.service";
      };
    };
  };
}
