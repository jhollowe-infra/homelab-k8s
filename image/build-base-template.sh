#!/usr/bin/env bash
# Creates ONE Proxmox VM template that nixos-anywhere installs NixOS onto.
#
# Since the 3 Proxmox hosts are in a cluster with shared storage, this only
# needs to be run once, from any single host - all hosts can then clone the
# resulting template regardless of which physical host they land on.
#
# We deliberately do NOT need a Talos-style custom-built image here:
# nixos-anywhere kexecs a NixOS installer into any running Linux over SSH
# and repartitions/installs from there, so a generic minimal cloud image is
# enough as the starting point. Debian's cloud image is used because it's
# small and boots fast; its contents are irrelevant after nixos-anywhere runs.
set -euo pipefail

PVE_HOST="${PVE_HOST:?set PVE_HOST to the Proxmox host to run this against, e.g. pve1.lan}"
TEMPLATE_ID="${TEMPLATE_ID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-nixos-anywhere-base}"
STORAGE="${STORAGE:-local-lvm}"
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"

img="$(mktemp -d)/base.qcow2"
echo "==> Downloading base cloud image"
curl -fL -o "$img" "$DEBIAN_IMAGE_URL"

echo "==> Creating template VM $TEMPLATE_ID ($TEMPLATE_NAME) on $PVE_HOST"
ssh "root@${PVE_HOST}" "qm create ${TEMPLATE_ID} --name ${TEMPLATE_NAME} --memory 2048 --cpu host --net0 virtio,bridge=vmbr0 --serial0 socket --vga serial0 --ostype l26"

echo "==> Importing disk into ${STORAGE}"
scp "$img" "root@${PVE_HOST}:/tmp/base.qcow2"
ssh "root@${PVE_HOST}" "qm importdisk ${TEMPLATE_ID} /tmp/base.qcow2 ${STORAGE} && rm -f /tmp/base.qcow2"
ssh "root@${PVE_HOST}" "qm set ${TEMPLATE_ID} --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0"
ssh "root@${PVE_HOST}" "qm set ${TEMPLATE_ID} --ide2 ${STORAGE}:cloudinit --boot order=scsi0 --agent enabled=1"
ssh "root@${PVE_HOST}" "qm template ${TEMPLATE_ID}"

rm -rf "$(dirname "$img")"
echo "==> Done. Template ID ${TEMPLATE_ID} is available cluster-wide."
echo "    Set proxmox_template_id = ${TEMPLATE_ID} in terraform.tfvars."
