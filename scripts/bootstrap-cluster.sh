#!/usr/bin/env bash
# One-time: installs NixOS via nixos-anywhere on all 3 freshly-created VMs,
# in order (node-1 first, since it's the one with clusterInit = true and
# the others need it reachable via serverAddr).
#
# Run from inside `nix develop` (flake.nix devShell) so nixos-anywhere,
# colmena, kubectl etc. are on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -r age-key.txt ]]; then
  echo "Missing age-key.txt; create or restore the age private key first." >&2
  exit 1
fi
SOPS_AGE_KEY_FILE="$(pwd)/age-key.txt" sops -d secrets/secrets.sops.yaml >/dev/null

extra_files="$(mktemp -d)"
trap 'rm -rf "$extra_files"' EXIT
install -d -m 0755 "$extra_files/var/lib/sops-nix"
install -m 0400 age-key.txt "$extra_files/var/lib/sops-nix/key.txt"

for host in hl01-kube01 hl01-kube02 hl01-kube03; do
  # get the DHCP IP the bootstrap image got (not loopback IP)
  ip="$(tofu -chdir=terraform output -json node_ips \
    | jq -er --arg host "$host" 'first(.[$host][][] | select(. != "127.0.0.1"))')"
  echo "==> Installing NixOS on ${host} (${ip})"
  SSHPASS=nixos nixos-anywhere --env-password --extra-files "$extra_files" \
    --flake ".#${host}" "root@${ip}"
done

echo "==> Fetching kubeconfig from hl01-kube01"
node1_ip="$(tofu -chdir=terraform output -json node_installed_ips | jq -er '."hl01-kube01" | split("/")[0]')"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${node1_ip}" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s|127.0.0.1|${node1_ip}|" > kubeconfig
chmod 600 kubeconfig

echo "==> Cluster bootstrapped. Use it with:"
echo "    export KUBECONFIG=$(pwd)/kubeconfig"
echo "    kubectl get nodes"
echo ""
echo "Next: install Longhorn and democratic-csi, see cluster-bootstrap/README.md"
