# tailscale

Pinned Tailscale installation and management-plane enrolment. The role installs
the exact package version from Tailscale's signed apt repository, holds it,
configures the UDP transport port, and enrols a node only when it has no
Tailscale IPv4 address.

**Unit of automation:** one node's management VPN identity. **Outcome:** an
enrolled node whose tailnet traffic is filtered by UFW rather than Tailscale's
own netfilter chains.

| Property | Value |
|---|---|
| Idempotent | **True** |
| Atomic | **False** — package/repository changes remain if enrolment fails |
| Check mode | Repository/config and package-change prediction only; APT resolution, systemd, and live CLI are skipped |

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

- `tailscale_enabled` — enables the role; defaults to `false`.
- `tailscale_apt_version` — exact apt version installed and held.
- `tailscale_key_sha256` — checksum pin for the suite-specific repository key.
- `tailscale_udp_port` — local UDP transport port, also opened by `hardening`.
- `tailscale_auth_key` — optional bootstrap-only secret required for a new node.

The source list and `/etc/default/tailscaled` carry the role's deterministic
`Ansible managed` header and are written with `backup: true`. The downloaded
OpenPGP keyring is the one narrow no-header exception because it is binary; it
is checksum-pinned and also written with `backup: true`.

On a first-run dry run, APT cannot resolve a package from a repository whose
creation and cache refresh are themselves only simulated. The role therefore
predicts the package change by comparing the installed `dpkg` version with the
pin. The following live run performs and verifies the real repository-backed
installation.

`tailscale_apt_version` is pinned to the official package in
`group_vars/all.yml`. The independently verified package SHA256 is documented
there, but apt's repository signature plus the checksum-pinned signing key are
the installation trust boundary.

## Why netfilter mode is off

Tailscale's default netfilter mode installs an early accept for `tailscale0`.
That can bypass UFW's management-only policy and expose services beyond SSH.
This role therefore uses `--netfilter-mode=off` for new nodes, repairs enrolled
nodes with `tailscale set --netfilter-mode=off`, and verifies numeric
`NetfilterMode == 0`. The `hardening` role owns all firewall rules and must run
first.

## Bootstrap and rollout

Create the ignored encrypted file from the `ansible/` directory:

```bash
ansible-vault create vars/tailscale.vault
# In the encrypted editor only:
# tailscale_auth_key: "..."
```

Roll out the automation account, firewall, and Tailscale in that safe order:

```bash
ansible-playbook site.yml \
  --tags automation_user,hardening,tailscale \
  --ask-vault-pass \
  --extra-vars @vars/tailscale.vault
```

The role removes a stale `/run/tailscale-auth.key` before inspecting state,
waits for the LocalAPI, stages the secret with mode `0600`, and removes it even
when enrolment fails. Once every node is enrolled, revoke the reusable auth key
in the admin console and delete the local vault file.

Mandatory live checks from a different tailnet peer after each node rolls out:

```bash
ssh ansible@<node-tailscale-ip> true        # must succeed
nc -vz <node-tailscale-ip> 80               # must fail
nc -vz <node-tailscale-ip> 443              # must fail
```

Do not treat static checks or container Molecule as a substitute for these peer
tests: they cannot prove the live packet path through `tailscale0` and UFW.

## Rollback

```bash
# Restore Tailscale's own firewall management if UFW is being removed.
sudo tailscale set --netfilter-mode=on

# Or remove this node from the management VPN entirely.
sudo tailscale logout
sudo systemctl disable --now tailscaled
sudo apt-mark unhold tailscale
sudo apt-get remove tailscale
sudo rm /etc/apt/sources.list.d/tailscale.list
sudo rm /usr/share/keyrings/tailscale-archive-keyring.gpg
```

Also remove the machine from the Tailscale admin console. Restoring a backed-up
source list or `/etc/default/tailscaled` file requires restarting `tailscaled`.

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    - role: hardening
      tags: [hardening]
    - role: tailscale
      tags: [tailscale]
```
