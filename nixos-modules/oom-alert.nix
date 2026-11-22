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
#
# Container attribution: the "Killed process" line only has the process
# name and PID. The kernel emits a separate `oom-kill:constraint=...,
# task_memcg=<cgroup path>,task=<comm>,pid=...` line (dump_oom_summary in
# mm/oom_kill.c) immediately before it. The cgroup path for a Kubernetes
# container ends in the 64-hex container ID (e.g. .../cri-containerd-<id>.scope),
# so we grep for both lines, remember the `oom-kill:` one, extract the ID
# when the `Killed process` line arrives, and ask the container runtime
# (crictl) for the pod/container name. The killed container is normally
# still present as an exited container until kubelet GCs it, and the timer
# runs every minute, so the lookup almost always succeeds. If it doesn't,
# the alert falls back to the raw cgroup path / short ID rather than dropping.
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
      pkgs.cri-tools # crictl, to map container ID -> pod/container name
      pkgs.jq
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

      # Adjust if not running k3s (e.g. unix:///run/containerd/containerd.sock).
      export CONTAINER_RUNTIME_ENDPOINT="unix:///run/k3s/containerd/containerd.sock"

      ctx=""
      last_pid=""
      pid_re='Killed process ([0-9]+)'

      journalctl -k -b all -g 'oom-kill:|Killed process' -o cat --cursor-file="$cursor_file" --no-pager \
        | while IFS= read -r line; do
            # Context line comes first; stash it and wait for "Killed process".
            if [[ "$line" == oom-kill:* ]]; then
              ctx="$line"
              continue
            fi

            # The kernel/journal can emit the same "Killed process" line more
            # than once for a single kill; alert once per PID.
            pid=""
            if [[ "$line" =~ $pid_re ]]; then
              pid="''${BASH_REMATCH[1]}"
            fi
            if [ -n "$pid" ] && [ "$pid" = "$last_pid" ]; then
              continue
            fi
            last_pid="$pid"

            where="unknown"
            if [[ "$ctx" =~ task_memcg=([^,]*) ]]; then
              cgpath="''${BASH_REMATCH[1]}"
              where="cgroup $cgpath"
              if [[ "$cgpath" =~ ([0-9a-f]{64}) ]]; then
                id="''${BASH_REMATCH[1]}"
                name="$(crictl ps -a --id "$id" -o json 2>/dev/null \
                  | jq -r '.containers[0] // empty
                           | "\(.labels["io.kubernetes.pod.namespace"])/\(.labels["io.kubernetes.pod.name"]) (container: \(.metadata.name))"' \
                  2>/dev/null)" || name=""
                if [ -n "$name" ]; then
                  where="$name"
                else
                  where="container ''${id:0:12} (no longer known to runtime)"
                fi
              fi
            fi

            msg=":skull: **$hostname**: OOM killer fired in **$where** - $line"
            echo "$msg"
            payload="$(jq -n --arg content "$msg" '{content: $content}')"
            curl -sf -X POST "$webhook" \
              -H "Content-Type: application/json" \
              -d "$payload"
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
