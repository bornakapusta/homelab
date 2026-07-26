---
status: ready
priority: p1
issue_id: "001"
tags: [code-review, security, ansible, operations]
dependencies: []
---

# Add a dedicated `ansible` automation user (lockout-safe rollout)

## Problem Statement

Ansible currently connects as the human admin account:

- `ansible/group_vars/all.yml:7-8` — `admin_user: borna`, `ansible_user: "{{ admin_user }}"`
- `autoinstall/user-data.example:79` — `borna ALL=(ALL) NOPASSWD:ALL`

So one identity is simultaneously: the interactive login, the SSH key you carry on
your laptop, the passwordless-root path on all three nodes, and (after
`control_plane`) the owner of a cluster-admin kubeconfig at
`/home/borna/.kube/config`.

Consequences:

- **No separation of audit trail.** `sudo` logs and `auth.log` cannot distinguish
  "Borna typed a command" from "a playbook ran". On a 3-node cluster that is the
  only forensic record you have.
- **Key rotation is coupled to the human account.** Rotating the automation key
  means touching your own login; revoking a compromised automation key locks you
  out of your own machines.
- **Blast radius.** Anything that reads `~/.ssh/id_ed25519` on the laptop gets
  passwordless root on all three nodes *and* cluster-admin.
- **Fragility.** The automation path depends on the human account's shell,
  dotfiles, and `authorized_keys` staying intact.

## Findings

**Honest framing first:** a dedicated `ansible` user that also holds
`NOPASSWD:ALL` is *not* a meaningful reduction in privilege. Ansible executes
arbitrary Python modules as root; command-limited sudoers is not workable. The
real wins are **separation, rotation, and auditability**, plus the ability to
restrict the automation key by source address. Do not sell this to yourself as
"hardening" — it is operational hygiene, and it is worth doing for that reason.

**The dangerous part is the rollout, not the user.** Two existing tasks will lock
you out of all three nodes at once if the ordering is wrong:

1. `roles/hardening/tasks/main.yml:28` — `AllowUsers {{ admin_user }}`.
   If you flip `ansible_user` to `ansible` *before* this line lists the new user,
   the next `site.yml` run reloads sshd and the `ansible` user can no longer log
   in. All three nodes, simultaneously (`forks = 5`, no `serial`).
2. Any new `/etc/sudoers.d/` file written **without** `validate:` can render
   `sudo` unusable machine-wide. There is currently no sudoers task in the repo,
   so this is a hazard introduced *by* this change.

Also note `roles/hardening/tasks/main.yml:17` sets `PasswordAuthentication no`,
so the new user is unreachable until its public key is in place — the ordering
below accounts for that.

## Proposed Solutions

### Option A — dedicated user, two-variable rollout, human kept as break-glass (recommended)

Introduce two distinct variables instead of overloading `admin_user`:

```yaml
# group_vars/all.yml
admin_user: borna            # interactive human login; keeps a shell
ansible_service_user: ansible # automation only; nologin-ish, no password
ansible_user: "{{ admin_user }}"  # flip to ansible_service_user in step 4
ssh_allowed_users:
  - "{{ admin_user }}"
  - "{{ ansible_service_user }}"
```

Then `roles/hardening/tasks/main.yml:28` becomes
`AllowUsers {{ ssh_allowed_users | join(' ') }}`.

New role `roles/ansible_user` (runs in `site.yml` **before** `hardening`):

```yaml
- name: Create the automation user
  ansible.builtin.user:
    name: "{{ ansible_service_user }}"
    shell: /bin/bash          # NOT nologin — become/pipelining needs a shell
    create_home: true
    password: "!"             # locked: no password login, ever
    state: present

- name: Install the automation public key
  ansible.posix.authorized_key:
    user: "{{ ansible_service_user }}"
    key: "{{ lookup('file', ansible_service_pubkey) }}"
    key_options: 'from="192.168.178.0/24",no-port-forwarding,no-agent-forwarding,no-X11-forwarding'
    exclusive: true

- name: Grant passwordless sudo to the automation user
  ansible.builtin.copy:
    dest: "/etc/sudoers.d/90-{{ ansible_service_user }}"
    owner: root
    group: root
    mode: "0440"
    content: "{{ ansible_service_user }} ALL=(ALL) NOPASSWD:ALL\n"
    validate: "visudo -cf %s"   # NON-NEGOTIABLE — prevents cluster-wide lockout
```

Rollout order (each step is one `make nodes` run, verified before the next):

1. Generate a **separate** keypair on the laptop:
   `ssh-keygen -t ed25519 -f ~/.ssh/homelab_ansible -C "ansible@homelab"`.
   Set `ansible_service_pubkey: ~/.ssh/homelab_ansible.pub`.
2. Run `site.yml` **as `borna`** with the new role + the `ssh_allowed_users`
   change. Both users are now permitted by sshd; nothing has switched yet.
3. Verify by hand, on every node, before changing anything:
   `ssh -i ~/.ssh/homelab_ansible ansible@node-1 sudo -n true`
4. Only then flip `ansible_user: "{{ ansible_service_user }}"` and add
   `ansible_ssh_private_key_file` (or a `~/.ssh/config` Host block). Re-run
   `make ping`.
5. Optionally tighten `borna`: replace `NOPASSWD:ALL` with password-required
   sudo. `borna` stays your break-glass account — keep its shell and key.

Note `no_prompt`/`no-pty` must **not** be added to `key_options`: Ansible's
`sudo` become plugin needs a pty in some configurations, and pipelining is
enabled in `ansible.cfg:21`.

- **Pros:** never a moment where the connecting user is not in `AllowUsers`;
  human retains independent access; keys rotate independently; `visudo`
  validation closes the lockout hole.
- **Cons:** ~40 lines of new role; two keys to manage; 4-step rollout.
- **Effort:** Medium. **Risk:** Low if the steps are done in order.

### Option B — keep `borna`, drop `NOPASSWD`, use a vaulted become password

Leave the single user; store the sudo password in `ansible-vault` and set
`become_ask_pass = False` + `ansible_become_password` from vault.

- **Pros:** no new user; a stolen SSH key alone no longer grants root.
- **Cons:** solves none of the audit/rotation problems; introduces a vault
  password you must now manage; the sudo password ends up in a file on the
  laptop anyway, so the gain is thinner than it looks.
- **Effort:** Small. **Risk:** Low.

### Option C — create the user in `autoinstall/user-data` instead of via Ansible

- **Pros:** the automation user exists from first boot; no bootstrap-as-human phase.
- **Cons:** node-1 is already installed interactively, so it needs the Ansible
  path regardless; drifts the two provisioning mechanisms; re-imaging becomes the
  only way to change the automation user.
- **Effort:** Small. **Risk:** Medium (nodes end up inconsistent).

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/group_vars/all.yml` — add `ansible_service_user`, `ssh_allowed_users`, `ansible_service_pubkey`
- `ansible/roles/hardening/tasks/main.yml:28` — `AllowUsers` from the list
- `ansible/roles/ansible_user/` — new role (tasks, defaults, meta)
- `ansible/site.yml` — insert `ansible_user` role before `hardening`
- `autoinstall/user-data.example:75-80` — document that the automation user is
  Ansible-managed, not autoinstall-managed
- `ansible/requirements.yml` — add `ansible.posix` (needed for `authorized_key`)
- `CLAUDE.md` — document the two-user model and the break-glass account

**Interaction with `control_plane`:** `roles/control_plane/tasks/main.yml:24-39`
copies the cluster-admin kubeconfig to `/home/{{ admin_user }}/.kube/config`.
Keep that pointed at the **human** user. The automation user does not need a
persistent kubeconfig — the roles already use
`KUBECONFIG=/etc/kubernetes/admin.conf` via `environment:`.

## Acceptance Criteria

- [ ] `ansible` user exists on all three nodes with a locked password (`passwd -S ansible` shows `L`)
- [ ] `ssh -i ~/.ssh/homelab_ansible ansible@<each node> sudo -n true` succeeds
- [ ] `borna` can still log in and `sudo` after the switch (break-glass verified)
- [ ] `/etc/sudoers.d/90-ansible` is mode `0440`, root:root, and was written with `validate: visudo -cf %s`
- [ ] sshd `AllowUsers` lists both users; `sshd -t` passes
- [ ] `make ping` and `make nodes` both pass with `ansible_user: ansible`
- [ ] Password auth still disabled; the automation key is `from=`-restricted
- [ ] Automation private key is **not** in the repo and matches a `.gitignore` rule

## Work Log

- 2026-07-26 — RESOLVED in the same session. Implemented: new `automation_user` role (locked password, from=-restricted key via ansible.posix.authorized_key, sudoers written with `validate: visudo -cf %s`); `ssh_allowed_users` drives sshd AllowUsers; preflight refuses to run if the connecting user is not on that list. NOT yet switched: `ansible_user` still points at admin_user. Remaining manual steps are in group_vars/all.yml (ssh-keygen, verify, then flip). Status ready, not complete.
- 2026-07-26 — Filed from `/ce-review`. Explicitly requested by the user alongside
  the review. Key insight: the user itself is easy; the sshd `AllowUsers` +
  sudoers ordering is what can brick all three nodes at once.

## Resources

- `ansible/roles/hardening/tasks/main.yml:8-33` — sshd drop-in and `sshd -t` validation
- `autoinstall/user-data.example:75-80` — current NOPASSWD grant
- Related: `006-pending-p2-serial-rollout-blast-radius.md` (no `serial:` means
  sshd changes land on all nodes simultaneously)
