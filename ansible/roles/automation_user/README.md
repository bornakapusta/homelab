# automation_user

Creates the dedicated `ansible` automation account: its own SSH key, a locked
password, and a validated sudoers drop-in.

**Unit of automation:** one service account on one machine. **Outcome:** an
account Ansible can log into with a key that is distinct from your personal one.

## What this does and does not buy you

**Does:** an SSH key that rotates independently of your human login; auth and
sudo logs that distinguish "a playbook ran" from "a person typed something"; a
key restricted by source address via `from=`.

**Does not:** reduced privilege. Ansible executes arbitrary Python modules as
root, so this account holds `NOPASSWD:ALL` exactly like `admin_user` does. This is
separation for audit and key rotation, **not** privilege reduction. Do not read
the two-user model as a security boundary between them.

| Property | Value |
|---|---|
| Idempotent | **True** |
| Atomic | **False** |
| Check mode | Supported |

## Ordering requirement

**Must run before the `hardening` role.** The account has to exist and be listed
in sshd's `AllowUsers` before `hardening` reloads sshd. Reversing the order locks
the new account out of every node.

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

Required: `ansible_service_user`, `ansible_service_pubkey`, `ssh_allowed_from`.
Optional: `automation_user_key_options` (see `defaults/main.yml`).

`ansible_service_pubkey` is a path **on the controller**, not on the node. The
role fails with instructions if it does not exist; generate one with:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab_ansible -C "ansible@homelab"
```

The key is installed with `exclusive: true` — exactly one key may authenticate
this account, so a stale key left behind cannot become an unnoticed way in.

## Rollback

```bash
sudo rm /etc/sudoers.d/90-ansible        # a .bak~ copy sits beside it
sudo userdel -r ansible
```

Then remove the account from `ssh_allowed_users` and re-run the `hardening` role.
Do this **before** switching `ansible_user` back, or the next run cannot connect.

Anything writing to `/etc/sudoers.d/` in this role uses `validate: visudo -cf %s`
and `backup: true`. A malformed sudoers file makes `sudo` unusable on every node
at once, so neither is optional.

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    # Before hardening, always.
    - role: automation_user
      tags: [automation_user, users]
```
