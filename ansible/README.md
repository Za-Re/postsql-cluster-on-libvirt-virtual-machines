# Ansible Vault password

`.vault_pass` holds the password used to encrypt/decrypt
`group_vars/vault.yml`. Generated locally, never committed (only this
README is).

Regenerate it with:

```bash
openssl rand -base64 32 > ansible/.vault_pass
```

If you regenerate it, any existing `group_vars/vault.yml` encrypted
with the *old* password will need re-encrypting (`ansible-vault rekey`
or decrypt + re-encrypt with the new password) — otherwise Ansible
won't be able to read it anymore.
