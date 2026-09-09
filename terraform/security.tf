# Security posture for this project (local libvirt path) — full
# rationale in docs/DECISIONS.md. No resources of its own; this exists
# for repo-layout parity with the lab spec and to point at where each
# control actually lives.
#
# - SSH: key-only auth (ssh_pwauth: false), dedicated key injected via
#   cloud-init — see compute.tf (libvirt_cloudinit_disk.node_init).
# - Network isolation: private NAT subnet, unreachable from outside this
#   host — see network.tf (libvirt_network.pg_cluster).
# - Node-to-node port restriction (only 5432 between the 3 DB nodes,
#   not "anyone on the subnet") is intentionally handled by ufw in
#   Ansible, not Terraform — local libvirt has no security-group
#   equivalent to enforce this at the network layer.
