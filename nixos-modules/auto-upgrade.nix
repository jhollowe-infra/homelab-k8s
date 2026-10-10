# Each node pulls this repo's flake on its own schedule and applies it -
# no central "push" step needed for day-2 NixOS config changes. Terraform/
# Proxmox-level changes (new node, disk resize) are NOT covered by this;
# those still require running `tofu apply` from outside the VMs.
#
# This replaces NixOS's built-in system.autoUpgrade with a custom service,
# because a plain `nixos-rebuild switch` on a schedule has no way to know
# it broke something. If `config.homelabK3s.enable` is on, this adds two
# cluster-aware guards on top of the basic apply+rollback-on-failure logic,
# since all 3 nodes run etcd and a simultaneous bad rollout could break
# quorum on all of them at once:
#
#   1. Pre-check: skip this run entirely if the cluster is already
#      unhealthy (apiserver not ready, or any node NotReady). Don't let a
#      2nd node's scheduled upgrade pile onto a cluster that's still
#      recovering from the 1st node's upgrade.
#   2. Post-check: after switching, wait for this node to rejoin as Ready.
#      If it doesn't within the timeout, roll back too (on top of the
#      always-on rollback-if-nixos-rebuild-itself-failed below).
#
# Per-node `dates` (set in each hosts/<name>/default.nix) are staggered a
# few hours apart on top of this, so a human has a window to notice a
# rollback happened (check `journalctl -u homelab-auto-upgrade` on node-1)
# before node-2's window opens.
#
# `nixos-rebuild switch --rollback` behavior verified against nixpkgs
# source (pkgs/by-name/ni/nixos-rebuild-ng/nixos-rebuild.8.scd): it rolls
# back to the generation before the current one in
# /nix/var/nix/profiles/system, without building anything, which is why
# this is safe to use as a fast, no-build rollback path. `systemctl restart
# k3s` is also confirmed correct: the k3s module (nixos/modules/services/
# cluster/rancher/k3s.nix) names its systemd unit literally `k3s`.
# The cluster-health check logic (readyz probe, node Ready status via
# `kubectl get nodes`) and the timing/staggering strategy are this repo's
# own design, not a nixpkgs API surface - still worth a manual
# `systemctl start homelab-auto-upgrade` test on one node before trusting
# the unattended schedule, since that logic hasn't been exercised against
# a live cluster.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelabAutoUpgrade;
  k3sEnabled = config.homelabK3s.enable;
  flakeRef = "github:jhollowe-infra/homelab-k8s";

  clusterHealthFns = ''
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    cluster_healthy() {
      k3s kubectl get --raw /readyz >/dev/null 2>&1 || return 1
      if k3s kubectl get nodes --no-headers 2>/dev/null | grep -qv " Ready "; then
        return 1
      fi
      return 0
    }

    wait_for_healthy() {
      local timeout=$1 elapsed=0
      while [ "$elapsed" -lt "$timeout" ]; do
        if cluster_healthy; then
          return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
      done
      return 1
    }
  '';

  upgradeScript = pkgs.writeShellApplication {
    name = "homelab-auto-upgrade";
    runtimeInputs = [
      pkgs.nixos-rebuild
      pkgs.curl
      pkgs.coreutils
    ]
    ++ lib.optional k3sEnabled config.services.k3s.package;
    text = ''
      ${lib.optionalString k3sEnabled ''
        ${clusterHealthFns}

        echo "==> Pre-check: is the cluster healthy before upgrading?"
        if ! cluster_healthy; then
          echo "Cluster is not healthy right now - skipping this upgrade cycle so we don't compound an existing problem."
          exit 0
        fi
      ''}

      echo "==> Applying ${flakeRef}#${cfg.hostName}"
      if nixos-rebuild switch --flake "${flakeRef}#${cfg.hostName}" --print-build-logs; then
        ${
          if k3sEnabled then
            ''
              echo "==> Post-check: waiting for this node to be Ready again"
              if wait_for_healthy 180; then
                echo "Upgrade succeeded and cluster is healthy."
                exit 0
              fi
              echo "Cluster did not become healthy after the upgrade - rolling back."
              failure_reason="Post-upgrade cluster health check failed"
            ''
          else
            ''
              echo "Upgrade succeeded."
              exit 0
            ''
        }
      else
        echo "nixos-rebuild failed - rolling back."
        failure_reason="nixos-rebuild switch failed"
      fi

      if webhook="$(cat ${config.sops.secrets.discord-webhook-resources.path})" \
        && curl -sf -X POST "$webhook" \
          -H "Content-Type: application/json" \
          -d "{\"content\": \":warning: **${config.networking.hostName}**: NixOS auto-upgrade failed: $failure_reason. A rollback is being attempted. Check journalctl -u homelab-auto-upgrade for details.\"}"; then
        echo "Failure alert sent to Discord."
      else
        echo "Failed to send the Discord failure alert." >&2
      fi

      nixos-rebuild switch --rollback
      ${lib.optionalString k3sEnabled ''
        systemctl restart k3s || true
        if wait_for_healthy 120; then
          echo "Rollback succeeded, cluster healthy again."
        else
          echo "WARNING: still unhealthy after rollback. Manual intervention needed." >&2
          exit 1
        fi
      ''}
    '';
  };
in
{
  options.homelabAutoUpgrade = {
    dates = lib.mkOption {
      type = lib.types.str;
      description = "systemd.time calendar spec for this node's upgrade window, e.g. \"03:00\".";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "The flake output name to build (usually matches networking.hostName).";
    };
  };

  config = {
    sops.secrets.discord-webhook-resources = {
      sopsFile = ../secrets/secrets.sops.yaml;
      owner = "root";
      mode = "0400";
    };

    systemd.services.homelab-auto-upgrade = {
      description = "Pull and apply homelab-k8s NixOS config, with health-checked rollback";
      script = "${upgradeScript}/bin/homelab-auto-upgrade";
      serviceConfig = {
        Type = "oneshot";
        # Root: nixos-rebuild and systemctl restart k3s both need it.
        User = "root";
      };
    };

    systemd.timers.homelab-auto-upgrade = {
      description = "Timer for homelab-auto-upgrade";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        Persistent = true;
        # Small per-run jitter on top of the per-node staggered `dates`,
        # so nodes don't all hit GitHub at exactly their scheduled second.
        RandomizedDelaySec = "10min";
      };
    };
  };
}
