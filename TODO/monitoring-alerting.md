# TODO: Monitoring, metrics & alerting

Currently the only alerting in the homelab is the one-off Discord webhook in
`nixos-modules/longhorn-disk-alert.nix` (Longhorn disk usage). This note is
research/planning for a proper metrics + alerting stack, to implement later.

> NOTE on sourcing: everything below marked with a source came from web
> searches done 2026-09 and is search-engine-summarized, not fetched/read
> directly from primary docs (Prometheus docs, Longhorn docs, k3s docs,
> Alertmanager source). Treat specifics (exact metric names, exact flags,
> exact RAM numbers) as "needs verification against the real docs/`helm show
> values`/a real test deploy" before actually implementing, not as confirmed
> fact. Numbers from different searches also disagreed with each other in
> places (see the resource-footprint section) - that spread itself is a sign
> these are rough community estimates, not authoritative benchmarks.

## Recommendation (tentative)

Start with **kube-prometheus-stack** (Prometheus Operator + Prometheus +
Alertmanager + Grafana + kube-state-metrics + node-exporter, one Helm chart),
heavily trimmed - not one of the lighter alternatives - because:

- It's the ecosystem default: Longhorn and most other charts ship
  ready-made `ServiceMonitor`/`PrometheusRule` support for it specifically
  (see below), so less glue code.
- A trimmed config plausibly fits our "don't waste CPU/RAM" constraint for
  a 3-node cluster this small (see footprint section) - our scale is far
  below where people report it struggling (that's more like 50-100+ nodes
  or 500k+ series).
- VictoriaMetrics is the better choice if this ever grows or resource
  pressure turns out to be real in practice - worth re-evaluating after a
  trial, not necessary to pre-optimize for now.

Treat this as a starting hypothesis to validate with a real trial install,
not a final decision - see "Open questions" below.

## 1. kube-prometheus-stack on k3s: gotchas

- k3s does **not** run separate control-plane pods for
  scheduler/controller-manager/etcd the way kubeadm does (it's one binary),
  and by default doesn't use etcd at all (SQLite/Kine) unless embedded HA
  etcd is explicitly enabled (which we do use, per our 3-node HA design).
  The chart's default `kubeScheduler`/`kubeControllerManager`/`kubeProxy`/
  `kubeEtcd` scrape targets assume kubeadm-style separate endpoints and
  will just generate failing-scrape noise on k3s unless disabled or
  reconfigured with the right endpoints/port.
- Since we *do* run k3s's embedded etcd (for the 3-node HA control plane),
  we specifically want etcd metrics, not to blanket-disable them - see the
  etcd/cert section below for the k3s-specific way to expose that
  (`etcd-expose-metrics: true`, port 2381, and `kubeEtcd.endpoints` pointed
  at the 3 node IPs rather than relying on chart auto-discovery).
- k3s already ships its own metrics-server (for `kubectl top` / HPA); this
  is a separate thing from Prometheus and doesn't conflict, just don't
  confuse the two.
- No default StorageClass point doesn't apply to us - we'll already have
  Longhorn's default StorageClass installed by the time this goes in.

## 2. Resource footprint & trimming

Search results gave inconsistent numbers (2.5-5.5GB default down to
~1-1.5GB optimized in one source; 3-5GB+ down to <1GB in another) - treat
all of these as rough community ballpark, not measured fact for our setup.
Directionally consistent though: default install is heavy for 3 modest
nodes, a trimmed one is plausibly fine.

Commonly recommended trims (combine as needed):
- **Disable irrelevant control-plane scrape targets**: `kubeControllerManager`,
  `kubeScheduler`, `kubeProxy` off (k3s doesn't expose these the normal way).
  Keep `kubeApiServer` and `kubelet` on. Handle `kubeEtcd` specially (see
  above) since we actually want it.
- **`defaultRules.create: false`** or trim which rule groups load - the
  chart ships a large default rule/dashboard set tuned for full kubeadm
  clusters; a lot of it won't apply and costs eval overhead for nothing.
- **Reduce `scrapeInterval`/`evaluationInterval`** (e.g. 15s/30s default ->
  60s) - meaningfully cuts CPU/RAM at the cost of coarser resolution. For a
  homelab, 60s is almost certainly fine.
- **Reduce `retention`** (e.g. 3-7d instead of the ~10-15d default) and/or
  set a `retentionSize` cap - directly bounds TSDB memory/disk.
- **Set explicit `resources.requests/limits`** on every component
  (prometheus, alertmanager, grafana, kube-state-metrics, node-exporter,
  the operator itself) so nothing can silently balloon and OOM a node -
  important on our modest hardware regardless of other tuning.
- **Drop high-cardinality cAdvisor container metrics** you'll never query
  via `metricRelabelings` (`container_tasks_state`, per-fs/network/socket
  breakdowns, etc.) - one source called this "the silent RAM killer."
- Optional/aggressive: tune Go's `GOGC` env var lower on the Prometheus
  container to trade CPU for RAM.
- Optional/skip entirely: **Prometheus Agent mode** (no local TSDB/query/
  alerting, just scrape + remote_write elsewhere) - not applicable to us
  since we want local alerting/dashboards and have nowhere else to
  remote_write to; mentioned here only for completeness.

## 3. Alertmanager -> Discord

Per search results: **native `discord_configs` receiver support landed in
Alertmanager ~v0.25+**, meaning no separate proxy/adapter container
(`alertmanager-discord`, etc.) should be needed anymore - just set
`webhook_url` (or `webhook_url_file` from a k8s Secret / sops-managed
value, consistent with how we already handle the Longhorn webhook secret)
under a `discord_configs` receiver in Alertmanager's config, which in the
Helm chart is `alertmanager.config`.

Things called out worth remembering:
- Discord's message length limit (2000 chars) means a big alert storm can
  hit HTTP 400s without a custom `message`/`title` template that keeps
  output compact - worth setting a template rather than relying on
  Alertmanager's default formatting.
- Discord webhook rate limit is ~30 req/60s - keep `group_interval`
  reasonably high (5m+) so a multi-alert storm batches into fewer messages
  instead of hitting that limit.
- **Verify the `discord_configs` field name/shape and the minimum
  Alertmanager version directly against the Alertmanager docs/CHANGELOG
  before relying on it** - this came from a search summary, not a doc
  fetch, and the chart's bundled Alertmanager version needs to be new
  enough.

## 4. Alternative: VictoriaMetrics k8s stack

`victoria-metrics-k8s-stack` (vmagent + vmsingle/vmcluster + vmalert,
compatible with existing `ServiceMonitor`/`PodMonitor` CRDs) is the
commonly cited lower-resource alternative:
- Search-summarized comparisons put VictoriaMetrics at roughly 4-10x lower
  RAM and meaningfully lower CPU than Prometheus at the same series count,
  plus much better on-disk compression - but the specific numbers quoted
  (e.g. "500k series: 8-12GB Prometheus vs 1-2GB VM") are for cluster
  scales way bigger than our 3 nodes, so they're not directly informative
  for us - our real series count will be far lower and both stacks would
  likely be "small" in absolute terms.
- It's a drop-in for existing Prometheus-ecosystem CRDs/dashboards (mostly),
  so switching later isn't a total rewrite if kube-prometheus-stack turns
  out too heavy in practice.
- Downside: smaller ecosystem/community than Prometheus/Grafana for
  ready-made dashboards and docs; slightly different mental model
  (`vmalert` evaluates rules against the TSDB via HTTP, decoupled from
  scraping).
- One source noted VictoriaMetrics tolerates NFS-backed storage better
  than Prometheus's TSDB (smoother sequential writes vs. Prometheus's
  mmap+locking-sensitive design) - relevant to the storage-tier question
  below, but this is exactly the kind of specific technical claim that
  needs verifying against VictoriaMetrics' own storage docs before being
  trusted, since our 3-tier storage design leans on TSDB storage location
  mattering.

**Recommendation stands**: start with kube-prometheus-stack given our small
scale and the Longhorn/ecosystem integration advantage; revisit
VictoriaMetrics only if a real trial shows resource pressure.

## 5. What alerts actually matter here

- **etcd health/quorum** - since all 3 nodes run embedded etcd (per our HA
  design), losing quorum is the worst-case failure mode this whole
  monitoring effort should prioritize catching early. Needs `kubeEtcd`
  pointed at the k3s embedded etcd metrics endpoint (see certs section) -
  don't skip this the way generic "disable kubeEtcd on k3s" advice
  suggests, since we specifically enabled embedded HA etcd.
- **Node NotReady** - standard, cheap, should just work via kube-state-metrics.
- **Certificate expiry** (k3s auto-rotates most certs on service restart
  within ~120 days of a 365-day validity per search results, but the root
  CAs are ~10yr and don't auto-renew) - three possible approaches surfaced:
  1. k3s's own `supervisor-metrics`/`etcd-expose-metrics: true` exposing a
     `k3s_certificate_expiration_seconds` metric directly (least extra
     infra, easiest fit for us if the metric name/config option is real -
     **verify against k3s docs**, this is very likely to be at least
     approximately right but exact metric/flag names are unverified).
  2. A separate `x509-certificate-exporter` DaemonSet reading cert files
     directly off `/var/lib/rancher/k3s/server/tls/` (works regardless of
     whether k3s exposes its own metric, more moving parts).
  3. Generic `apiserver_client_certificate_expiration_seconds` from the
     apiserver itself.
  Option 1 is the natural first thing to try given we're already on k3s
  and it's the least additional infrastructure.
- **Longhorn volume degraded/faulted** - Longhorn reportedly ships its own
  `ServiceMonitor` toggle (`metrics.serviceMonitor.enabled: true` in its
  Helm values) and exposes a `longhorn_volume_robustness` metric (Healthy/
  Degraded/Faulted) plus per-node storage usage. **This would
  meaningfully overlap/duplicate our custom Longhorn disk-growth Discord
  script** in intent (both are "tell me when Longhorn storage is in
  trouble") - worth deciding whether to keep our hand-rolled growpart+alert
  script (it also *does* auto-growing, which Prometheus/Alertmanager can't)
  and layer Prometheus-based degraded-replica/robustness alerts on top as
  a complementary signal, rather than trying to replace one with the other.
- **Node resource pressure** (CPU/mem/disk) - standard kube-state-metrics +
  node-exporter territory, comes near-free once the stack exists.
- **Proxmox host-level monitoring** - explicitly out of k8s-cluster scope
  (hypervisor host health, not something running inside the cluster) -
  separate concern, likely its own future TODO (Proxmox has native metrics
  export or community exporters; not researched here).

## 6. Where does Prometheus's TSDB live?

Given our 3-tier storage design (`README.md` "Storage design" section):
boot disk / Longhorn fast-local-replicated / TrueNAS-NFS-bulk.

Search results were unambiguous and specific about **NFS being
discouraged for Prometheus's TSDB** - citing file-locking behavior
(`flock`/`fcntl` over NFS being unreliable, especially NFSv3's external
lock manager), `mmap`-heavy chunk access performing poorly over a network
filesystem, and real documented failure modes (stale locks after a
crash/reschedule, potential dual-writer corruption if a lock is silently
lost). This lines up with general Prometheus operational knowledge
(Prometheus's own docs are known to recommend local storage for the TSDB)
even though the specific quoted error strings above weren't independently
verified here.

**Conclusion for our design: TSDB belongs on tier 2 (Longhorn/fast local),
not tier 3 (TrueNAS NFS).** This is exactly what tier 2 is for (small,
latency-sensitive, wants replication) - a Prometheus PVC on Longhorn is a
very natural fit, arguably more central to "why tier 2 exists" than the
Jellyfin-config example already in the README. Losing metrics history on a
node failure isn't precious data - Longhorn's 2-replica failover is enough
here, no need to also involve TrueNAS/NFS for this.

## 7. NixOS-level vs. in-cluster (Helm)

Mostly this should be in-cluster/Helm-based, matching how Longhorn and
democratic-csi are already handled in this repo - no reason for Prometheus/
Alertmanager/Grafana themselves to be NixOS services.

One piece that came up as a genuine hybrid option: **run `node-exporter` as
a native NixOS systemd service (`services.prometheus.exporters.node`)
instead of the chart's node-exporter DaemonSet**, then point Prometheus at
it via `additionalScrapeConfigs`/a static target list (disabling the
chart's own `nodeExporter`/`prometheus-node-exporter` subchart to avoid
running it twice). The argument for this: it keeps reporting host-level
metrics (disk, CPU, memory, systemd unit state) even if k3s/containerd
itself is the thing that's broken - which is exactly the failure mode this
whole effort is trying to catch early (a node going bad without the other
2 noticing). Given we already manage these nodes declaratively via NixOS
(`hosts/common/default.nix`), this fits naturally as another
`nixos-modules/*.nix` module, similar in spirit to `k3s.nix`.

This is worth doing over the DaemonSet approach for our setup specifically
- flag it as a real recommendation, not just a "some people do this"
mention, but still confirm the NixOS option name/`enabledCollectors` list
against the actual NixOS module docs (`nixos-option` / search.nixos.org)
before implementing, since this note's specifics came from a search
summary.

## Rough implementation shape (for later)

1. New `nixos-modules/node-exporter.nix` (NixOS-native, all 3 nodes) +
   firewall rule for its port, mirroring the hybrid approach above.
2. New `cluster-bootstrap/kube-prometheus-stack-values.yaml`, alongside the
   existing `democratic-csi-truenas-values.yaml` (Longhorn's own Helm
   values now live in `homelab-apps`'s `infra/longhorn`, not here - this
   stack would likely belong there too, as `infra/kube-prometheus-stack`,
   rather than in this repo's `cluster-bootstrap/`), with: control-plane
   scrape targets trimmed per k3s reality (etcd
   pointed at the 3 node IPs on port 2381, others off), `defaultRules`
   trimmed, scrape/eval interval + retention tuned down, explicit
   resources on every component, node-exporter subchart disabled (using
   the NixOS one instead), Alertmanager configured with `discord_configs`
   pointed at a `discord-webhook-url`-style sops secret (can likely reuse
   the same Discord webhook already set up for Longhorn, or use a
   dedicated channel/webhook - decide later), Prometheus's PVC on the
   Longhorn storage class (tier 2).
3. `PrometheusRule`s for: etcd health/quorum, node NotReady, k3s cert
   expiry, Longhorn volume robustness/degraded - decide whether any of
   these should be *removed* from `defaultRules` first to avoid duplicate
   noise.
4. README updates: new "Monitoring & alerting" section (parallel to the
   existing storage/self-update sections), plus a decision on whether the
   Longhorn disk-growth Discord script stays as-is (recommendation: yes,
   keep it - it does an auto-grow action Prometheus/Alertmanager can't,
   just let the new stack add complementary read-only alerting).

## Open questions to resolve before implementing

- Reuse the existing Longhorn Discord webhook/channel for cluster alerts
  too, or set up a separate one/channel so "storage growth notice" and
  "something's actually wrong" don't blend together?
- Any interest in long-term metrics retention/history beyond a few days,
  or is "recent state + alerting" the actual goal? (Affects retention
  sizing and whether VictoriaMetrics' compression advantage ever matters.)
- Proxmox host-level monitoring (separate from this k8s-cluster-scoped
  note) - worth its own future TODO note.
