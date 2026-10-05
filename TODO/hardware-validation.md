# TODO: Validate on real hardware

This repo has been developed/reviewed without a live 3-node cluster to test
against. Everything below is logic or config that only exercises real code
paths once it runs on the actual Proxmox hosts and VMs - flagging it here so
none of it gets silently assumed-working just because `nix flake check` /
`tofu validate` pass. Checklist form: check each off with the real result
(pass, or what broke) once tried, don't just delete the line.

## First bootstrap (`scripts/bootstrap-nodes.sh` and `scripts/setup-cluster.sh`)

- [ ] `tofu apply` actually creates all 3 VMs cleanly from the base template
      (`image/build-base-template.sh` output) with the right disks/NIC/CPU.
- [ ] `nixos-anywhere --flake ".#k8s-node-N"` succeeds against a freshly
      cloned VM for all 3 nodes, in order.
- [ ] `hosts/common/disko.nix` partitions both virtual disks as expected
      (ESP+root on `/dev/sda`, Longhorn on `/dev/sdb`) and boots afterward -
      never applied to a real disk yet.
- [ ] k3s actually forms a 3-node HA cluster: node-1 with `clusterInit =
      true` comes up, node-2/node-3 join via `serverAddr` and the sops-decrypted
      join token, `kubectl get nodes` shows all 3 `Ready`.
- [ ] `homelabNetwork` static addressing (`nixos-modules/network.nix`)
      actually matches interfaces via the `en*` glob on real hardware NICs
      (not just VM virtio) - confirm no double-match if a GPU or other
      passthrough device ever presents as a network-ish device.
- [ ] `scripts/setup-cluster.sh`'s kubeconfig extraction/IP substitution
      (`sed s/127.0.0.1/.../`) produces a kubeconfig that actually works from
      outside the node.

## GPU passthrough

- [ ] `docs/proxmox-host-setup.md` VFIO steps (IOMMU enable, module
      blacklist, `vfio-pci ids=...` binding) work end-to-end on the real
      Proxmox hosts - written from the PVE wiki, never executed here.
- [ ] Intel iGPU (`nixos-modules/gpu-intel-quicksync.nix`) passthrough
      actually exposes `/dev/dri/renderD128` in the VM, and VA-API hardware
      accel (e.g. via Jellyfin, `vainfo`) actually works on the Gen9.5
      UHD 630 - the "VA-API not QSV" reasoning has only been checked against
      docs, not a real transcode.
- [ ] NVIDIA P620 passthrough (`nixos-modules/gpu-nvidia.nix`) actually
      loads the `legacy_580` driver branch and `nvidia-smi` sees the card
      inside the VM.
- [ ] `nvidia-container-toolkit` + `services.k3s.containerdConfigTemplate`
      wiring actually lets a pod request the GPU via CDI and successfully
      run something on it (e.g. `nvidia-smi` in a test pod) - config verified
      against nixpkgs source only, never run against a real container runtime.
- [ ] Confirm the real PCI bus addresses per physical host for
      `quicksync_pci_id`/`nvidia_pci_id` in `terraform.tfvars` - do NOT
      assume they match across hosts (see
      [[pcie-passthrough-aliasing]] for the longer-term fix).
- [ ] Confirm each Proxmox host still has a usable console (onboard 2nd
      graphics, serial, or IPMI/BMC) after the iGPU is bound to vfio-pci -
      per the caveat in `docs/proxmox-host-setup.md`.

## Longhorn disk growth (`nixos-modules/longhorn-disk-grow.nix`) & alerting (`nixos-modules/longhorn-disk-alert.nix`)

- [ ] Bump `longhorn_disk_gb` in `terraform.tfvars`, `tofu apply`, and
      confirm the timer actually detects the enlarged `/dev/vdb`, runs
      `growpart` + `resize2fs` online, and the filesystem grows with no
      reboot and no data loss.
- [ ] Confirm the 0/1 `growpart` exit-code handling (`SuccessExitStatus =
      "0 1"`) behaves as expected when the partition is already at full
      size (i.e. re-running the timer after a successful grow is a no-op,
      not a failure).
- [ ] Cross 80% real usage on `/var/lib/longhorn` and confirm the Discord
      webhook fires exactly once, then at most once/day while still over
      threshold, and stops once usage drops back below 80%.
- [ ] Manually run `systemctl start homelab-longhorn-disk-grow` and
      `systemctl start homelab-longhorn-disk-alert` once each before
      trusting the unattended 15-minute timers, per the modules' own
      comments.

## Auto-upgrade + rollback (`nixos-modules/auto-upgrade.nix`)

- [ ] Confirm the pre-check (apiserver `/readyz`, all nodes `Ready`) really
      skips a scheduled upgrade when the cluster is unhealthy, rather than
      piling a 2nd change on top.
- [ ] Force a bad rollout (e.g. a config that fails to bring k3s back
      `Ready` within the timeout) and confirm the auto-rollback
      (`nixos-rebuild switch --rollback` + `systemctl restart k3s`) actually
      recovers the node - this logic has never been exercised against a
      live cluster.
- [ ] Confirm the staggered per-node windows (`03:00`/`05:00`/`07:00`)
      leave enough real time between a node's upgrade finishing (or rolling
      back) and the next node's window starting, given actual `tofu
      apply`/rebuild durations on this hardware.
- [ ] Confirm `boot.loader.grub.configurationLimit` and `nix.gc` settings
      actually leave enough old generations on disk for `--rollback` to
      have something to fall back to, once GC has run a few times for real.
- [ ] Set `flakeRef` in `auto-upgrade.nix` to the real GitHub repo (still
      the placeholder value) before relying on this at all.

## Storage backends (`cluster-bootstrap/*.yaml`)

- [ ] `helm show values democratic-csi/democratic-csi` against the real
      chart, diff against the field names assumed in
      `democratic-csi-truenas-values.yaml` (see README's Accuracy note) -
      then do a real `helm install`.
- [ ] democratic-csi actually provisions NFS PVs against the real TrueNAS
      box using the sops-decrypted `truenas-driver-config` secret end to
      end (mount, write, read back from a pod).

Longhorn's own Helm-install/replica-count validation now belongs in
`homelab-apps` (its `infra/longhorn`) - only this repo's disk
provisioning/grow/alert pieces are validated below.

## Terraform / Proxmox provider (`terraform/modules/vm/main.tf`)

- [ ] `bpg/proxmox` resource/argument names (`machine = "q35"`, `discard =
      "on"`, `hostpci` blocks, etc.) actually apply cleanly against the real
      Proxmox API version in use - only checked against provider source,
      never run `tofu apply` for real.
- [ ] `lifecycle.ignore_changes` on `network_device[0].mac_address` and
      `initialization` actually prevents spurious diffs/reprovisioning on a
      real `tofu plan` after the VM has been running a while.
- [ ] `scripts/add-node.sh` actually joins a 4th node cleanly post-bootstrap
      (targeted `tofu apply`, then `nixos-anywhere`, then `kubectl get
      nodes` shows it `Ready`).

## sops / secrets

- [ ] Real `sops -e -i` / `sops -d` round-trip against `secrets/*.sops.yaml`
      works with the actual age key, and sops-nix decrypts the k3s join
      token and TrueNAS API key/Discord webhook secrets at activation on a
      real node (only exercised in the abstract so far).
