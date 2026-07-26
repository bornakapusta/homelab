---
status: pending
priority: p2
issue_id: "017"
tags: [code-review, security, networking, ansible, supply-chain]
dependencies: []
---

# The Tailscale block installs an unverified script, and ufw still blocks SSH over the tailnet

## Problem Statement

A Tailscale section was added to `roles/base/tasks/main.yml` with the stated goal:
"Install Tailscale so nodes are reachable from anywhere via 100.x.x.x."

As written, that goal is not achieved, and the block departs from three conventions
the rest of the repo follows carefully.

**The functional gap:** `roles/hardening/tasks/main.yml` allows SSH only from
`ssh_allowed_from`, which is `[192.168.178.0/24]` — the tailnet range
`100.64.0.0/10` is present but **commented out** in `group_vars/all.yml`. So
Tailscale comes up, the node gets a 100.x address, and ufw drops SSH to it. Remote
access silently does not work.

## Findings

1. **Already fixed during the review pass:** `tailscale up --authkey=...` had no
   `no_log`, so the auth key was echoed into terminal scrollback with the command.
   `no_log: true` has been added. Listed here for the record.
2. **The install script is fetched without verification.** Every other remote
   artefact in this repo is checksum-pinned — two apt signing keys and the Calico
   manifest, all three verified against upstream. This block does
   `get_url` → `command: /tmp/tailscale-install.sh` with no `checksum:`, then
   executes it as root. That is the single least-verified thing on the node, and it
   runs with the most privilege.
3. **Download location and hygiene differ from convention.** The Calico manifest is
   downloaded to `/root/` with mode `0600` and deleted after use
   (`roles/control_plane/tasks/main.yml`). This writes to `/tmp` with mode `0755`
   and never cleans up. `/tmp` is world-readable and world-traversable; a
   `0755` root-owned script sitting there permanently is avoidable.
4. **`tailscale_auth_key` has no home.** It is referenced via
   `| default('')` but is not declared in `group_vars/all.yml` or any role
   defaults, so the block silently no-ops. A Tailscale auth key is a credential
   that grants tailnet membership — it belongs in `ansible-vault`, not in plain
   group_vars, and definitely not on the command line of a shell history.
5. **`Enable tailscaled` can fail on a fresh node.** Its condition is
   `ts_installed.rc == 0 or tailscale_auth_key | ... > 0`. With an auth key set on
   a node where install *just* happened this is fine, but if the auth key is set
   and the install block failed, the task still runs and errors on a missing unit.
   Minor, but `failed_when` / a re-check would be tidier.
6. **Reachability from the tailnet interacts with the ufw peer rules.**
   `node_ips` derives from `ansible_host` (LAN addresses), and the ufw rules trust
   those wholesale. Tailscale traffic arrives on `tailscale0` from 100.x, which is
   not covered — intentional for pod traffic, but it means the tailnet is
   management-plane only. Worth stating explicitly so it is not mistaken for a
   second cluster network later.

## Proposed Solutions

### Option A — install from Tailscale's apt repo, vault the key, open the tailnet (recommended)

Replace the script with the same pinned-apt-repo pattern the rest of the repo uses
for Docker and Kubernetes:

```yaml
- name: Add Tailscale GPG key
  ansible.builtin.get_url:
    url: https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
    dest: /etc/apt/keyrings/tailscale.gpg
    mode: "0644"
    checksum: "sha256:{{ tailscale_key_sha256 }}"

- name: Add Tailscale apt repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [signed-by=/etc/apt/keyrings/tailscale.gpg]
      https://pkgs.tailscale.com/stable/ubuntu {{ ansible_distribution_release }} main
    filename: tailscale
    state: present

- name: Install Tailscale
  ansible.builtin.apt:
    name: tailscale
    state: present
    update_cache: true
    cache_valid_time: 3600
```

Then uncomment the tailnet in `group_vars/all.yml` so ufw actually permits it:

```yaml
ssh_allowed_from:
  - 192.168.178.0/24
  - 100.64.0.0/10
```

Note this also widens the automation key's `from=` restriction (it is built from
`ssh_allowed_from` in `roles/automation_user/defaults/main.yml`), which is the
correct behaviour — the automation account should be usable over the tailnet.

And store the key encrypted:

```bash
ansible-vault create ansible/group_vars/all/vault.yml   # tailscale_auth_key: tskey-...
```

- **Pros:** verified, signed packages instead of an unverified root-executed
  script; consistent with the two apt repos already configured; upgrades come
  through apt like everything else; remote access actually works.
- **Cons:** needs the Tailscale key digest verified out-of-band; introduces a vault
  password to manage; a third apt repo.
- **Effort:** Medium. **Risk:** Low.

### Option B — keep the script, add a checksum and fix hygiene

Pin the install script's digest, download to `/root/` at `0600`, delete afterwards,
and uncomment the tailnet CIDR.

- **Pros:** much smaller diff; closes the verification hole and the functional gap.
- **Cons:** Tailscale updates the script, so the pin will break on a schedule you
  do not control — the same rotation problem flagged for the Docker key in `002`,
  but on a script rather than a keyring. Also leaves Tailscale outside apt, so it
  never gets patched by `unattended-upgrades`.
- **Effort:** Small. **Risk:** Medium.

### Option C — remove the Tailscale block

- **Pros:** returns `base` to LAN-only; one less moving part before the cluster
  even exists.
- **Cons:** loses remote access, which is a reasonable thing to want for a homelab
  you are not always sitting next to.
- **Effort:** Trivial. **Risk:** Low.

## Recommended Action

_(fill during triage)_

**Decide the ufw question either way.** Whichever install method is chosen, leaving
`100.64.0.0/10` commented out while running Tailscale means the feature is
installed but unreachable — the worst of both worlds.

## Technical Details

**Affected files:**
- `ansible/roles/base/tasks/main.yml` — the Tailscale block (`no_log` already applied)
- `ansible/group_vars/all.yml` — `ssh_allowed_from` tailnet entry; `tailscale_key_sha256`
- `ansible/group_vars/all/vault.yml` — new, for `tailscale_auth_key`
- `ansible/roles/base/defaults/main.yml` — document `tailscale_auth_key` as optional
- `ansible/roles/preflight/tasks/main.yml` — could assert that if Tailscale is
  enabled, the tailnet CIDR is in `ssh_allowed_from`
- `CLAUDE.md` — document that the tailnet is management-plane only

## Acceptance Criteria

- [ ] Tailscale installed from a verified source (signed apt repo, or a pinned digest)
- [ ] Nothing root-executable left behind in `/tmp`
- [ ] `tailscale_auth_key` stored in ansible-vault, not plain group_vars
- [ ] `no_log: true` on the `tailscale up` task (done)
- [ ] `ssh -i ~/.ssh/homelab_ansible ansible@100.x.y.z` succeeds from off-LAN
- [ ] `sudo ufw status` shows the tailnet range permitted for 22/tcp
- [ ] `make nodes` is idempotent across two runs with Tailscale already authenticated
- [ ] A run with no `tailscale_auth_key` set still succeeds and skips cleanly

## Work Log

- 2026-07-26 — Filed from `/ce-review`. This block was added to `roles/base` while
  the review's fixes were being applied, so it was not part of the original 15
  findings. `no_log: true` applied immediately (auth-key leak); the rest left as-is
  rather than restructuring newly-written code unasked.

## Resources

- `ansible/roles/control_plane/tasks/main.yml` — the download-verify-cleanup pattern to mirror
- `ansible/roles/kubernetes_node/tasks/main.yml` — the pinned-apt-repo pattern to mirror
- `ansible/roles/automation_user/defaults/main.yml` — `from=` derives from `ssh_allowed_from`
- Related: `002-pending-p1-unverified-pinned-checksums.md` — same supply-chain concern
