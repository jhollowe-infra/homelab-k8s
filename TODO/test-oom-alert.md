# TODO: Test `nixos-modules/oom-alert.nix` against a live node

Delete this file once the OOM alert (see `TODO/monitoring-alerting.md`
section 3) has been manually verified working on real hardware - it's
scratch/throwaway testing instructions, not a permanent design note.

Prerequisite: `discord-webhook-url-resources` must be populated with a
real Discord webhook in `secrets/secrets.sops.yaml` and deployed, per
`secrets/secrets.sops.yaml.example`.

1. **First-run sanity check** (no OOM has happened, no cursor file yet):
   ```
   systemctl start homelab-oom-alert
   systemctl status homelab-oom-alert   # should be inactive/exited, no failure
   journalctl -u homelab-oom-alert -n 20
   ls -la /var/lib/homelab-oom-alert/   # cursor file should now exist
   ```
   Confirms the service runs cleanly end-to-end (secret readable, `-b all`
   full-history scan completes, cursor file gets created) with no false
   Discord post when there's nothing to report.

2. **Trigger a real, contained OOM kill** - don't actually starve the
   whole node; use a scoped transient cgroup so only a throwaway process
   is killed:
   ```
   systemd-run --scope -p MemoryMax=50M -p MemorySwapMax=0 \
     bash -c 'tail /dev/zero | tail'
   ```
   This should get OOM-killed within seconds. Confirm the kernel logged it:
   ```
   journalctl -k -b 0 -g 'Killed process' -n 5
   ```
   (the "Killed process" line is logged by `__oom_kill_process` the same
   way for both a cgroup-scoped OOM and a system-wide one - verified
   against the kernel source, `mm/oom_kill.c` - so this is a safe,
   realistic stand-in for a genuine host-wide OOM without actually risking
   the node).

3. **Confirm the alert fires exactly once for that kill**:
   ```
   systemctl start homelab-oom-alert
   ```
   Check the configured Discord channel for exactly one new message
   referencing the killed process, and check the cursor file advanced:
   ```
   cat /var/lib/homelab-oom-alert/cursor
   ```

4. **Confirm no duplicate alert on a second run** with nothing new to
   report:
   ```
   systemctl start homelab-oom-alert
   ```
   Discord channel should get no new message, and
   `journalctl -u homelab-oom-alert -n 20` should show it exited quickly
   having found zero new matching entries.

5. **Confirm the timer itself is wired up** (don't just rely on manual
   `systemctl start`):
   ```
   systemctl list-timers homelab-oom-alert.timer
   ```
   Should show a next-trigger time ~1 minute out.

6. **Spot-check resource usage stays light**, per the point of this
   module - after a run:
   ```
   systemctl show homelab-oom-alert -p MemoryPeak -p CPUUsageNSec
   ```
   Should be small/negligible; if `MemoryPeak` comes back surprisingly
   large on a node with a big journal, that's a sign the `-b all` full-scan
   cost on first run (or after a cursor file is lost/deleted) needs
   revisiting - e.g. bounding the first scan with `--since` instead of a
   true unbounded `-b all`.

7. **Optional, harder to test in isolation**: reboot the node, then
   trigger another contained OOM (step 2) and confirm the alert still
   fires correctly post-reboot - checks that `-b all` (overriding `-k`'s
   default `--boot=0`) actually does what's claimed across a real boot
   boundary, not just within one boot.
