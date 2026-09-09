# Failover

Manual failover exercises performed against the live cluster (Phase 5).
No HA manager exist and every step below is a human decision, not an automatic
one. That gap is the point of this lab.

## Test A: lose one replica

1. Stopped PostgreSQL on `pg-02`.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo systemctl stop postgresql"
   ```

2. Confirmed the primary (`pg-01`, at the time) stayed writable by
   inserting a row while `pg-02` was down.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
     "sudo -u postgres psql -d database_test -c \"INSERT INTO cluster_test(message) VALUES ('primary still writable while pg-02 is down');\""
   ```

3. `pg_stat_replication` on the primary correctly showed only `pg-03`.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
     "sudo -u postgres psql -c \"SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;\""
   ```

4. Restarted `pg-02`: it reappeared streaming, and the row written
   during its outage was present, confirming real catch-up (not just
   a reconnect).

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo systemctl start postgresql"

   # back in pg_stat_replication on the primary
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
     "sudo -u postgres psql -c \"SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;\""

   # and the row it missed is now present
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo -u postgres psql -d database_test -c 'SELECT * FROM cluster_test ORDER BY id;'"
   ```

**What changes if the standby is offline too long**: `pg-02` has a
named, persistent replication slot, so the primary retains *all* WAL
generated during its outage, no matter how long. The only limit is
the primary's own disk filling up with retained WAL (`pg_wal`), not a
fixed time/size window. Without a slot (relying only on
`wal_keep_size`), a long enough outage would eventually make catch-up
impossible and force a full rebuild instead of a simple restart.

## Test B: lose the primary

```
1. Healthy        2. Primary fails    3. Human decides      4. Promote
   pg-01 primary     pg-01 unreach-      compared LSN on       SELECT
   pg-02/03 replica  able, no auto       pg-02 vs pg-03:       pg_promote()
                      election           tied → either safe    on pg-02
                                                                    │
   ┌────────────────────────────────────────────────────────────┘
   ▼
5. Re-point                          6. Safe rejoin
   inventory/hosts.ini edited           pg-03 rebuilt via
   by hand: pg-02 → [primary]           pg_basebackup from
   (no automatic discovery)             pg-02 (old primary
                                         NOT restarted writable)
```

1. Stopped `pg-01`.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.11 \
     "sudo systemctl stop postgresql"
   ```

2. **Did not promote immediately** — checked `pg_last_wal_replay_lsn()`
   on both remaining replicas first. Both showed the identical LSN, so either was an equally safe candidate.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo -u postgres psql -c 'SELECT pg_last_wal_replay_lsn();'"
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.13 \
     "sudo -u postgres psql -c 'SELECT pg_last_wal_replay_lsn();'"
   ```

3. Promoted `pg-02`.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo -u postgres psql -c 'SELECT pg_promote();'"
   ```

4. Verified: `pg_is_in_recovery()` on `pg-02` flipped to `f`.

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
   ```

5. Updated `inventory/hosts.ini` by hand — `pg-02` moved to
   `[primary]`, `pg-01` removed (failed, unmanaged). This *is* the
   "how does an application find the new primary" mechanism in this
   lab: nothing does it automatically.

6. Rebuilt `pg-03` as a replica of `pg-02` via `pg_basebackup`. Its
   stale `standby.signal` still pointed at the dead `pg-01`, so it had
   to be stopped and cleared before the bootstrap guard would let the
   rebuild run:

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.13 \
     "sudo systemctl stop postgresql"
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.13 \
     "sudo rm /var/lib/postgresql/18/main/standby.signal"

   cd ansible
   # skip straight to the replica-bootstrap play — postgresql isn't
   # running on pg-03 right now, so the first play would fail trying
   # to reach it
   ansible-playbook playbooks/site.yml \
     --extra-vars "bootstrap_replica=true" \
     --start-at-task "Check whether this node is already a standby"

   # then a normal run so the first play can re-apply cleanly now
   # that pg-03 has a real running instance again
   ansible-playbook playbooks/site.yml
   ```

   Verified it came back in recovery mode, streaming, and holding
   *all* current data, including the row written during Test A's
   outage, proving it rebuilt from `pg-02`'s real current state:

   ```bash
   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.12 \
     "sudo -u postgres psql -c \"SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;\""

   ssh -i ssh_keys/pg_cluster_ed25519 ubuntu@192.168.100.13 \
     "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();' -d database_test -c 'SELECT * FROM cluster_test ORDER BY id;'"
   ```

7. **`pg-01` was deliberately not restarted as a writable server** —
   see below for why. It remains stopped, unmanaged, pending a rebuild
   decision.

## Current state

```
                    ┌─────────────────┐
                    │  Client / psql   │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  pg-02 PRIMARY    │  ← promoted
                    │  192.168.100.12   │
                    └─────────┬─────────┘
                       WAL streaming
                    ┌─────────▼─────────┐
                    │  pg-03  REPLICA    │  ← rebuilt from pg-02
                    │  192.168.100.13    │
                    └────────────────────┘

  pg-01 (192.168.100.11) — STOPPED, unmanaged, not in inventory
```

## Required failure analysis

**How was the promotion candidate selected?**
By comparing `pg_last_wal_replay_lsn()` across the remaining
replicas before promoting anything — whichever replica has replayed
the most WAL is closest to what the old primary actually had, meaning
the least potential data loss. In our case both were tied, so either
was safe.

**How would an application discover the new primary?**
It wouldn't, automatically which is the deliberate gap this lab
exists to demonstrate. A human (or external tooling this lab
intentionally omits, like Patroni/repmgr/a proxy) has to update
whatever the application uses to find the primary: a connection
string, a DNS record, a load balancer's backend config, or as we
did directly, the Ansible inventory driving the whole cluster.

**What is a PostgreSQL timeline?**
An identifier tagging a branch of WAL history, incremented every time
that history "forks", most importantly, on promotion, when a former
standby stops replaying someone else's WAL and starts generating its
own. It's embedded in WAL segment filenames, and it's what lets
Postgres detect two incompatible histories rather than silently
merging them.

**Why can the old primary cause split-brain?**
If restarted as a normal writable server without reconciling
timelines first, it and the newly-promoted primary could each accept
independent writes at the same time — two genuinely divergent
histories with no automatic way to merge them back together.

**When would you rebuild the old primary vs. use `pg_rewind`?**
`pg_rewind` is faster. It rewinds just the diverged portion instead
of re-copying everything but it only works if the right
prerequisites were enabled *before* the divergence happened (below).
Without them, a full rebuild (wipe + `pg_basebackup`) is the only safe
option, regardless of preference. That's our situation here.

**What prerequisites must exist before `pg_rewind` can safely help?**
Either `data_checksums` (set only at `initdb` time, can't be added
retroactively) or `wal_log_hints = on` (changeable anytime, but only
protects WAL written *after* it's enabled) must already be active
before the fork point, so `pg_rewind` can identify exactly which data
blocks changed. The WAL from the divergence point onward must still be
available. The node being rewound must be cleanly stopped first. This
cluster never enabled either prerequisite, so `pg_rewind` is not a
viable option for `pg-01` as it stands and a full rebuild is required.
