#!/usr/bin/env bash
# One-time: installs NixOS via nixos-anywhere on all 3 freshly-created VMs,
# in order (node-1 first, since it's the one with clusterInit = true and
# the others need it reachable via serverAddr).
#
# Run from inside `nix develop` (flake.nix devShell) so nixos-anywhere,
# colmena, kubectl etc. are on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

for host in hl01-kube01 hl01-kube02 hl01-kube03; do
  # get the DHCP IP the bootstrap image got (not loopback IP)
  ip="$(tofu -chdir=terraform output -json node_ips \
    | jq -er --arg host "$host" 'first(.[$host][][] | select(. != "127.0.0.1"))')"
  echo "==> Installing NixOS on ${host} (${ip})"
  SSHPASS=nixos nixos-anywhere --env-password --flake ".#${host}" "root@${ip}"
done

echo "==> Fetching kubeconfig from hl01-kube01"
node1_ip="$(tofu -chdir=terraform output -json node_installed_ips | jq -r '."hl01-kube01"')"
ssh "root@${node1_ip}" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1/${node1_ip}/" > kubeconfig
chmod 600 kubeconfig

echo "==> Cluster bootstrapped. Use it with:"
echo "    export KUBECONFIG=$(pwd)/kubeconfig"
echo "    kubectl get nodes"
echo ""
echo "Next: install Longhorn and democratic-csi, see cluster-bootstrap/README.md"
