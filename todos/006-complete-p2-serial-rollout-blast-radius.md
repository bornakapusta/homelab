---
status: complete
priority: p2
issue_id: "006"
tags: [code-review, operations, availability, ansible]
dependencies: []
---

# `site.yml` reconfigures all three nodes simultaneously — apt upgrade, containerd restart, and sshd reload hit the whole cluster at once

## Problem Statement

`site.yml:11-13` targets `hosts: k8s_cluster` with no `serial:`, and
`ansible.cfg:10` sets `forks = 5`. With three nodes, every task runs on all three
in lockstep. Several of those tasks are disruptive:

| Task | Location | Effect on all 3 nodes at once |
|---|---|---|
| `Upgrade installed packages` | `roles/base/tasks/main.yml:31-33` | `apt upgrade: safe` — can pull a kernel, leaves all nodes reboot-pending |
| `Restart containerd` (handler) | `roles/kubernetes_node/handlers/main.yml:6-9` | every pod on every node killed simultaneously |
| `Reload sshd` (handler) | `roles/hardening/handlers/main.yml:2-5` | your only access path, changed everywhere at once |
| `Enable ufw` | `roles/hardening/tasks/main.yml:85-87` | firewall enabled on all nodes together |

For a 3-node cluster with no HA control plane (`inventory.ini:4` — Stage A is
1 CP + 2 workers), a simultaneous containerd restart is a total outage, and a
simultaneous bad sshd config is a total lockout.

## Findings

1. **The handler flush makes this concrete.**
   `roles/kubernetes_node/tasks/main.yml:53` and `:117` call
   `meta: flush_handlers`. Because roles in `site.yml` share one play, that flush
   also fires the pending `Reload sshd` and `Reload ufw` handlers from the
   `hardening` role. So all three of the disruptive handlers land mid-play, on
   every host, within the same second.
2. **`apt upgrade: safe` runs unconditionally on every `make nodes`.** The README
   and `CLAUDE.md` both describe `site.yml` as "re-run freely", which is true for
   *config* but not for *package upgrades* — every re-run is also a fleet-wide
   patch event.
3. **No reboot signalling.** Nothing checks `/var/run/reboot-required`. After a
   kernel upgrade all three nodes sit pending-reboot with no indication, and the
   correct procedure (`kubectl drain` → reboot → `uncordon`, one node at a time) is
   documented nowhere in the repo.
4. **`hardening` runs before `kubernetes_node` in the same play**, so an sshd
   misconfiguration is applied to all three nodes before any later task could
   catch it. `roles/hardening/tasks/main.yml:31-33` does run `sshd -t`
   immediately after writing the drop-in, which is a genuinely good guard — it
   fails the play *before* the handler reloads sshd. That mitigation is real, but
   it only covers syntax, not semantics (e.g. an `AllowUsers` line that is valid
   but excludes you — see `001-pending-p1-dedicated-ansible-user.md`).
5. **`cluster.yml` is fine as-is.** It splits CP and workers into separate plays
   (`cluster.yml:14-26`), which is the right shape.

## Proposed Solutions

### Option A — `serial: 1` on `site.yml`, plus a reboot-required report (recommended)

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  become: true
  serial: 1              # one node at a time — a bad change stops at node-1
  any_errors_fatal: true # do not proceed to node-2 if node-1 failed
  roles: …
```

Add at the end of the `base` role:

```yaml
- name: Check whether a reboot is pending
  ansible.builtin.stat:
    path: /var/run/reboot-required
  register: reboot_required

- name: Warn that this node needs a manual drain + reboot
  ansible.builtin.debug:
    msg: >-
      {{ inventory_hostname }} needs a reboot.
      Drain first:  kubectl drain {{ inventory_hostname }} --ignore-daemonsets --delete-emptydir-data
      Then:         sudo reboot ; kubectl uncordon {{ inventory_hostname }}
  when: reboot_required.stat.exists
```

`serial: 1` + `any_errors_fatal: true` is the key pair: it converts "all three
nodes broken" into "node-1 broken, two known-good nodes remaining".

- **Pros:** turns fleet-wide failures into single-node failures; the reboot
  warning surfaces work that is currently invisible; ~3× runtime for a 3-node
  cluster is a few minutes.
- **Cons:** `site.yml` takes roughly 3× as long. `serial: 1` also means the
  `node_ips`-based ufw rules (`roles/hardening/tasks/main.yml:63-67`) are applied
  progressively — harmless, since `node_ips` comes from inventory
  (`group_vars/all.yml:15`), not from live facts.
- **Effort:** Small. **Risk:** Low.

### Option B — split the disruptive parts into a separate playbook

Keep `site.yml` non-disruptive (config only) and move `apt upgrade` + any
service restarts into a `patch.yml` with `serial: 1` and explicit drain/uncordon
tasks.

- **Pros:** cleanest separation; `site.yml` genuinely becomes "run freely"; the
  drain/reboot/uncordon cycle gets automated where it belongs.
- **Cons:** a fourth playbook and a new `make patch` target; two places to keep
  in sync; more machinery than a 3-node homelab strictly needs today.
- **Effort:** Medium. **Risk:** Low.

### Option C — `serial: 1` only, skip the reboot reporting

- **Pros:** one-line change.
- **Cons:** leaves finding 3 unaddressed — nodes silently accumulate pending
  kernel upgrades and you find out during an unrelated incident.
- **Effort:** Trivial. **Risk:** Low.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/site.yml:11-13` — add `serial: 1`, `any_errors_fatal: true`
- `ansible/roles/base/tasks/main.yml:31-33` — the unconditional upgrade
- `ansible/roles/base/tasks/main.yml` (end) — reboot-required check
- `ansible/roles/kubernetes_node/tasks/main.yml:53,117` — `flush_handlers` calls that pull `hardening`'s handlers forward
- `CLAUDE.md` — document that `make nodes` is also a patch event, and the drain/reboot procedure
- `Makefile:9-11` — consider a `make patch` target if Option B

**Ordering subtlety worth preserving:** the `flush_handlers` at
`roles/kubernetes_node/tasks/main.yml:53` exists so sysctls apply before containerd
starts, and at `:117` so containerd restarts before it is enabled. Both are
correct and deliberate. Do not remove them — `serial: 1` addresses the blast
radius without touching the intra-host ordering.

## Acceptance Criteria

- [ ] `site.yml` runs one host at a time; a forced failure on node-1 leaves node-2 and node-3 untouched
- [ ] A pending reboot on any node is reported at the end of the run with the drain command
- [ ] `CLAUDE.md` documents that `make nodes` performs an apt upgrade
- [ ] Manual drain → reboot → uncordon procedure documented for a 1-CP cluster (note: draining the CP is different)
- [ ] `make nodes` on a converged cluster still reports zero changes

## Work Log

- 2026-07-26 — RESOLVED in the same session. site.yml is now serial: 1 + any_errors_fatal: true. Added pending-reboot detection to the base role reporting the drain/reboot/uncordon sequence. cluster.yml's first play also got any_errors_fatal.
- 2026-07-26 — Filed from `/ce-review`. Confirmed the `flush_handlers` cross-role
  interaction by reading role order in `site.yml:15-23` against the flush points in
  `kubernetes_node`.

## Resources

- `ansible/site.yml` — single play, all hosts
- `ansible/cluster.yml:14-26` — correctly split plays, for contrast
- Related: `001-pending-p1-dedicated-ansible-user.md` (sshd lockout is the worst case here)
