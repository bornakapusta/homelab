---
status: complete
priority: p3
issue_id: "010"
tags: [code-review, quality, developer-experience, ansible]
dependencies: []
---

# Role defaults are comment-only, so a missing or wrong variable fails late and cryptically

## Problem Statement

Every role's `defaults/main.yml` documents required variables as comments rather
than providing values or validating them:

- `roles/hardening/defaults/main.yml` — `# admin_user: (required)`, `# node_ips: (required)`, `# ssh_allowed_from: (required)`
- `roles/control_plane/defaults/main.yml` — `# admin_user:`, `# control_plane_endpoint:`, `# pod_cidr:`, `# calico_version:`
- `roles/kubernetes_node/defaults/main.yml` — `# kubernetes_minor:`, `# kubernetes_apt_version:`
- `roles/worker/defaults/main.yml` — none needed

Documenting requirements is good. But nothing enforces them, so a typo in
`group_vars/all.yml` surfaces as an undefined-variable error deep inside a role —
or worse, as a semantically valid but wrong value that only shows up after
`kubeadm init` has baked it into certificates.

## Findings

1. **The highest-value assertion is not about definedness at all.**
   `group_vars/all.yml:28-32` warns that `pod_cidr` must not overlap the home LAN,
   and that Calico's default `192.168.0.0/16` *would* collide with
   `192.168.178.0/24`. That is exactly the kind of constraint an `assert` should
   enforce — the comment even says "Do not change this to 192.168.x", which is a
   rule expressed as a plea.
2. **Some values are unrecoverable once used.** `control_plane_endpoint` and
   `pod_cidr` are written into certificates and CNI config by
   `roles/control_plane/tasks/main.yml:12-18`. Catching a mistake before
   `kubeadm init` costs nothing; catching it after costs a `kubeadm reset` on all
   three nodes.
3. **`node_ips` is a derived expression** (`group_vars/all.yml:15`), so it fails at
   *use* time, not parse time. If `ansible_host` is missing for any inventory host,
   the failure appears inside the ufw loop at
   `roles/hardening/tasks/main.yml:63-67` with a Jinja traceback rather than
   "node-3 has no ansible_host".
4. **Version strings are already flagged as needing checks.**
   `group_vars/all.yml:35` says "CHECK THESE BEFORE YOUR FIRST RUN". An assert that
   `kubernetes_apt_version` starts with `kubernetes_minor` catches the most likely
   mistake — bumping one and forgetting the other — which is also the mistake that
   breaks the pinned checksum in `002-pending-p1-unverified-pinned-checksums.md`.
5. `ansible.builtin.assert` with `quiet: true` costs no meaningful runtime and adds
   no dependencies.

## Proposed Solutions

### Option A — a `preflight` role at the top of `site.yml` (recommended)

```yaml
# roles/preflight/tasks/main.yml
- name: Required variables are set
  ansible.builtin.assert:
    that:
      - admin_user is defined and admin_user | length > 0
      - timezone is defined
      - control_plane_endpoint is defined
      - pod_cidr is defined
      - kubernetes_minor is defined
      - kubernetes_apt_version is defined
      - calico_version is defined
      - ssh_allowed_from | default([]) | length > 0
    quiet: true
    fail_msg: "A required variable in group_vars/all.yml is missing or empty."

- name: control_plane_endpoint must be a DNS name, not an IP
  ansible.builtin.assert:
    that:
      - control_plane_endpoint is not match('^\d+\.\d+\.\d+\.\d+$')
    fail_msg: >-
      control_plane_endpoint must be a NAME so extra control-plane nodes can be
      added later without regenerating certificates. See group_vars/all.yml.

- name: Pinned kube version must match the pinned minor
  ansible.builtin.assert:
    that:
      - kubernetes_apt_version is match('^' ~ (kubernetes_minor | regex_escape) ~ '\.')
    fail_msg: >-
      kubernetes_apt_version ({{ kubernetes_apt_version }}) does not belong to
      kubernetes_minor ({{ kubernetes_minor }}). Bump both together.

- name: Every inventory host must have an ansible_host
  ansible.builtin.assert:
    that:
      - hostvars[item].ansible_host is defined
    fail_msg: "{{ item }} has no ansible_host in inventory.ini"
    quiet: true
  loop: "{{ groups['k8s_cluster'] }}"
  run_once: true

- name: Pod CIDR must not overlap any node's LAN subnet
  ansible.builtin.assert:
    that:
      - not (item | ansible.utils.network_in_network(pod_cidr))
    fail_msg: >-
      pod_cidr {{ pod_cidr }} overlaps {{ item }}. Pod networking will break in
      ways that look like random pod-to-pod failures.
    quiet: true
  loop: "{{ ssh_allowed_from }}"
```

The overlap check needs the `ansible.utils` collection; if you would rather not add
a dependency, a `pod_cidr is not match('^192\.168\.')` check catches the specific
documented footgun with zero new requirements.

Run it as the first role in `site.yml`, and also at the top of `cluster.yml` since
`cluster.yml` can be run independently.

- **Pros:** mistakes surface in seconds with an actionable message instead of
  mid-run with a traceback; encodes the constraints currently living only in
  comments; the CIDR check protects an unrecoverable decision.
- **Cons:** a sixth role; `ansible.utils` dependency if you want real subnet math.
- **Effort:** Small. **Risk:** Low.

### Option B — `assert` blocks inside each role's `tasks/main.yml`

- **Pros:** roles stay self-validating and independently usable; no new role.
- **Cons:** the checks run *after* earlier roles have already made changes, so
  `hardening` may have reconfigured sshd before `control_plane`'s assertions catch a
  bad `control_plane_endpoint`. Assertions are only cheap if they run first.
- **Effort:** Small. **Risk:** Low.

### Option C — real default values in `defaults/main.yml`

- **Pros:** roles work out of the box.
- **Cons:** actively harmful for values like `admin_user` and
  `control_plane_endpoint` — a plausible-looking default silently provisions the
  wrong thing instead of failing. Comment-only defaults are the right call here;
  the gap is validation, not defaults.
- **Effort:** Small. **Risk:** Medium.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/preflight/` — new role (tasks, meta)
- `ansible/site.yml:15-23` — insert `preflight` first
- `ansible/cluster.yml:14-19` — insert `preflight` first
- `ansible/requirements.yml` — add `ansible.utils` if the subnet check is used
- `ansible/group_vars/all.yml:28-32` — the comment can then point at the assert

## Acceptance Criteria

- [ ] Commenting out `admin_user` makes `site.yml` fail within seconds with a named message
- [ ] Setting `pod_cidr: 192.168.0.0/16` fails preflight, before any node is touched
- [ ] Setting `control_plane_endpoint` to an IP fails preflight
- [ ] Mismatched `kubernetes_minor` / `kubernetes_apt_version` fails preflight
- [ ] Removing `ansible_host` from a node in `inventory.ini` fails preflight naming that node
- [ ] Preflight adds no measurable time to a normal run

## Work Log

- 2026-07-26 — RESOLVED in the same session. New preflight role, first in both playbooks. 10 assertions. Negative-tested all of them against a synthetic local inventory — every one fires with an actionable message. One assertion was rewritten during testing: `ansible_host is defined` was a no-op and had to become an IPv4 match (see finding note below).
- 2026-07-26 — Filed from `/ce-review`. The pod-CIDR overlap assertion is the one
  worth doing even if the rest is skipped: `group_vars/all.yml:28-32` documents a
  footgun that is unrecoverable after `kubeadm init`.

## Resources

- `ansible/group_vars/all.yml:28-32` — the CIDR collision warning this would enforce
- `ansible/roles/control_plane/tasks/main.yml:89-93` — an existing example of an
  in-repo verification task (the Calico CIDR patch check), which is the pattern to follow
