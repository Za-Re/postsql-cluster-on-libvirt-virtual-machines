# PostgreSQL Cluster Lab 01

> **Learning project, not a production pattern.** This exists to build
> hands-on understanding of PostgreSQL replication concepts (WAL,
> streaming replication, manual promotion, split-brain risk) by
> deliberately doing the parts an HA manager would normally automate.
> In production, use a managed/HA solution (Patroni, repmgr, or a
> managed cloud database) instead of hand-rolling failover like this.

Three-node PostgreSQL 18 cluster (1 primary + 2 streaming replicas)
built from scratch: Terraform provisions the VMs, Ansible configures
the OS and PostgreSQL, native physical streaming replication handles
the data. No HA manager, so failover is manual, by design (see
[FAILOVER.md](FAILOVER.md)). Full design writeup in
[architecture.md](architecture.md); every provider quirk and decision
made along the way in [docs/DECISIONS.md](docs/DECISIONS.md).

```
        pg-01 PRIMARY
       /            \
  pg-02 REPLICA   pg-03 REPLICA
```

## Host prerequisites (read before `terraform apply`)

Run `scripts/hypervisor-bootstrap.sh` once on the KVM host before
first use. See that script and `docs/DECISIONS.md` for the full
diagnosis, but the key thing to know:

**This lab sets `security_driver = "none"` in `/etc/libvirt/qemu.conf`
on the host.** That disables AppArmor confinement *and* dynamic DAC
ownership management for every VM libvirt runs on this machine, not
just this project's 3 nodes. It was needed to work around a real
AppArmor gap with this provider's COW disk backing-chain setup
(details in `docs/DECISIONS.md`).

**This is a lab-only trade, not a production recommendation.**
Disabling `security_driver` removes a real defense-in-depth layer.
Normally, even if a VM's process were compromised, AppArmor stops it
from reading other VMs' disks or arbitrary host files. Acceptable here
for a personal, single-operator, non-multi-tenant lab machine; do
**not** carry this setting into a shared or production KVM host. A
more surgical fix (a scoped AppArmor local-override for just the
affected path, instead of disabling the security driver entirely) is
the option to reach for there.

Also needed on the host: KVM/libvirt, Terraform, Ansible (with the
`community.general` and `community.postgresql` collections. Both
ship with the full `ansible` package, not just `ansible-core`).

## Running it

```bash
# 1. Provision the VMs
cd terraform
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply

# 2. Configure OS + PostgreSQL + replication
cd ../ansible
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml --extra-vars "bootstrap_replica=true"

# 3. Verify
ansible all -m ping

# replication status on the primary — both replicas should show
# state=streaming, sync_state=async
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
  "sudo -u postgres psql -c 'SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;'"

# each replica should report recovery=true
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
  "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.13 \
  "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"

# write on the primary, confirm it shows up on both replicas
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
  "sudo -u postgres psql -c 'CREATE DATABASE academy;'"
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
  "sudo -u postgres psql -d academy -c 'CREATE TABLE cluster_test (id BIGSERIAL PRIMARY KEY, message TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT now());'"
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
  "sudo -u postgres psql -d academy -c \"INSERT INTO cluster_test(message) VALUES ('hello from babak academy');\""
ssh -i ../ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
  "sudo -u postgres psql -d academy -c 'SELECT * FROM cluster_test;'"
```

See `FAILOVER.md` for the full set of manual failover checks (stopping/restarting nodes, promotion, rejoin).

`ssh_keys/` and `ansible/.vault_pass` are generated locally, gitignored. See `ssh_keys/README.md` and `ansible/README.md` to regenerate them.

## Destroying

```bash
cd terraform
terraform destroy
```

Nothing persists outside this repo so it's safe to destroy and recreate at
will (the whole point of the local, no-cloud-cost setup this project
deliberately chose. See `docs/DECISIONS.md`).

## Repo layout

```
terraform/        infrastructure: VMs, network, storage
ansible/          OS + PostgreSQL configuration, replication, secrets
docs/             DECISIONS.md contains the "why" behind every choice and fix
architecture.md   full design writeup
FAILOVER.md       manual failover exercises + required analysis
```
