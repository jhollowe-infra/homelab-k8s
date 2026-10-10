# Proxmox host setup

This playbook configures the Proxmox no-subscription apt repository, disables
the standard PVE and Ceph enterprise source files, enables Intel IOMMU and
VFIO modules, and disables TSO/GSO on interfaces detected with the e1000e
kernel driver. It also disables the Proxmox subscription notice which restarts
`pveproxy` if it changes the notice configuration.
It targets Proxmox VE 8+ hosts using `/etc/kernel/cmdline`.

## Run

Install Ansible on the control machine, copy `inventory.example.yml` to
`inventory.yml`, and set each host's SSH address and user. The playbook
detects e1000e devices from their bound Linux kernel driver. Its generated
interface stanza uses `inet manual`, suitable for physical ports enslaved to
a Linux bridge; review the generated file if an e1000e interface is directly
configured with an address.

Preview one host, then apply:

```sh
ansible-playbook -i inventory.yml site.yml --limit pve1 --check --diff
ansible-playbook -i inventory.yml site.yml --limit pve1
```

The playbook does not reboot the host or restart networking. Reboot after
applying to activate the kernel command line. Verify IOMMU with
`cat /proc/cmdline` and `dmesg | grep -i iommu`.

NFS mounting and cluster joining are not included: the repository does not
define the host-specific NFS export or cluster-join details needed to do
those safely.
