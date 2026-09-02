# SSH keypair for the lab cluster

This directory holds a dedicated keypair used only to reach the 3 lab VMs
(injected by cloud-init, used by Ansible to connect). It is **not**
committed to git — only this README is.

Regenerate it with:

```bash
ssh-keygen -t ed25519 -f ssh_keys/pg_cluster_ed25519 -N "" -C "pg-cluster-lab"
```

- `pg_cluster_ed25519` — private key (permissions `600`)
- `pg_cluster_ed25519.pub` — public key, referenced by
  `terraform/variables.tf` (`ssh_public_key_path`) and by
  `ansible/inventory` as the key Ansible connects with.
