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

Currently the only alerting in the homelab is the one-off Discord webhook in
`nixos-modules/longhorn-disk-alert.nix` (Longhorn disk usage) — itself an
example of the pattern this note's host-level alerts follow: alerting
posted directly from a host, independent of the in-cluster stack.

## 1. NixOS-native `node-exporter`

Run `node-exporter` as a native NixOS systemd service
(`services.prometheus.exporters.node`) on all 3 nodes, instead of
kube-prometheus-stack's node-exporter DaemonSet (disable that subchart in
`homelab-apps`'s Helm values to avoid running it twice). Point
`homelab-apps`'s Prometheus at it via `additionalScrapeConfigs`/a static
target list.

Rationale: this keeps reporting host-level metrics (disk, CPU, memory,
systemd unit state) even if k3s/containerd itself is the thing that's
broken — exactly the failure mode worth catching early (a node going bad
without the other 2 noticing). Given these nodes are already managed
declaratively via NixOS (`hosts/common/default.nix`), this fits naturally
as another `nixos-modules/*.nix` module, similar in spirit to `k3s.nix`.

Confirm the NixOS option name/`enabledCollectors` list against the actual
NixOS module docs (`nixos-option` / search.nixos.org) before implementing,
since specifics above came from a search summary, not verified docs.

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

- **OOM killer invocations.**
- **Root disk >=95% full for at least 30 minutes** (sustained, not a
  momentary spike).
- **NixOS auto-update failure.** The auto-update's status (success or
  failure) should also get pushed into the monitoring/metrics system
  either way (mechanism TBD — textfile collector for node-exporter,
  pushgateway, or similar), but this host-level alert itself should only
  *fire* on failure, not on every successful run.

Each of these posts to whichever Discord webhook/category `homelab-apps`'s
alerting plan assigns it to (see `homelab-apps/TODO/alerting.md`'s
category list) — exact assignment TBD at implementation time.

## Open questions to resolve before implementing

- Exact NixOS module option names/`enabledCollectors` for
  `services.prometheus.exporters.node` — verify against NixOS docs.
- Exact k3s flag/metric names for etcd and cert-expiry metrics exposure —
  verify against k3s docs before relying on search-summarized names.
- Mechanism for pushing NixOS auto-update status into the metrics system
  on success (textfile collector vs. pushgateway vs. other).
- Which Discord category (per `homelab-apps`'s alerting plan) each
  host-level alert (OOM, disk, auto-update failure) belongs to.
- Follow-up TODO (not yet scoped): pull in Proxmox host-level and
  NixOS-VM-level status, so host/hypervisor health (separate from
  in-cluster k8s monitoring) is covered too.
