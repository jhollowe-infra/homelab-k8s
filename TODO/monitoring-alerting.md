# TODO: Host-level monitoring & alerting (NixOS/k3s-host scope)

> Scope note: in-cluster metrics, dashboards, and alerting (kube-prometheus-
> stack, Alertmanager, Discord routing/categories, Flux-reconciliation
> alerting, "what alerts matter" at the k8s-resource level, TSDB storage
> placement) are planned and implemented in `homelab-apps`'s
> `TODO/alerting.md`, not here. This note is scoped to what actually has to
> live on the NixOS hosts themselves: the node-exporter module, host-level
> alerts that must work independently of the in-cluster stack, and k3s
> config flags needed to expose metrics for `homelab-apps`'s Prometheus to
> scrape.

> NOTE on sourcing: everything below marked with a source came from web
> searches done 2026-09 and is search-engine-summarized, not fetched/read
> directly from primary docs (k3s docs, Alertmanager source). Treat
> specifics (exact metric names, exact flags) as "needs verification
> against the real docs/a real test deploy" before actually implementing.

Currently the only pre-existing alerting in the homelab was the one-off
Discord webhook in `nixos-modules/longhorn-disk-alert.nix` (Longhorn disk
usage) — itself an example of the pattern this note's host-level alerts
follow: alerting posted directly from a host, independent of the
in-cluster stack. It now posts through the `resources` category secret
(`discord-webhook-url-resources`) rather than a standalone
`discord-webhook-url`, now that the categorized scheme below exists - the
old uncategorized secret has been removed; **`secrets/secrets.sops.yaml`
needs a one-time manual edit to rename/replace that field before
redeploying** (see the note on `oom-alert.nix` below - same blocker, same
secret).

## 1. NixOS-native `node-exporter` — DONE

Implemented in `nixos-modules/node-exporter.nix`, imported by every node via
`hosts/common/default.nix`. Runs `services.prometheus.exporters.node` (the
`systemd` collector explicitly enabled, since it's off by default in
node_exporter itself; `openFirewall` on, which adds its own scoped firewall
rule for port 9100, not via `networking.firewall.allowedTCPPorts`),
confirmed directly against the nixpkgs module source (not just a search
summary) — see the comment in that file.

This replaces the kube-prometheus-stack chart's `nodeExporter` DaemonSet
(disable that subchart in `homelab-apps`'s Helm values); `homelab-apps`'s
Prometheus still needs an `additionalScrapeConfigs`/static target list
pointing at each node's IP on port 9100 — that wiring is `homelab-apps`'s
side of this, not done here.

Rationale: this keeps reporting host-level metrics (disk, CPU, memory,
systemd unit state) even if k3s/containerd itself is the thing that's
broken — exactly the failure mode worth catching early (a node going bad
without the other 2 noticing).

## 2. k3s config flags needed for `homelab-apps`'s Prometheus to scrape

These are NixOS/k3s config changes that belong here even though the
consuming Prometheus scrape config lives in `homelab-apps`:

- **etcd metrics**: since all 3 nodes run k3s's embedded HA etcd, enable
  `etcd-expose-metrics: true` (port 2381) so `homelab-apps`'s
  `kubeEtcd.endpoints` can point at the 3 node IPs directly, rather than
  relying on kube-prometheus-stack's kubeadm-style auto-discovery (which
  doesn't apply to k3s).
- **Certificate expiry**: k3s auto-rotates most certs on service restart
  within ~120 days of a 365-day validity per search results, but the root
  CAs are ~10yr and don't auto-renew. k3s's own `supervisor-metrics`
  (reportedly exposing a `k3s_certificate_expiration_seconds` metric) is
  the natural first thing to try, since it's the least additional
  infrastructure — **verify the exact flag/metric name against k3s docs**
  before relying on it. If that doesn't pan out, the alternative
  (`x509-certificate-exporter` DaemonSet, or the generic apiserver
  `apiserver_client_certificate_expiration_seconds` metric) would be an
  in-cluster component and belongs in `homelab-apps`'s scope instead.

## 3. Host-level alerts (independent of the in-cluster stack)

Posted directly from the host (same pattern as
`nixos-modules/longhorn-disk-alert.nix`), not depending on
Prometheus/Alertmanager being up. To start:

- **OOM killer invocations — DONE.** Implemented in
  `nixos-modules/oom-alert.nix`, imported by every node via
  `hosts/common/default.nix`. Fires once per OOM-killer invocation (not
  deduped/throttled like the Longhorn disk alert, since each OOM kill is
  its own distinct event worth reporting). Deliberately avoids
  `journalctl -f` (a long-running follow process would keep journal data
  mapped into memory for its whole lifetime — counterproductive for a
  service meant to help during memory pressure); instead it's a oneshot
  on a 1-minute timer using `journalctl --cursor-file` to pick up exactly
  where the last run left off, filtered to kernel messages matching
  "Killed process" (the exact text the kernel's OOM killer logs, per
  `mm/oom_kill.c`). No hard `MemoryMax` (journalctl's mmap'd journal pages
  would get charged to the service's own cgroup and could make it the
  thing that gets OOM-killed on a large first scan); instead it's made
  "light" via `OOMScoreAdjust=1000` (always the first kill candidate,
  never a contributor to the problem it's reporting), `Nice=19`, and
  `IOSchedulingClass=idle`. Posts to the `discord-webhook-url-resources`
  sops secret (the `resources` category per
  `homelab-apps/TODO/alerting.md`) — **you still need to create that
  Discord webhook and add the real value to `secrets/secrets.sops.yaml`**
  (placeholders for all 4 categories were added to
  `secrets.sops.yaml.example`, replacing the old standalone
  `discord-webhook-url` field entirely - both this module and
  `longhorn-disk-alert.nix` now read `discord-webhook-url-resources`; the
  actual encrypted secrets need `sops -e -i` run with real `sops`/`age`
  access, which wasn't available in the environment that implemented
  this).
  **Not yet tested against a live node/journal - see
  `TODO/test-oom-alert.md` before trusting it unattended.**
- **Root disk >=95% full for at least 30 minutes** (sustained, not a
  momentary spike).
- **NixOS auto-update failure.** The auto-update's status (success or
  failure) should also get pushed into the monitoring/metrics system
  either way (mechanism TBD — textfile collector for node-exporter,
  pushgateway, or similar), but this host-level alert itself should only
  *fire* on failure, not on every successful run.

## Open questions to resolve before implementing

- Exact k3s flag/metric names for etcd and cert-expiry metrics exposure —
  verify against k3s docs before relying on search-summarized names.
- Mechanism for pushing NixOS auto-update status into the metrics system
  on success (textfile collector vs. pushgateway vs. other).
- Which Discord category (per `homelab-apps`'s alerting plan) the disk and
  auto-update-failure alerts belong to (OOM is settled: `resources`, see
  above).
- Follow-up TODO (not yet scoped): pull in Proxmox host-level and
  NixOS-VM-level status, so host/hypervisor health (separate from
  in-cluster k8s monitoring) is covered too.
