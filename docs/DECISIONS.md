# Decisions log

Running notes on *why*, kept separate from the code so the `.tf`/`.yml`
files stay clean. Newest entries at the bottom.

## Infra path: local libvirt/KVM, not AWS

No AWS free tier available; VirtualBox is installed but its Terraform
provider (`terra-farm/virtualbox`) is thinly maintained and has weak
cloud-init support. Host already has a fully working KVM/libvirt stack
(confirmed: CPU virtualization flags, `kvm_amd` module loaded, libvirtd
active via socket activation, user in `libvirt` group). Chose
`dmacvicar/libvirt`, an actively maintained provider with proper
cloud-init support since it would be closer to the AWS experience than the VirtualBox
provider.

## Provider version pin: `~> 0.9.9`

`dmacvicar/libvirt` is still pre-1.0. Under semver, a 0.x package can
introduce breaking changes on a minor bump (0.9 -> 0.10), so the
constraint intentionally floats only the last digit (0.9.9, 0.9.10, ...)
rather than the whole minor version.

## Connection URI: `qemu:///system`, not `qemu:///session`

`qemu:///session` is a per-user, unprivileged libvirtd instance with
simpler permissions, but it doesn't support the NAT/bridged networking
the 3-node cluster needs. `qemu:///system` is the system-wide instance,
same one `virsh list --all` used during host verification and the
account is already in the `libvirt` group, so no `sudo` is needed.

## SSH key: dedicated lab keypair, stored in the repo (not `~/.ssh`)

Generated at `ssh_keys/pg_cluster_ed25519` (gitignored; only
`ssh_keys/README.md` is committed) instead of reusing the personal
`~/.ssh/id_ed25519` or adding a new key under `~/.ssh`. Reasoning:
- Disposable lab infra shouldn't share a key with real accounts/servers.
- Keeping it inside the repo makes the project self-contained. Anyone
  cloning it (or a grader) can see exactly which key is in play and
  regenerate it, without touching the user's personal `~/.ssh`.
- Both Terraform (`variables.tf`, injects the `.pub` via cloud-init) and
  Ansible (inventory, uses the private key to connect) reference it by
  a relative repo path, so it isn't tied to one operator's home
  directory setup.

## Network subnet: `192.168.100.0/24`

Checked host's real ranges to avoid collisions with Wi-Fi LAN and a pre-existing libvirt bridge (`virbr0`)

## Static IPs: `ips[].dhcp.hosts[]` on `libvirt_network`, not on the domain

Older provider docs/examples show classic HCL blocks (`mode = "nat"`,
`addresses = [...]`) directly on `libvirt_network`. `terraform validate`
rejected that against the installed v0.9.9 — this provider version was
rewritten on the newer plugin framework, using typed nested attributes
that mirror libvirt's own XML schema more closely (`forward.mode`,
`ips[].address`/`prefix`, `ips[].dhcp.hosts[]` for static leases).

## Cloud-init disk must be re-ingested as a `libvirt_volume`

`libvirt_cloudinit_disk` only writes an ISO to local disk (`.path`); it
is not itself attachable to a domain. The provider's own resource docs
show the fix: feed that `.path` into a second `libvirt_volume` via
`create.content.url`, which uploads it into the pool as a real volume —
that's the volume a domain's cdrom `disks[]` entry actually references.

## AppArmor blocked domain start; fixed at the host-bootstrap layer

First real `terraform apply` failed: `Could not open
'.../ubuntu-24.04-base': Permission denied` when starting each domain.
The file's own DAC ownership/permissions were correct
(`libvirt-qemu:kvm`, `0600`) — but the per-VM QEMU log revealed QEMU
was actually launched with `USER=root` (this host's `qemu.conf` has no
uncommented `user =`/`group =`, unlike Ubuntu's usual packaged
default), which makes DAC bits moot: root bypasses them outright. The
real blocker was Ubuntu's per-VM **AppArmor** profile (MAC confinement
applies to root too). Its dynamically generated `.files` fragment
(meant to list every disk path the VM may touch) was missing entirely
— most likely `virt-aa-helper` failing to walk the backing-file chain
for our `node_disk` -> `base_image` relationship, set via Terraform's
`backing_store` attribute rather than a domain-declared `<disk>`.

Two things tried and ruled out along the way, kept here so the reasoning
isn't lost: `sudo aa-complain libvirtd` (targets the *daemon's own*
profile, not the per-VM one — didn't help) and disabling libvirt's
mount-namespace isolation (`namespaces = []` — also didn't help, so
that mechanism wasn't the cause either). The kernel audit log search
that seemed to rule AppArmor out entirely was itself misleading: it
showed `kauditd_printk_skb: N callbacks suppressed` right at the
relevant timestamp — the actual denial for this exact event was very
likely rate-limited away by the kernel, never reaching the log.

**Confirmed fix**: `security_driver = "none"` in `/etc/libvirt/qemu.conf`
(+ `systemctl restart libvirtd`) — disables AppArmor *and* dynamic DAC
relabeling for every future libvirt-managed QEMU domain on this host.
`terraform apply` succeeded immediately after. Captured as
`scripts/hypervisor-bootstrap.sh` rather than run ad hoc — this is a
one-time **host** setup step, a layer below Terraform (which assumes a
working hypervisor already exists, the same assumption the AWS
provider makes about EC2's own hypervisor). In a team setting this
belongs in whatever provisions the KVM host itself — a Packer-built
golden image or an Ansible "hypervisor bootstrap" role — not something
engineers are expected to remember and type by hand.

Tradeoff, explicitly: this is host-wide, not project-scoped — it
removes AppArmor's per-VM containment for *every* VM this host ever
runs via libvirt, not just this project's 3 nodes. Acceptable for a
single-operator, non-multi-tenant lab machine; revisit if this host is
ever used for anything less trusted. A more surgical fix (a scoped
AppArmor local-override snippet for just the missing path, instead of
disabling the security driver entirely) remains the option to reach
for if AppArmor needs to stay fully enforced.

## Ansible: `host_key_checking = False`

VMs get destroyed/recreated at the same IPs regularly, and each fresh
VM gets a brand-new SSH host key on first boot. Without disabling the
check, every recreate would trip "REMOTE HOST IDENTIFICATION HAS
CHANGED" and refuse to connect until `~/.ssh/known_hosts` is manually
cleared. Standard trade for ephemeral lab infra; acceptable here since
the subnet is NAT-isolated and reachable only from this host (same
reasoning as the Phase 1 "administrative source" restriction).

A more surgical alternative was built and verified working — a small
script (`ssh-keygen -R` + `ssh-keyscan` per node, IPs read from
`terraform output -json`) that keeps `host_key_checking` at its secure
default instead of disabling it outright. Reverted to the plain
disable for now to keep the workflow simpler while iterating on later
phases; the scripted approach is easy to reinstate later (see git
history) if tighter host-key verification is ever wanted. Would not
rely on the blanket disable on a real fleet with persistent hosts —
proper fix there is SSH CA host certificates or scripted `known_hosts`
management.

## Ansible Vault: `become_user` to an unprivileged user needs `acl`

Setting the `postgres` superuser password via
`community.postgresql.postgresql_user` requires running as the
`postgres` OS user (peer auth on the local socket) — `become_user:
postgres` on top of `become: true`. This failed with `chmod: invalid
mode: 'A+user:postgres:rx:allow'` — Ansible's mechanism for handing
off its temp files to an unprivileged `become_user` needs the `acl`
package (`setfacl`/`getfacl`) on the target; without it, Ansible falls
back to a broken BSD-style ACL syntax that doesn't exist on Linux.
Fixed by adding `acl` to `roles/common`'s base packages — a general
Ansible-operational prerequisite (needed by any future role that uses
`become_user` to switch to a non-root account), not Postgres-specific,
which is why it lives in `common` rather than `postgres`.

## PostgreSQL version and paths as explicit variables (`group_vars/all.yml`)

Targeting PG 18, matching the lab's own stated baseline. Data/config/bin
paths are variables, not hardcoded in tasks — required by item 8, and
genuinely necessary since Debian/Ubuntu's `postgresql-common` packaging
keeps config (`postgresql.conf`, `pg_hba.conf`) *outside* PGDATA
(`/etc/postgresql/<version>/main` vs `/var/lib/postgresql/<version>/main`),
unlike most other distros which nest config inside the data directory.
A RHEL-based image would need different values here, not different task
logic. Also worth remembering: Debian's own tooling (`pg_lsclusters`,
`pg_ctlcluster`) calls a *single server instance* a "cluster" — a
different sense of the word than our 3-node primary+replicas cluster.

## Replica bootstrap requires an explicit `bootstrap_replica=true` flag

`roles/replica`'s destructive block (stop postgresql, wipe PGDATA,
`pg_basebackup` from the primary) was originally guarded only by
`standby.signal` not existing. That's correct for the common case
(already-bootstrapped replica, playbook re-run) but has a real gap:
`pg_promote()` (Phase 5) automatically removes `standby.signal` as
part of promotion, and `inventory/hosts.ini` is static — a promoted
node stays listed under `replicas` with nothing updating that
automatically. A routine playbook re-run after a Phase 5 promotion
would see "no standby.signal" on the now-primary node and wipe its
real data. Fixed by requiring `--extra-vars "bootstrap_replica=true"`
in addition to the `standby.signal` check, so the destructive path can
never fire as a side effect of an ordinary run — only when explicitly
intended. A more robust fix (comparing Postgres's own cluster system
identifier, shared by a primary and its real replicas but different
for any independently-initialized instance — closer to what Patroni
actually does) was considered and set aside as more than this lab
needs.

## `serial: 1` on the replica-bootstrap play

First real run: `pg-03`'s `pg_basebackup` succeeded, `pg-02`'s failed
with `requested WAL segment ... has already been removed`. Ansible
runs a play's tasks across hosts in parallel by default — both
replicas were pulling a full base backup from the primary at the same
time, which slowed `pg-02`'s enough that the primary recycled an older
WAL segment before `pg-02`'s backup process consumed it, despite the
replication slot. `pg_basebackup` cleaned up its own partial data on
failure, so no manual cleanup was needed — just a re-run. Fixed by
adding `serial: 1` to the replica play, forcing replicas to bootstrap
one at a time rather than racing each other against the same primary.

## Replication slot created separately, not via `pg_basebackup --create-slot`

Second failure on retry: `pg_02_slot` already exists — `pg_basebackup
--create-slot` creates the slot as an early step, and when the first
attempt failed later (the WAL-race issue above), its cleanup only
removed the copied data, not the slot already created on the primary.
`--create-slot` errors outright on an existing slot, so every retry
kept failing the same way without manual cleanup on the primary.

Fixed by creating the slot as its own explicit step, using
`community.postgresql.postgresql_slot` with `state: present`
(idempotent — confirms the slot exists rather than erroring if it
already does, cleanly absorbing the orphaned slot from the earlier
failures) and `immediately_reserve: true` (reserves the slot's WAL
retention point immediately at creation time, rather than only once
`pg_basebackup` gets around to connecting — likely also a more
deterministic fix for the original WAL-race than hoping timing works
out). `pg_basebackup` then references the pre-existing slot via
`--slot=` without `--create-slot`.

Slots are a primary-side concept (they don't exist on a replica at
all), but this task lives in `roles/replica`, which runs against the
replica hosts — so it uses `delegate_to: "{{ groups['primary'][0] }}"`
to make the actual connection land on the primary while keeping the
slot-naming logic (based on the replica's own hostname) in the same
role/file as the rest of that replica's bootstrap.