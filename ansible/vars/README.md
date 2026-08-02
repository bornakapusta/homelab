# Bootstrap secrets

This directory holds controller-local, one-time provisioning credentials.
Files matching `*.vault` are ignored by Git and must be encrypted with
Ansible Vault.

Create the Tailscale bootstrap file from the `ansible/` directory:

```bash
ansible-vault create vars/tailscale.vault
```

Enter only this variable in the encrypted editor:

```yaml
tailscale_auth_key: "your newly generated key"
```

Load it explicitly only while enrolling new nodes:

```bash
ansible-playbook site.yml \
  --tags automation_user,hardening,tailscale \
  --ask-vault-pass \
  --extra-vars @vars/tailscale.vault
```

After every node has joined, revoke the reusable auth key in the Tailscale admin
console and delete the local vault file. Normal playbook runs do not need it once
the nodes retain their own Tailscale identities.
