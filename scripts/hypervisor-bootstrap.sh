#!/usr/bin/env bash
# One-time setup for the KVM/libvirt HOST machine — not run by Terraform.
# Terraform's libvirt provider assumes a working hypervisor already
# exists (same assumption the AWS provider makes about EC2's own
# hypervisor); getting the host itself ready is a separate, one-time
# layer, same idea as a Packer-built golden image or an Ansible
# "hypervisor bootstrap" role. Re-run safely on a fresh host — every
# step here is idempotent.
set -euo pipefail

# On this host, qemu.conf has no uncommented user/group directives, so
# QEMU runs guest processes as literal root (not libvirt-qemu). Ubuntu's
# per-VM AppArmor profile still confines root, and its dynamically
# generated file-access rules failed to include our COW backing-chain
# base image (node_disk -> base_image via Terraform's backing_store,
# not a domain-declared <disk>) — domains failed to start with
# "Could not open '<base image>': Permission denied". Confirmed fix via
# direct testing (aa-complain on libvirtd's own profile and disabling
# libvirt's mount namespaces were tried first and did NOT help — see
# docs/DECISIONS.md for the full diagnosis).
#
# Tradeoff: this disables AppArmor + dynamic DAC relabeling for every
# VM this host runs via libvirt, not just this project's — acceptable
# for a single-operator, non-multi-tenant lab machine. Revert with:
#   sudo sed -i '/^security_driver = "none"$/d' /etc/libvirt/qemu.conf
#   sudo systemctl restart libvirtd
sudo bash -c 'grep -q "^security_driver" /etc/libvirt/qemu.conf || echo "security_driver = \"none\"" >> /etc/libvirt/qemu.conf'
sudo systemctl restart libvirtd
