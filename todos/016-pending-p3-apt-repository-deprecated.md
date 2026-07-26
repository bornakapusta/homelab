---
status: pending
priority: p3
issue_id: "016"
tags: [code-review, deprecation, ansible, maintenance]
dependencies: []
---

# `apt_repository` is deprecated and scheduled for removal in ansible-core 2.25

## Problem Statement

`ansible-playbook --syntax-check` emits:

```
[DEPRECATION WARNING]: ansible.builtin.apt_repository has been deprecated.
Use deb822_repository instead. This feature will be removed from
ansible-core version 2.25.
```

Two call sites:
- `roles/kubernetes_node/tasks/main.yml` — Docker apt repository
- `roles/kubernetes_node/tasks/main.yml` — Kubernetes apt repository

Current controller is ansible-core 2.21.2, so there are a few releases of runway.
Not urgent, but it is a hard removal with a known deadline, and it will break
`make nodes` silently at whatever point ansible-core is upgraded past 2.25.

## Findings

1. **Deliberately not fixed during the review pass.** `deb822_repository` writes
   `.sources` files in deb822 format rather than one-line `.list` entries. That is
   a different on-disk artefact, and migrating it on a repo that has *never
   successfully run* would mean changing untested code to untested code. The
   working (if deprecated) version is the safer thing to have in place for the
   first run.
2. **`python3-debian` may be required.** `deb822_repository` can need
   `python3-debian` on the target host for some operations. That is a new
   dependency to add to `base_packages`, and it needs verifying on Ubuntu 24.04
   rather than assumed.
3. **Migration leaves stale files.** Switching module changes the filename
   (`/etc/apt/sources.list.d/docker.list` →
   `/etc/apt/sources.list.d/docker.sources`). Without an explicit removal task the
   node ends up with **both**, and apt will warn about duplicate sources — or
   worse, keep using the old pinned repo definition. Any migration must delete the
   old `.list` files.
4. **The `signed-by=` keyring paths stay valid** — both repos already reference
   `/etc/apt/keyrings/*.asc`, which deb822 supports via the `signed_by` option, so
   the checksum-pinned keys carry over unchanged.
5. **Timing:** best done immediately *after* the first successful `make nodes`,
   when there is a known-good baseline to compare a converged run against.

## Proposed Solutions

### Option A — migrate after the first successful run (recommended)

```yaml
- name: Add Docker apt repository
  ansible.builtin.deb822_repository:
    name: docker
    types: [deb]
    uris: https://download.docker.com/linux/ubuntu
    suites: ["{{ ansible_distribution_release }}"]
    components: [stable]
    architectures: ["{{ 'amd64' if ansible_architecture == 'x86_64' else ansible_architecture }}"]
    signed_by: /etc/apt/keyrings/docker.asc
    state: present

- name: Remove the superseded one-line repo definitions
  ansible.builtin.file:
    path: "/etc/apt/sources.list.d/{{ item }}.list"
    state: absent
  loop: [docker, kubernetes]
```

Verify with `apt-get update` producing no duplicate-source warnings, and
`apt-cache policy kubeadm` still resolving to the pinned version.

- **Pros:** removes the deadline; deb822 is the supported format; keeps the
  checksum-pinned keys.
- **Cons:** needs a real node to verify against; `python3-debian` may need adding.
- **Effort:** Small. **Risk:** Low, once there is a working baseline.

### Option B — pin ansible-core below 2.25 and defer

- **Pros:** zero change now.
- **Cons:** trades a known deadline for a version ceiling on the controller, which
  is the same problem wearing a different hat.
- **Effort:** Trivial. **Risk:** Low.

### Option C — do nothing

- **Pros:** nothing to do.
- **Cons:** `make nodes` breaks on a future controller upgrade, at a time not of
  your choosing, with a module-not-found error.
- **Effort:** None. **Risk:** Medium.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/kubernetes_node/tasks/main.yml` — both `apt_repository` tasks
- `ansible/roles/base/defaults/main.yml` — possibly add `python3-debian`
- `CLAUDE.md` — note the repo format if migrated

## Acceptance Criteria

- [ ] `ansible-playbook --syntax-check site.yml cluster.yml` emits no deprecation warnings
- [ ] `apt-get update` on each node reports no duplicate-source warnings
- [ ] Old `/etc/apt/sources.list.d/{docker,kubernetes}.list` removed
- [ ] `apt-cache policy kubeadm containerd.io` still resolves the pinned versions
- [ ] `make check` still passes ansible-lint at the `production` profile

## Work Log

- 2026-07-26 — Surfaced by `ansible-playbook --syntax-check` during the `/ce-review`
  fix pass (the tooling from `015` immediately paying for itself). Deliberately
  deferred: migrating untested code to untested code before the first run is worse
  than carrying a deprecation with runway left.

## Resources

- `ansible/roles/kubernetes_node/tasks/main.yml` — both call sites
- Related: `015-pending-p3-no-lint-or-ci.md` — the check that found this
