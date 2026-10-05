# homelab-k8s
Declarative kubernetes configuration running k3s on NixOS; made with the help of an LLM

> [!WARNING]
> This was repo's contents were created by an LLM and have not yet been validated. 

Declarative configuration and tooling for a 3-node k3s Kubernetes cluster
running on NixOS VMs on Proxmox. **App deployment (GitOps, including the
in-cluster Longhorn Helm install and the external ingress/load-balancing
stack) lives in a separate repo**
([`homelab-apps`](https://github.com/jhollowe-infra/homelab-apps)) — this
repo only covers: the Proxmox bootstrap ISO, the VMs themselves, the
NixOS/k3s node configuration (including the kube-vip API-server VIP), the
disk Longhorn uses (provisioning, auto-grow, usage alerting — but not
Longhorn itself), and the TrueNAS CSI storage backend the cluster depends
on.

## Topology

- 3 physical Proxmox hosts (in one Proxmox cluster, shared storage), 1 k8s
  VM per host.
- All 3 nodes run **both** control-plane and worker roles (k3s embedded
  etcd HA across all 3).
- Every node has its CPU's integrated GPU (Intel QuickSync-capable, e.g.
  UHD 630 on Comet Lake) passed through for hardware video transcode via
  VA-API.
- One node (initially) also has a discrete NVIDIA GPU (a Quadro P620)
  passed through, for workloads that specifically need CUDA/NVENC.
- Apps request `homelab/quicksync: "true"` and/or `homelab/gpu-nvidia:
  "true"` node labels (via `nodeSelector`, in the app repo) independently —
  a pod can want either, both, or neither.

## Storage design

Three tiers, matched to what actually needs to be fast vs. cheap vs. bulk:

1. **Boot disk** — minimal, holds the OS + k3s only (`hosts/common/disko.nix`).
2. **Fast local, replicated** — a 2nd virtual disk per VM, on Proxmox local
   storage, given to **Longhorn** (installed via Flux from `homelab-apps`'s
   `infra/longhorn`, not from this repo). Longhorn replicates each volume
   across 2 of the 3 nodes, so a PVC survives one physical host going down
   and the pod reschedules onto a node that already has the data. Use this
   for small/latency-sensitive data — e.g. a media server's database and
   config. This disk starts small and grows on demand — see
   [Longhorn disk growth & alerting](#longhorn-disk-growth--alerting).
3. **Bulk, network** — your TrueNAS NAS, exposed dynamically via
   **democratic-csi** (NFS). Use this for large, less latency-sensitive
   data — e.g. the media files themselves.

A media server (e.g. Jellyfin) app or notes app (e.g. Nextcloud) would mount tier 2 for its database/config PVC and tier 3 for the media library/content PVC.

## External ingress & load balancing

Two separate VIPs, two separate mechanisms, don't conflate them:

- **k3s API server VIP** (`10.10.100.10`,
  `k8s-api-vip.kube-nodes.johnhollowell.internal`) — **kube-vip**, static
  pod, managed by *this* repo (`nixos-modules/kube-vip.nix`). Exists so the
  3 control-plane nodes have a stable address with failover. See
  [One-time setup](#one-time-setup).
- **External app traffic VIP(s)** (currently `10.10.100.5`) — **MetalLB**
  (L2 mode) handing a `type: LoadBalancer` Service to a separately
  Helm-managed **Traefik** (not k3s's bundled Traefik, which
  `nixos-modules/k3s.nix` disables via `--disable=traefik
  --disable=servicelb` specifically so it doesn't race MetalLB for the same
  Services), fronted by **cert-manager** (HTTP-01 challenges against a
  `letsencrypt-prod` `ClusterIssuer`) for TLS. All three are installed and
  managed entirely via Flux from `homelab-apps`'s `infra/` (`infra/metallb`
  + `infra/metallb-config`, `infra/traefik`, `infra/cert-manager` +
  `infra/cert-manager-config`) — **not** from this repo. Individual apps'
  `Ingress`/`IngressRoute` objects also live in `homelab-apps`.
- OPNsense's job for the MetalLB/Traefik VIP is just a static NAT
  port-forward (WAN -> the VIP); it does not run its own LB/HAProxy for
  this by design.
- This repo's only touchpoint with that stack is the `--disable=traefik
  --disable=servicelb` k3s flags above, which must stay set as a
  precondition for MetalLB to work.

## NixOS bootstrap ISO

Terraform uploads the NixOS live ISO to each Proxmox node's ISO datastore
using the Proxmox API, then creates blank-disk VMs that boot from it. The ISO
uses DHCP and runs the QEMU guest agent, so Terraform reports each live
installer's address for `nixos-anywhere`. The installed host configuration
then switches to the node's static address.

## Layout

```
flake.nix              devShell with every tool pinned (tofu, colmena,
                        nixos-anywhere, sops, age, kubectl, helm) — the
                        only prerequisite on any machine is Nix itself.
hosts/
  common/               config shared by all 3 nodes (disks, k3s, quicksync)
  k8s-node-{1,2,3}/      per-node config (hostname, cluster-init, GPU imports)
nixos-modules/
  k3s.nix                k3s server role + sops-nix token + node labels
  kube-vip.nix           API server VIP via kube-vip static pods
  gpu-intel-quicksync.nix  VA-API config for the iGPU (imported by all nodes)
  gpu-nvidia.nix           NVIDIA driver/containerd config (opt-in per node)
  auto-upgrade.nix         pull-based self-update, health-checked w/ rollback
  longhorn-disk-grow.nix   Longhorn disk auto-grow (partition + filesystem)
  longhorn-disk-alert.nix  Discord alert when Longhorn disk usage crosses 80%
image/
  bootstrap-iso.nix       NixOS live ISO used to create and bootstrap VMs
  build-base-template.sh  legacy template builder; not used by Terraform
terraform/
  modules/vm/             one k8s node VM: blank disks, ISO boot, hostpci
  *.tf, terraform.tfvars.example
cluster-bootstrap/
  democratic-csi-truenas-values.yaml Helm values for the TrueNAS NFS tier
                                      (Longhorn's Helm values live in
                                      homelab-apps's infra/longhorn)
secrets/
  *.sops.yaml.example     templates — copy, fill in, then `sops -e -i`
scripts/
  bootstrap-nodes.sh       first-time: nixos-anywhere on all 3 nodes
  setup-cluster.sh         fetch kubeconfig and install democratic-csi
  add-node.sh              add a node after initial bootstrap
```

## One-time setup

1. Enter the dev shell (only prerequisite: [Nix](https://nixos.org/download) itself):
   ```
   nix develop
   ```

2. Generate an age key for secrets encryption, put its public key in
   `.sops.yaml`, and back up the private key somewhere outside git:
   ```
   age-keygen -o age-key.txt
   ```
  Keep `age-key.txt` in the repository root while bootstrapping. The
  bootstrap script verifies it can decrypt the secrets file and securely
  stages it on each node at `/var/lib/sops-nix/key.txt` before the first
  activation. This key can decrypt every secret encrypted to its public key;
  protect it accordingly and never commit it.

3. Fill in the secrets templates (k3s join token, Discord webhook URL for
   disk-usage alerts, TrueNAS driver config) and encrypt them — see
   `secrets/*.example` for exact steps.

4. Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars`
   and fill in your Proxmox endpoint/credentials and each node's PCI IDs
   (`lspci -nn` on each physical host — the iGPU and, on the node with the
   P620, its PCI address too).

5. Build the NixOS bootstrap ISO before creating the VMs:
   ```
  nix build path:.#bootstrap-iso
   ```
  This creates a `result` symlink to a hash-prefixed Nix store path ending
  in `nixos-bootstrap.iso`. Terraform uploads it to the configured
  `iso_datastore` (default `local`) on each target node. The datastore must
  allow ISO images. The live ISO gets its address via DHCP
  and reports it through QEMU guest agent. Its temporary SSH login is
  `root` / `nixos`; keep the bootstrap network isolated and do not reuse this
  password.

6. Create the VMs:
   ```
   tofu -chdir=terraform init
   tofu -chdir=terraform apply
   ```

Add a LAN DNS A record for `k8s-api-vip.kube-nodes.johnhollowell.internal`
pointing to `10.10.100.10` before installing the nodes. Reserve that address
outside the DHCP pool.

7. Install NixOS on all 3:
   ```
  ./scripts/bootstrap-nodes.sh
   ```
  The script uses each VM's DHCP address for the installer and provisions
  the local age key so sops-nix can create the k3s token before k3s starts.
  Do not rerun this destructive install script on nodes that already contain
  data.

If a node is already installed but is missing `/var/lib/sops-nix/key.txt`,
copy the private key to that node over SSH and retry the deployment. Run this
from the repository root, changing `node` to each affected hostname:

```
node=hl01-kube01
ssh "root@$node.kube-nodes.johnhollowell.internal" 'install -d -m 0755 /var/lib/sops-nix && umask 077 && cat > /var/lib/sops-nix/key.txt' < age-key.txt
colmena apply --on "$node"
```

8. Fetch the kubeconfig and install democratic-csi:
   ```
   ./scripts/setup-cluster.sh
   ```
  This writes `kubeconfig` in the repository root and installs or upgrades
  democratic-csi. It requires the encrypted
  `secrets/truenas-driver-config.sops.yaml` file.

Your app-deployment repo ([`homelab-apps`](https://github.com/jhollowe-infra/homelab-apps),
Flux-based) points at this cluster's kubeconfig from here on; it also
installs Longhorn (`infra/longhorn`), the cluster's fast-local storage
layer, which this repo only provisions the underlying disk for.

## Day-2 operations

- **Add a node**: `./scripts/add-node.sh <hostname>` (after adding its
  `hosts/<name>/`, `flake.nix`, and `terraform.tfvars` entries).
- **Push a config update to all nodes immediately**: `colmena apply`.
- **Push a config update to one node immediately**: `colmena apply --on <hostname>`.
- **Nodes also self-update on a schedule** — see below.
- **Keep tool versions current**: `.github/workflows/update-flake-lock.yml`
  opens a weekly PR updating `flake.lock` (nixpkgs, disko, colmena,
  sops-nix, nixos-anywhere); Dependabot (`.github/dependabot.yml`) opens
  PRs for the `bpg/proxmox` Terraform provider and GitHub Actions versions.

## Self-updating nodes (pull-based)

Each node independently pulls this repo's flake and applies it on its own
schedule, via `nixos-modules/auto-upgrade.nix` — you don't have to run
`colmena apply` from a central machine for routine config changes. This
only covers the NixOS side; Terraform/Proxmox-level changes (new node,
resized disk, changed PCI passthrough) still require running `tofu apply`
from a machine with your Proxmox credentials, since the VMs themselves
can't create/resize themselves.

**Before this works**, edit `flakeRef` in `nixos-modules/auto-upgrade.nix`
to point at your actual GitHub repo (`github:<you>/homelab-k8s`) — it's a
placeholder until then.

**Safety, since all 3 nodes run etcd** (a bad rollout hitting all 3 at once
could break quorum together):

- Each node's upgrade window is staggered (`homelabAutoUpgrade.dates` in
  each `hosts/<name>/default.nix`: node-1 at 03:00, node-2 at 05:00,
  node-3 at 07:00), so a human has a window to notice a problem before it
  reaches the next node.
- Before upgrading, a node checks the cluster is currently healthy
  (apiserver `/readyz`, all nodes `Ready`) and **skips this cycle** if not
  — it won't pile a 2nd change onto a cluster that's still recovering from
  the 1st.
- After upgrading, it waits (up to 3 minutes) for itself to rejoin as
  `Ready`. If it doesn't, it **automatically rolls back** to the previous
  NixOS generation (`nixos-rebuild switch --rollback` — instant, the old
  generation is still on disk) and restarts k3s.
- `boot.loader.grub.configurationLimit` and `nix.gc` (in
  `hosts/common/default.nix`) keep enough old generations around for that
  rollback to actually have something to fall back to.

Check on it with:
```
systemctl status homelab-auto-upgrade.timer   # next scheduled run
journalctl -u homelab-auto-upgrade            # what happened last run (incl. any rollback)
```

This does **not** replace watching your nodes — it's a blast-radius limiter,
not a substitute for noticing a node stuck rolling back every night. If you
want alerting on that, `journalctl -u homelab-auto-upgrade` failing is the
thing to hook a monitoring check to (out of scope for this repo).

## Longhorn disk growth & alerting

This covers only the underlying disk this repo provisions for Longhorn;
Longhorn itself (the Helm install, StorageClass, replica count, etc.) is
managed by `homelab-apps`'s `infra/longhorn`.

Each node's Longhorn disk (`terraform`'s `longhorn_disk_gb`, default **4GB**)
is deliberately small at first, not sized for eventual usage — growing it
later is a one-line change, so there's little reason to overallocate up
front. Two independent systemd timers run every 15 minutes on each node:

- `nixos-modules/longhorn-disk-grow.nix` (`homelab-longhorn-disk-grow`):
  checks whether the underlying virtual disk has been enlarged since the
  partition was created, and if so grows the partition + ext4 filesystem
  online (`growpart` + `resize2fs`) — no reboot, no manual in-VM step.
- `nixos-modules/longhorn-disk-alert.nix` (`homelab-longhorn-disk-alert`):
  checks `/var/lib/longhorn` usage. Once it crosses **80%**, posts to a
  Discord webhook (deduped — once on first crossing, then at most once a
  day while still over threshold, until it drops back below).

**To grow a node's disk** after getting the alert: bump that node's
`longhorn_disk_gb` in `terraform/terraform.tfvars`, then `tofu -chdir=terraform
apply`. The node picks up the larger virtual disk and grows into it on its
next timer run (within 15 minutes) — that's the entire manual step.
Shrinking is not supported (Proxmox/ext4 can't safely shrink this way), so
it's fine to be conservative rather than guess high.

Requires the `discord-webhook-url` secret (Discord channel → Integrations →
Webhooks) filled in during [One-time setup](#one-time-setup) step 3.

## Adding a GPU to another node

1. On that physical Proxmox host, find the GPU's PCI ID: `lspci -nn`.
2. Set `nvidia_pci_id` for that node in `terraform/terraform.tfvars`.
3. In `hosts/<name>/default.nix`, uncomment/add
   `imports = [ ../../nixos-modules/gpu-nvidia.nix ];`.
4. `tofu -chdir=terraform apply`, then `colmena apply --on <hostname>`.
5. Apps target it via `nodeSelector: { homelab/gpu-nvidia: "true" }` in the
   app repo.
