---
status: complete
priority: p2
issue_id: "009"
tags: [code-review, security, ansible]
dependencies: []
---

# `host_key_checking = False` leaves every playbook run MITM-able on the WiFi link

## Problem Statement

`ansible/ansible.cfg:3-5`:

```ini
# WARNING: disables SSH host-key verification (MITM risk on WiFi).
# After first provisioning, populate known_hosts and set to True.
host_key_checking = False
```

The risk is correctly identified and the remediation is correctly described — but
nothing implements it, and nothing forces the follow-up. Meanwhile every
`make nodes` run pushes root-level configuration, apt signing keys, and (per
`001-pending-p1-dedicated-ansible-user.md`) sudoers files to hosts whose identity
is never verified.

## Findings

1. **Compounding factor:** `roles/kubernetes_node/tasks/main.yml:63-68` and
   `:126-131` fetch **apt signing keys** over these connections. The pinned
   checksums (see `002-pending-p1-unverified-pinned-checksums.md`) are what stop a
   substituted key — but those digests are themselves unverified, so right now
   there are two mitigations and neither is actually in force.
2. **This is a homelab on a trusted LAN**, which is why P2 rather than P1 is right.
   An attacker needs to already be on the WiFi. That is a real bar.
3. **It is a self-clearing problem.** The remediation costs about five minutes,
   once, and the comment already says what to do. Leaving a known-hole-with-a-TODO
   in a repo with zero commits is how it becomes permanent.
4. **Ansible has a middle setting.** `host_key_checking = True` combined with
   `ANSIBLE_HOST_KEY_AUTO_ADD` / `StrictHostKeyChecking=accept-new` gives
   trust-on-first-use: unknown hosts are accepted and pinned, but a **changed** key
   aborts. That is the pragmatic setting for a homelab, and it catches the case
   that actually matters (someone impersonating a node you already know).
5. `ansible.cfg:22` sets `ControlMaster=auto ControlPersist=60s`, so connections
   are multiplexed — host key verification happens once per 60 s window, not per
   task. Enabling it costs essentially nothing in runtime.

## Proposed Solutions

### Option A — populate `known_hosts` from the console, then enable checking (recommended)

Get each node's fingerprint from a channel that is not the network — the physical
console of each machine:

```bash
# on each node, at the keyboard:
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Then on the laptop, `ssh-keyscan` and **compare** before trusting:

```bash
for h in 192.168.178.26 192.168.178.27 192.168.178.28; do
  ssh-keyscan -t ed25519 "$h" 2>/dev/null | tee -a ~/.ssh/known_hosts
done
ssh-keygen -lf ~/.ssh/known_hosts   # compare against the console output
```

Then in `ansible.cfg`:

```ini
host_key_checking = True
```

The console comparison is the part that makes this real. `ssh-keyscan` alone
trusts the same network you are trying to protect — it pins whatever answers,
which prevents *future* MITM but not a MITM that is already in place.

- **Pros:** actual verification; future key changes abort loudly; the comment's
  stated plan gets executed.
- **Cons:** one physical visit per node (you have three, on your desk); re-imaging
  a node requires removing the stale entry (`ssh-keygen -R <ip>`).
- **Effort:** Small. **Risk:** Low.

### Option B — trust-on-first-use via `accept-new`

```ini
host_key_checking = True

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=accept-new
```

- **Pros:** no console visit; no manual `known_hosts` seeding; still catches a
  changed key on any subsequent run, which is the realistic attack.
- **Cons:** the *first* connection to each node is unverified — so if an attacker
  is already on the LAN before you first provision, they win silently.
- **Effort:** Trivial. **Risk:** Low-Medium.

### Option C — leave as-is

- **Pros:** nothing to do; the WARNING comment is honest about the trade-off.
- **Cons:** the hole is permanent in practice, and it undermines the checksum
  pinning that the repo already went to the trouble of adding. Inconsistent
  threat model.
- **Effort:** None. **Risk:** Medium.

## Recommended Action

_(fill during triage)_

Reasonable compromise: Option B now (one line, immediate improvement), Option A's
console verification when you are next physically at the machines.

## Technical Details

**Affected files:**
- `ansible/ansible.cfg:3-5` — the setting and its warning comment
- `ansible/ansible.cfg:20-22` — `ssh_args`, where `StrictHostKeyChecking` would go
- `README.md` / `CLAUDE.md` — document the `known_hosts` seeding step, and the
  `ssh-keygen -R` step for re-imaged nodes
- `Makefile` — a `make trust` target could wrap the keyscan+compare flow

**Interaction with re-imaging:** `autoinstall/user-data.example` describes
installing nodes 2 and 3 from USB. Each re-image regenerates host keys, so
whichever option is chosen needs a documented "node was re-imaged" procedure or the
next run fails confusingly.

## Acceptance Criteria

- [ ] `host_key_checking = True` in `ansible.cfg` (with or without `accept-new`)
- [ ] `make ping` succeeds against all three nodes with checking enabled
- [ ] If Option A: fingerprints compared against console output, and that step is documented
- [ ] Re-imaging procedure documented (`ssh-keygen -R <ip>` before re-provisioning)
- [ ] The `# WARNING` comment in `ansible.cfg` updated or removed to match reality

## Work Log

- 2026-07-26 — RESOLVED in the same session. Applied Option B: host_key_checking = True with StrictHostKeyChecking=accept-new (trust-on-first-use — a CHANGED key now aborts). Option A's console-fingerprint verification documented in ansible.cfg along with the ssh-keygen -R step for re-imaged nodes. Residual: the very first connection to each node is still unverified.
- 2026-07-26 — Filed from `/ce-review`. Kept at P2 rather than P1: the risk is
  acknowledged in-repo and requires LAN presence. Filed anyway because an
  acknowledged hole with an unexecuted TODO is still a hole, and because it
  undermines the checksum pinning in `002`.

## Resources

- `ansible/ansible.cfg:1-9`
- Related: `002-pending-p1-unverified-pinned-checksums.md` — same threat model, same channel
- Related: `001-pending-p1-dedicated-ansible-user.md` — a `from=`-restricted automation key raises the bar further
