# Alert (Discord webhook) once per OOM-killer invocation, independent of the
# in-cluster Prometheus/Alertmanager stack - same "alert directly from the
# host" pattern as longhorn-disk-alert.nix. See TODO/monitoring-alerting.md
# section 3.
#
# Deliberately NOT `journalctl -f` (a long-running follow process): that
# would hold the journal mapped in memory for the service's entire lifetime,
# which is the opposite of "light" when the thing being watched for is
# memory pressure. Instead this runs as a cheap oneshot on a short timer,
# using `--cursor-file` so each run only has to look at entries it hasn't
# seen yet - the journal is barely touched between actual OOM events.
#
# journalctl behavior below verified against the systemd man page source
# (upstream doc/journalctl.xml, fetched directly, not search-summarized):
# `--cursor-file=FILE`: "If FILE exists and contains a cursor, start
# showing entries after this location... At the end, write the cursor of
# the last entry to FILE. Use this option to continually read the journal
# by sequentially calling journalctl." (added in systemd v242) - exactly
# the "process each entry exactly once" semantics this needs, no manual
# cursor bookkeeping. `-k`/`--dmesg` "implies --boot=0 unless explicitly
# specified otherwise" - `-b all` below overrides that explicitly, so an
# OOM logged right before a reboot isn't silently skipped just because the
# next run happens to land on the following boot. `-g`/`--grep` matches
# against the `MESSAGE=` field using PCRE2, case-sensitive here since the
# pattern isn't all-lowercase (matches the kernel's exact "Killed process"
# text from mm/oom_kill.c's pr_err() call, verified against the kernel
# source directly).
{
  config,
  pkgs,
  ...
}:
{
  sops.secrets.discord-webhook-resources = {
    sopsFile = ../secrets/secrets.sops.yaml;
    owner = "root";
    mode = "0400";
  };

  systemd.services.homelab-oom-alert = {
    description = "Alert via Discord on each new OOM-killer invocation";
    path = [
      pkgs.curl
      pkgs.coreutils
      config.systemd.package # journalctl
    ];
    serviceConfig = {
      Type = "oneshot";
      # No hard MemoryMax here: journalctl mmaps the journal files it scans,
      # and those mapped pages get charged to this cgroup under cgroup v2 -
      # a hard cap could make this service itself the thing that gets OOM-
      # killed (e.g. on the very first run, before a cursor file exists,
      # when it has to scan the full `-b all` history). Make it light via
      # scheduling instead: lowest OOM-kill priority (first to go if memory
      # does run out, never a contributor), low CPU/IO priority so it never
      # competes with real work.
      OOMScoreAdjust = 1000;
      Nice = 19;
      IOSchedulingClass = "idle";
      StateDirectory = "homelab-oom-alert";
    };
    script = ''
      webhook="$(cat ${config.sops.secrets.discord-webhook-resources.path})"
      cursor_file=/var/lib/homelab-oom-alert/cursor
      hostname=${config.networking.hostName}

      journalctl -k -b all -g 'Killed process' -o cat --cursor-file="$cursor_file" --no-pager \
        | while IFS= read -r line; do
            echo "OOM kill on $hostname: $line"
            curl -sf -X POST "$webhook" \
              -H "Content-Type: application/json" \
              -d "{\"content\": \":skull: **$hostname**: OOM killer fired - $line\"}"
          done
    '';
  };

  systemd.timers.homelab-oom-alert = {
    description = "Periodic check for new OOM-killer invocations";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      Unit = "homelab-oom-alert.service";
    };
  };
}
