# hardening

SSH lockdown, host firewall, automatic security patching.

**Unit of automation:** one machine's exposure. **Outcome:** key-only SSH from
approved networks, a default-deny firewall that still forwards pod traffic, and
unattended security upgrades that never reboot on their own.

> **This is the role that can lock you out of every node at once.** It writes
> sshd's `AllowUsers` and reloads sshd on all three machines. Read the arguments
> section before changing `ssh_allowed_users`.

| Property | Value |
|---|---|
| Idempotent | **True** — verified by `make test` |
| Atomic | **False** |
| Check mode | Supported |
| Tested | Yes — `make test` (Molecule, see below) |

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).
All three are required, with no defaults on purpose: a plausible-looking default
for any of them would silently harden the wrong thing.

- `ssh_allowed_users` — rendered into sshd's `AllowUsers`. **Must** contain the
  account Ansible connects as, plus both `admin_user` and
  `ansible_service_user`. Dropping any of them locks that account out of every
  node on the next reload. The `preflight` role asserts exactly this, and the
  Molecule scenario asserts it again against a real sshd.
- `ssh_allowed_from` — source networks for port 22, and for ingress 80/443.
- `node_ips` — peer addresses trusted wholesale by ufw. Kubernetes needs a wide
  range of inter-node ports (6443, 2379-2380, 10250, 30000-32767, plus CNI);
  allowing the peers outright is less fragile than hand-punching each one.

## Two details that are load-bearing

**`DEFAULT_FORWARD_POLICY="ACCEPT"`.** ufw defaults to DROP on the FORWARD chain,
which silently breaks pod-to-pod networking — the symptom is random pod timeouts
with a firewall that looks correctly configured. The Molecule scenario asserts
this line specifically.

**`sshd -t` before any reload.** The config is validated while the old daemon is
still running, so a bad drop-in fails the run instead of reloading a config that
refuses your key. Note that the actual reload is triggered by the play-global
`meta: flush_handlers` inside the `kubernetes_node` role — see the comment there.

## Rollback

Every file this role writes is written with `backup: true`, so the previous
version sits beside the live one. Backup names contain dots and end in `~`, which
means sshd's `Include *.conf`, apt's config reader, and sudo all ignore them.

From a console session (not SSH, in case you are locked out):

```bash
# restore the previous sshd drop-in
sudo cp /etc/ssh/sshd_config.d/99-hardening.conf.*~ \
        /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh

# or drop the hardening entirely
sudo rm /etc/ssh/sshd_config.d/99-hardening.conf
sudo systemctl reload ssh

sudo ufw disable                 # firewall off
```

Files this role **replaces** wholesale rather than edits:
`/etc/ssh/sshd_config.d/99-hardening.conf`,
`/etc/apt/apt.conf.d/20auto-upgrades`, `/etc/apt/apt.conf.d/51-no-auto-reboot`.
It *edits* `/etc/default/ufw` in place. All carry an `Ansible managed` header.

## Testing

```bash
make test        # molecule test -s hardening
```

The scenario runs the role verbatim against an Ubuntu 26.04 container with real
systemd as PID 1 — no mocked handlers — then checks idempotency and asserts on
the resulting sshd, apt, and ufw state, including that `backup: true` actually
produced a recoverable copy. See [`../../molecule/hardening/`](../../molecule/hardening/).

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    # automation_user MUST come first — see that role's README.
    - role: hardening
      tags: [hardening]
  vars:
    ssh_allowed_users: [borna, ansible]
    ssh_allowed_from: ["192.0.2.0/24"]
    node_ips: ["198.51.100.10", "198.51.100.11"]
```
