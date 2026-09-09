# Architecture

## Responsibility boundary

```
 Terraform            Ansible                PostgreSQL / human
 ───────────           ───────────            ───────────────────
 provisions hosts  →   configures OS + PG  →  replicates +
 (VMs, network,        (packages, users,      manual primary promotion
 storage, keys)        firewall, vault,       on failure
                        replication config)
```

No HA manager (Patroni/repmgr) — deliberately. Leader election, client
routing, and safe rejoin after failover are left to the operator. See
`FAILOVER.md` for what that looks like in practice.

## Fresh-cluster topology

```
                    ┌─────────────────┐
                    │  Client / psql   │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │   pg-01 PRIMARY   │
                    │  192.168.100.11   │
                    │ accepts writes    │
                    └────┬─────────┬────┘
                WAL       │         │       WAL
             streaming    │         │    streaming
                    ┌──────▼──┐ ┌────▼─────┐
                    │ pg-02   │ │  pg-03   │
                    │ REPLICA │ │ REPLICA  │
                    │  .12    │ │   .13    │
                    └─────────┘ └──────────┘

     pg-cluster-net — 192.168.100.0/24, NAT, host-only reachable
```

| Node | IP | Role | vCPU/RAM/Disk |
|---|---|---|---|
| pg-01 | 192.168.100.11 | primary | 2 / 2 GB (dev) / 12 GB |
| pg-02 | 192.168.100.12 | replica | 2 / 2 GB (dev) / 12 GB |
| pg-03 | 192.168.100.13 | replica | 2 / 2 GB (dev) / 12 GB |

Static IPs via libvirt DHCP reservations keyed to each VM's MAC — see
`terraform/network.tf`.

## Infrastructure layer (Terraform)

- Provider: `dmacvicar/libvirt` (local KVM/QEMU, not AWS — see
  `docs/DECISIONS.md` for why).
- Base image: Ubuntu 24.04 cloud image, cloned copy-on-write per node.
- Identity/config injected via cloud-init (hostname, SSH key,
  `ssh_pwauth: false`) — no manual OS install step.
- Network: one isolated NAT subnet, unreachable from outside this
  host — this *is* the "restrict SSH to the administrative source"
  control, enforced structurally rather than by an allowlist rule.

## Configuration layer (Ansible)

- `roles/common` — hostname, base packages, time sync (`chrony`),
  base `ufw` policy (default deny incoming, allow SSH).
- `roles/postgres` — PGDG repo (Ubuntu's own repos only have PG16),
  installs PostgreSQL 18, sets replication-related settings
  (`wal_level`, `max_wal_senders`, `max_replication_slots`,
  `hot_standby`, `listen_addresses`), creates the least-privilege
  `replicator` role, `ufw` rule for 5432 scoped to the cluster
  subnet only, `pg_hba.conf` rule for replication connections.
  Applied to **every** node, not just the primary — a promoted
  replica needs these already active on itself.
- `roles/replica` — bootstraps a node via `pg_basebackup -R` from
  whichever host `inventory/hosts.ini` currently lists under
  `[primary]`, with a named, persistent replication slot. Guarded
  behind `bootstrap_replica=true` and a `standby.signal` check so it
  can never fire as a side effect of a routine run.
- Secrets (`postgres` superuser password, `replicator` password) live
  encrypted in `group_vars/vault.yml`, decrypted at runtime via
  `ansible.cfg`'s `vault_password_file` (gitignored, local only).

## Replication design

- Native PostgreSQL physical streaming replication, asynchronous.
- One named replication slot per replica (`pg_0N_slot`) — retains WAL
  for a disconnected replica indefinitely rather than a fixed
  `wal_keep_size` window, at the cost of needing slot monitoring (an
  offline replica pins WAL on the primary's disk until it reconnects).
- Replica auth via `.pgpass`, not a password embedded in
  `primary_conninfo`.

## Security posture

| Control | Where |
|---|---|
| SSH: key-only, dedicated lab keypair | cloud-init (Terraform) |
| Network isolation (private NAT subnet) | `terraform/network.tf` |
| Firewall: deny-by-default, SSH + 5432 (cluster subnet only) | `ufw` (Ansible) |
| DB access: least-privilege `replicator` role, password auth | `pg_hba.conf` (Ansible) |
| Secrets outside git | Ansible Vault |

Full rationale and every provider/tooling quirk hit along the way:
`docs/DECISIONS.md`.
