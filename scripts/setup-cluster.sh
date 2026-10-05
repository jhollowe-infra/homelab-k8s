#!/usr/bin/env bash
# Fetches the k3s kubeconfig from node-1, then installs democratic-csi.
# Longhorn is installed separately, via Flux, from the homelab-apps repo
# (see infra/longhorn there) - this repo only provisions and grows the
# underlying disk it uses (hosts/common/disko.nix,
# nixos-modules/longhorn-disk-{grow,alert}.nix).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -r age-key.txt ]]; then
  echo "Missing age-key.txt; create or restore the age private key first." >&2
  exit 1
fi
if [[ ! -r secrets/truenas-driver-config.sops.yaml ]]; then
  echo "Missing secrets/truenas-driver-config.sops.yaml; create and encrypt it first." >&2
  exit 1
fi
SOPS_AGE_KEY_FILE="$(pwd)/age-key.txt" sops -d secrets/truenas-driver-config.sops.yaml >/dev/null

echo "==> Fetching kubeconfig from hl01-kube01"
node1_ip="$(tofu -chdir=terraform output -json node_installed_ips | jq -er '."hl01-kube01" | split("/")[0]')"
api_vip_hostname="k8s-api-vip.kube-nodes.johnhollowell.internal"
kubeconfig_tmp="$(mktemp "$(pwd)/.kubeconfig.XXXXXX")"
trap 'rm -f "$kubeconfig_tmp"' EXIT
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${node1_ip}" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s|127.0.0.1|${api_vip_hostname}|" > "$kubeconfig_tmp"
chmod 600 "$kubeconfig_tmp"
mv "$kubeconfig_tmp" kubeconfig
trap - EXIT
export KUBECONFIG="$(pwd)/kubeconfig"

echo "==> Installing democratic-csi"
helm repo add democratic-csi https://democratic-csi.github.io/charts/ --force-update
helm repo update
kubectl create namespace democratic-csi --dry-run=client -o yaml | kubectl apply -f -
SOPS_AGE_KEY_FILE="$(pwd)/age-key.txt" sops -d secrets/truenas-driver-config.sops.yaml \
  | kubectl apply -n democratic-csi -f -
helm upgrade --install truenas-nfs democratic-csi/democratic-csi \
  --namespace democratic-csi \
  --values cluster-bootstrap/democratic-csi-truenas-values.yaml

echo "==> Cluster setup complete. Use it with:"
echo "    export KUBECONFIG=$(pwd)/kubeconfig"
echo "    kubectl get nodes"
