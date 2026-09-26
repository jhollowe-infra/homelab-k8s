#!/usr/bin/env bash
# Add a new k8s node VM after initial bootstrap.
#
# 1. Add a hosts/<name>/default.nix (copy an existing node's, set
#    clusterInit = false and serverAddr).
# 2. Add the node to flake.nix (nixosConfigurations + colmena) and to
#    terraform/terraform.tfvars (nodes = { ... }).
# 3. Run this script.
set -euo pipefail
cd "$(dirname "$0")/.."

host="${1:?usage: add-node.sh <hostname>}"

echo "==> Creating VM for ${host}"
tofu -chdir=terraform apply -target="module.node[\"${host}\"]"

ip="$(tofu -chdir=terraform output -json node_ips | jq -r ".\"${host}\"[0][0]")"
echo "==> Installing NixOS on ${host} (${ip})"
nixos-anywhere --flake ".#${host}" "root@${ip}"

echo "==> ${host} joined. Verify with:"
echo "    KUBECONFIG=./kubeconfig kubectl get nodes"
