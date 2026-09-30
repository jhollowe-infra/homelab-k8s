# TODO: Ingress & load balancing (internet -> OPNsense -> cluster)

Currently there's no path from the internet to services on the cluster at
all: `nixos-modules/k3s.nix` disables both k3s's built-in `servicelb`
(klipper-lb) and bundled `traefik` (`--disable=servicelb --disable=traefik`),
anticipating a different LB/ingress choice that was never made. This note is
research/planning for that choice, to implement later, once there are
actual services (from the future app-deployment repo) worth exposing.

Explicit design constraint from the user: **the LB/VIP should be managed by
the cluster itself, not by OPNsense** (i.e. no HAProxy/relayd on the
router) — OPNsense's job is just to route/forward to a cluster-managed VIP.

> NOTE on sourcing: this note mixes (a) facts fetched directly from a
> primary source in 2026-09 research (flagged inline as "fetched"), (b)
> facts from web-search-engine summaries (not independently fetched —
> treat as plausible, not confirmed), and (c) general background
> knowledge. Exact CRD names, Helm value keys, OPNsense plugin option
> names, and k3s flag names should be checked against real docs/`helm
> show values`/a test deploy before implementing, not trusted blind. Where
> sources disagreed or a claim is qualitative impression rather than
> measured data, that's called out explicitly.

## Recommendation (tentative)

**MetalLB in L2 mode, fronting a separately-Helm-managed Traefik (not
k3s's bundled Traefik, and not ingress-nginx), with cert-manager using
DNS-01 challenges.** Reasoning:

- L2 mode needs no dynamic routing setup on OPNsense — just a NAT
  port-forward to whatever VIP MetalLB assigns. That matches this
  homelab's actual network (one router, no existing BGP) far better than
  BGP mode, which is a real and documented homelab pattern (OPNsense has
  an FRR plugin for it — see below) but is more infrastructure than a
  single-router homelab needs right now. Revisit BGP mode only if the
  single-node-bottleneck property of L2 mode (see below) actually becomes
  a problem in practice.
- Traefik over ingress-nginx: **`kubernetes/ingress-nginx` (the SIG
  Network-governed project) was formally announced retired/end-of-life by
  Kubernetes SIG Network in November 2025** (fetched directly from a
  kubernetes.io blog post — high confidence on the announcement itself;
  the exact archival date of ~March 2026 mentioned in some summaries was
  not independently confirmed, treat that specific date as unverified).
  Cited reasons: chronic maintainer shortage and a critical (CVSS 9.8)
  RCE vulnerability found in early 2025. This is a different project from
  the still-maintained `nginxinc/kubernetes-ingress` (F5/NGINX Inc.), but
  the point is: don't default to the community ingress-nginx chart for a
  new setup today. A separately-Helm-managed Traefik chart (decoupled
  from whatever Traefik version happens to ship bundled with a given k3s
  release) avoids that dead project while staying closer to what k3s
  already assumes.
- MetalLB over kube-vip for the *Service LoadBalancer* job specifically:
  sources consistently describe MetalLB as the more mature/CRD-driven/
  feature-rich option for that job (BGP mode, BFD, multi-pool, status
  CRDs); kube-vip's service mode is described as comparatively simpler.
  kube-vip's actual unique value is a *different* job — see next section.

Treat this as a starting hypothesis, not a final decision — validate with
a real test deploy before trusting exact CRD/flag names below.

## 1. LoadBalancer/VIP options: MetalLB vs. kube-vip

**MetalLB** (fetched directly from its GitHub releases page: core app
**v0.16.0**, Helm chart **metallb-chart-0.16.1**, both 2026-05 — the one
version data point in this note pulled from a primary source rather than
a search summary):

- Config is entirely CRD-based since v0.13+: `IPAddressPool`,
  `L2Advertisement`, `BGPPeer`, `BGPAdvertisement`, plus newer
  `ServiceL2Status`/`ServiceBGPStatus` observability CRDs.
- **L2 mode**: one elected "leader" speaker pod answers ARP/NDP for a
  given VIP; all inbound traffic for that IP funnels through that one
  node before kube-proxy/CNI spreads it to pods anywhere in the cluster.
  Failover is gratuitous-ARP-based via memberlist gossip. Ceiling: that
  one node's NIC bandwidth — a real limitation, but almost certainly a
  non-issue at homelab traffic volumes.
- **BGP mode**: a speaker on every node peers with the router; the router
  ECMP-hashes across all of them for true multi-node distribution. Needs
  a BGP-capable router (OPNsense can do this via its `os-frr` plugin —
  see OPNsense section) and has a known caveat: ECMP rehashing on
  topology change can reset in-flight TCP connections, usually mitigated
  with `externalTrafficPolicy: Local`.
- **v0.16 uses `frr-k8s`** (a Kubernetes-native FRRouting wrapper) as the
  default BGP backend now, replacing the older direct FRR-mode — this is
  a recent architecture change, worth re-checking current docs since this
  note's information may age quickly here.
- **k3s conflict, confirmed and consistent across sources**: k3s's
  built-in ServiceLB (klipper-lb) also watches `type: LoadBalancer`
  Services and will race with MetalLB (or kube-vip's service mode) for
  the same Service, causing stuck/`Pending` states — this is exactly why
  `k3s.nix` already disables it (`--disable=servicelb`); that decision
  does not need to change, it's a *precondition* for MetalLB, not a
  mistake to revisit.
- Resource footprint: search-summarized (not an official sizing doc) puts
  controller + speaker each in the tens-of-MB range, base cost tiny,
  scaling a little per LoadBalancer Service / BGP peer. Treat exact
  numbers as illustrative, not authoritative — but directionally, this is
  very lightweight for a 3-node homelab regardless.
- Install: Helm repo `https://metallb.github.io/metallb`, needs the
  target namespace labeled for privileged Pod Security Admission if PSA
  is enforced. `IPAddressPool`/`L2Advertisement` are separate CRD
  manifests applied after the Helm install, not Helm values.

**kube-vip**:

- Two genuinely different jobs, don't conflate them: (a) **control-plane
  API server VIP** — runs as a *static pod*, which is what lets it exist
  *before* a working local API server — solving a bootstrap problem MetalLB
  structurally can't solve (MetalLB's controller/speaker are themselves
  scheduled *by* the API server, so they can't provide HA *for* it); (b)
  a Service `type: LoadBalancer` implementation (ARP or BGP), functionally
  overlapping with MetalLB's job.
- **Correction from earlier research pass**: the static-pod path is
  `/var/lib/rancher/k3s/agent/pod-manifests/` (watched directly by
  kubelet, on any node, independent of the API server) — **not**
  `/var/lib/rancher/k3s/server/manifests/`, which is a different,
  server-only mechanism (k3s's own "Deploy Controller" applying arbitrary
  resources *through* the API server, used for things like the bundled
  Traefik/CoreDNS and tracked as `AddOn` CRs) and requires a working API
  server, defeating the point for kube-vip's control-plane use case. Easy
  to mix up since both are called "manifests" — verify against
  https://kube-vip.io/docs/installation/k3s/ before implementing.
- Common homelab patterns, per search results (qualitative impression
  from guides, no usage-share data found, so treat "most common" claims
  as anecdotal): (A) kube-vip for control-plane VIP *only* + MetalLB for
  service LB — described as the most frequently recommended combo; (B)
  kube-vip doing both jobs, for a simpler single-tool setup; (C)
  MetalLB-only, when there's no multi-control-plane HA need.
- **This matters for us specifically**: the 3-node k3s cluster has
  embedded HA etcd and now uses kube-vip for its API-server VIP at
  `10.10.100.10`. This is separate from the internet-ingress work below;
  kube-vip handles API access/failover, while the recommended MetalLB
  installation will handle external Service VIPs.

### 1a. Implemented: kube-vip control-plane VIP for the API server

Decided so far: the VIP gets the hostname
**`k8s-api-vip.kube-nodes.johnhollowell.internal`** (matching the
`kube-nodes.johnhollowell.internal` node-naming scheme) and address
**`10.10.100.10`**. Reserve the address outside DHCP's range and any
MetalLB pool; add a LAN DNS A record for the hostname.

Implemented as a **separate NixOS module**
(`nixos-modules/kube-vip.nix`) imported by `hosts/common/default.nix` and
enabled on all 3 server nodes:

1. The module materializes a kube-vip static pod manifest at
  `/var/lib/rancher/k3s/agent/pod-manifests/kube-vip.yaml` in ARP/L2 mode.
  A one-shot systemd unit discovers the LAN interface from the node's
  default-gateway route before k3s starts, avoiding a hard-coded NIC name.
  The manifest uses `cp_enable: true` and `vip_leaderelection: true` and
  mounts the host's `/etc/rancher/k3s/k3s.yaml` at
  `/etc/kubernetes/admin.conf`. The image is pinned to kube-vip v1.2.4.
2. `nixos-modules/k3s.nix` provides `homelabK3s.tlsSan`, wired to repeated
  `--tls-san=<value>` flags. The kube-vip module sets the VIP hostname and
  `10.10.100.10` on all server nodes so API TLS verification succeeds.
3. `serverAddr` in `hosts/hl01-kube02/default.nix` and
   `hosts/hl01-kube03/default.nix` from
  `https://hl01-kube01.kube-nodes.johnhollowell.internal:6443` to
  `https://k8s-api-vip.kube-nodes.johnhollowell.internal:6443`. Both
  joining nodes have k3s enabled so they can participate in failover.
   Bootstrapping order note: node-1 (`clusterInit = true`) still comes up
   first and is briefly the sole holder of the VIP; nodes 2/3 join via the
   VIP once their own kube-vip static pods are up too.
4. `scripts/setup-cluster.sh` rewrites the fetched kubeconfig to use the
  VIP hostname. Colmena's `deployment.targetHost` remains per-node because
  it is the SSH destination for configuration deployment.
5. README setup instructions require the LAN DNS A record to point the VIP
  hostname to `10.10.100.10`.

Tradeoffs: one more static pod per server node to keep healthy; ARP-mode
failover has a brief (seconds) gap during leader transition, same class of
limitation as MetalLB's L2 mode above — acceptable for a homelab. Coexists
fine with MetalLB (different job), just needs a non-overlapping IP.
- If running both: use non-overlapping IP pools/ranges between kube-vip's
  VIP(s) and MetalLB's pool.

## 2. Ingress controller choice

- k3s ships Traefik by default (currently disabled here). Common reasons
  homelabbers replace it: most public tutorials/charts assume
  nginx-style annotations rather than Traefik's CRD model
  (`IngressRoute`/`Middleware`), so copy-paste guides are friction-free
  with ingress-nginx; Traefik's version is coupled to k3s's release
  cadence unless managed separately, so a k3s upgrade can silently bump
  Traefik (e.g. v2->v3) and break existing routing config.
- **ingress-nginx (`kubernetes/ingress-nginx`) was announced retired by
  Kubernetes SIG Network in November 2025** — confirmed via direct fetch
  of a kubernetes.io blog post, so higher confidence than most of this
  note. Do not default to it for a new setup. (Distinct from the
  still-maintained `nginxinc/kubernetes-ingress` — different codebase,
  easy to confuse by name.) The community's stated direction is Gateway
  API and/or other maintained controllers.
- Given that, two reasonable options remain: (a) **Traefik via its own
  Helm chart** (not k3s-bundled) — closest to what k3s already assumes,
  decoupled version from k3s's release cadence, avoids relearning a new
  ecosystem; (b) **Gateway API** (the newer, more expressive successor to
  Ingress) via a maintained implementation (e.g. Traefik or others also
  support Gateway API) — more future-proof but newer/less homelab-tutorial
  coverage as of this research. Recommendation leans (a) for now given
  this is a small homelab and (a) is the lower-friction path from where
  this repo already is; (b) is worth a look if starting fresh feels more
  appealing by the time this gets implemented.
- Standard pattern either way: the ingress controller's own Service is
  `type: LoadBalancer`, and MetalLB assigns *that* Service the VIP — i.e.
  MetalLB doesn't hand out per-app VIPs, it hands out (usually) one VIP
  to the ingress controller, which then does host/path-based routing to
  individual app Services inside the cluster. Only workloads that
  specifically need their own dedicated external IP (not HTTP-routable
  through the ingress) would get their own separate MetalLB-assigned
  LoadBalancer Service.

## 3. OPNsense-side integration

- With L2-mode MetalLB (the recommended starting point): OPNsense's job
  is just a **static NAT port-forward** (e.g. WAN:443 -> `<VIP>`:443,
  WAN:80 -> `<VIP>`:80 if needed for HTTP-01/redirects) to whatever IP
  MetalLB's `IPAddressPool` hands the ingress controller's Service. No
  dynamic routing needed — this is the whole point of choosing L2 mode
  for a single-router homelab.
- **BGP peering is real but a step up**: OPNsense has an `os-frr` plugin
  (System -> Firmware -> Plugins) providing FRRouting-based BGP,
  configurable through the GUI (Routing -> BGP: neighbors, prefix-lists,
  route-maps, "Maximum Paths" for ECMP). Search results describe OPNsense
  <-> MetalLB BGP peering as something homelabbers actually document and
  do, not purely theoretical — but it's presented as the step you take
  once you've outgrown L2 mode's single-node bottleneck, not the default
  starting point. No hard adoption data found either way; treat "how
  common" as qualitative impression, not measured. Not needed for this
  homelab's current scale — noted for later if L2 mode's ceiling ever
  actually matters.
- **OPNsense's CARP is a different, unrelated concept — don't confuse the
  two.** CARP (Common Address Redundancy Protocol, IP protocol 112) is
  OPNsense's *own* HA mechanism for **router/firewall failover** between
  two OPNsense boxes (active/passive), sharing a virtual IP/MAC, paired
  with pfsync (state table sync) and config sync. It solves "what if the
  router itself dies," not "what if a k8s node dies" — the latter is what
  MetalLB/kube-vip's VIPs are for. Both happen to use the term "VIP" and
  (in L2/CARP's ARP-based case) similar low-level mechanics, which is
  exactly why they're easy to conflate, but they operate at different
  layers for different failure modes. This homelab has one OPNsense
  router (no CARP pair), so this only matters as a terminology
  clarification, not something to configure.

## 4. TLS/certificates

- **cert-manager** is the standard k8s-native way to automate issuing/
  renewing TLS certs — a `ClusterIssuer`/`Issuer` referencing an ACME CA
  (Let's Encrypt), with the ingress controller terminating TLS using the
  resulting Secret. Keeping this section brief on purpose; a full
  cert-manager design (which issuer, wildcard vs. per-host certs, issuer
  scoping) can be its own later TODO once ingress itself exists.
- **HTTP-01** needs port 80 publicly reachable per hostname being
  validated, no wildcards. **DNS-01** validates via a TXT record through
  your DNS provider's API — no inbound port exposure at all, works behind
  NAT, and supports wildcard certs (also avoids leaking a full subdomain
  list via public Certificate Transparency logs, which HTTP-01-issued
  certs do). **DNS-01 is the right fit here** given this is a
  homelab behind NAT with no need to open port 80 just for ACME —
  consistent across sources, no disagreement found.
- Scope decision for later: TLS/cert-manager config plausibly belongs in
  *this* repo (cluster infra, same bucket as Longhorn/democratic-csi/the
  ingress controller itself) rather than the app-deployment repo, since
  the `ClusterIssuer` is cluster-wide infrastructure that individual apps
  just reference — but this can be revisited when it's actually
  implemented.

## 5. Interaction with existing `nixos-modules/k3s.nix` flags

- `--disable=servicelb` and `--disable=traefik` are **already correct**
  for this plan — no change needed there, they're preconditions for
  MetalLB + a separately-managed ingress controller, not something to
  revert. (`k3s.nix`'s existing comment about "you don't want fighting
  with your own ingress/storage choices" already anticipated this
  direction; it just wasn't acted on yet.)
- Ordering/bootstrapping: MetalLB and the ingress controller are both
  ordinary in-cluster Helm installs (like Longhorn/democratic-csi
  already are) — they go into `cluster-bootstrap/` alongside
  `longhorn-values.yaml`/`democratic-csi-truenas-values.yaml` and get
  installed via `helm install` *after* the cluster is already up, same
  pattern as the existing storage layer. No NixOS/`k3s.nix` changes are
  needed beyond what's already there. The one gotcha to verify at
  implementation time: MetalLB's CRDs need to exist before applying
  `IPAddressPool`/`L2Advertisement` manifests (standard "helm install
  chart, then apply CRD-backed config" ordering — not unique to this
  chart, but easy to hit if scripting an unattended bootstrap).

## Rough implementation shape (for later)

1. New `cluster-bootstrap/metallb-values.yaml` (Helm values) +
   `cluster-bootstrap/metallb-pool.yaml` (the `IPAddressPool`/
   `L2Advertisement` CRD manifests, applied after the Helm install) —
   pick an IP range on the LAN outside DHCP's range for the pool.
2. New `cluster-bootstrap/traefik-values.yaml` (or ingress controller of
   choice, per the decision in section 2) — its Service picks up a VIP
   from MetalLB's pool automatically once bound as `type: LoadBalancer`.
3. New `cluster-bootstrap/cert-manager-values.yaml` + a `ClusterIssuer`
   manifest using DNS-01 against whatever DNS provider hosts the domain
   (needs an API token — sops-nix secret, same pattern as the Discord
   webhook / TrueNAS driver config already in this repo).
4. OPNsense: one NAT port-forward rule, WAN:443 (and :80 if wanted) ->
   the ingress controller's MetalLB-assigned VIP.
5. README updates: a new "Ingress & load balancing" section (parallel to
   the existing storage/monitoring sections) once implemented.

## Open questions to resolve before implementing

- Traefik (separately managed) vs. Gateway API from the start — worth
  deciding based on how the future app-deployment repo will express
  routing, since that repo is where individual app `Ingress`/`HTTPRoute`
  objects will actually live.
- The kube-vip API-server VIP is configured at `10.10.100.10`; confirm
  that it is reserved outside DHCP's range and any future MetalLB pool.
- How is `*.kube-nodes.johnhollowell.internal` resolved today (for the
  existing node hostnames) — the VIP hostname needs the same treatment.
- Which DNS provider hosts the relevant domain, and does its API support
  cert-manager's DNS-01 webhook/solver out of the box, or need a
  community webhook solver?
- Single shared ingress VIP for everything, or does anything (e.g. a
  service needing a non-HTTP protocol) need its own dedicated
  MetalLB-assigned LoadBalancer IP instead of going through the ingress
  controller?
