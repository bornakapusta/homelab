---
status: complete
priority: p2
issue_id: "004"
tags: [code-review, correctness, ansible, idempotency]
dependencies: []
---

# `containerd.io` is installed before the unhold task, so deliberate version bumps are silently ignored

## Problem Statement

In `roles/kubernetes_node/tasks/main.yml` the task order is:

| Line | Task |
|---|---|
| 79-84 | `Install containerd` (`containerd.io`, `state: present`) |
| 141-145 | `Unhold packages so a deliberate version change can apply` (loop includes `containerd.io`) |
| 166-169 | `Hold containerd version` |

The unhold task runs **62 lines after** the install. On any run after the first,
`containerd.io` is already `hold`, so `Install containerd` cannot change it. The
unhold at line 141 comes too late to help — it only takes effect on the *next*
run, and by then line 166 has re-held it.

Net effect: `containerd.io` is pinned to whatever version happened to be current
on the first run, permanently, with no way to move it via the playbook. The
comment at line 141 ("so a deliberate version change can apply") describes an
intent the ordering defeats.

## Findings

1. **The kube packages are fine.** `kubelet`/`kubeadm`/`kubectl` are unheld at
   line 141-145, installed at 147-156 with `allow_downgrade: true`, then re-held at
   159-163. That sequence is correct and is clearly the intended pattern.
   `containerd.io` was added to the unhold loop but its install was left upstream.
2. **`containerd.io` has no version variable at all.** `group_vars/all.yml:34-40`
   pins `kubernetes_minor`, `kubernetes_apt_version`, and `calico_version`, but
   containerd is `state: present` — unpinned on first install, then frozen by the
   hold. So the version you get depends on when you first ran the playbook. That
   is the worst of both worlds: not reproducible, and not upgradable.
3. **The hold is load-bearing.** The comment at line 165 is right: an unintended
   containerd upgrade rewrites `/etc/containerd/config.toml` and resets
   `SystemdCgroup`, which breaks the kubelet in a way that does not mention
   cgroups. So the hold must stay — the fix is ordering, not removal.
4. **Interaction with `base`.** `roles/base/tasks/main.yml:31-33` runs
   `apt upgrade: safe` on every `site.yml` run. Held packages are excluded, which
   is exactly why the hold exists. Confirms the hold is correct and the ordering
   is the bug.
5. **Secondary idempotency wart:** `dpkg_selections` reports `changed` on every
   transition, so lines 141-145 and 159-169 flip `install`→`hold` each run and
   `site.yml` never converges to zero changes. Cosmetic, but it hides real drift.

## Proposed Solutions

### Option A — move the unhold above the containerd install and pin the version (recommended)

Reorder so the unhold is the first apt-touching task in the role, and add a
version variable:

```yaml
# group_vars/all.yml
containerd_apt_version: "1.7.27-1"   # pin like the kube packages; check with:
                                     #   apt-cache madison containerd.io
```

```yaml
# roles/kubernetes_node/tasks/main.yml — before "Install containerd"
- name: Unhold managed packages so deliberate version changes can apply
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: install
  loop: [kubelet, kubeadm, kubectl, containerd.io]
  failed_when: false      # packages may not be installed yet on first run

- name: Install containerd at the pinned version
  ansible.builtin.apt:
    name: "containerd.io={{ containerd_apt_version }}"
    state: present
    update_cache: true
    cache_valid_time: 3600
    allow_downgrade: true
```

Then keep both `hold` tasks at the end of the role, where they are now.

- **Pros:** containerd becomes reproducible and upgradable; matches the pattern
  already used for the kube packages; single unhold point.
- **Cons:** one more version to check before the first run (adds to the list in
  `group_vars/all.yml:35`); `dpkg_selections` on a not-yet-installed package
  needs `failed_when: false`.
- **Effort:** Small. **Risk:** Low.

### Option B — reorder only, leave `containerd.io` unpinned

- **Pros:** two-line diff; fixes the immediate "cannot upgrade" bug.
- **Cons:** the version still depends on first-run date, so the three nodes can
  end up on different containerd versions if provisioned weeks apart. For a
  cluster that is a real inconsistency.
- **Effort:** Trivial. **Risk:** Low.

### Option C — drop the containerd hold, rely on the blacklist in `hardening`

`roles/hardening/tasks/main.yml:116-121` already blacklists `containerd.io` from
unattended-upgrades.

- **Pros:** removes the ordering problem entirely.
- **Cons:** the blacklist only covers *unattended* upgrades. `roles/base` runs an
  explicit `apt upgrade: safe` on every run, which the blacklist does not touch —
  so containerd would upgrade under you and reset `SystemdCgroup`. Rejected.
- **Effort:** Trivial. **Risk:** High.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/kubernetes_node/tasks/main.yml:79-84` — install task, needs to move after unhold
- `ansible/roles/kubernetes_node/tasks/main.yml:141-145` — unhold task, needs to move to top
- `ansible/roles/kubernetes_node/tasks/main.yml:166-169` — hold task, stays
- `ansible/group_vars/all.yml:34-40` — add `containerd_apt_version`
- `ansible/roles/kubernetes_node/defaults/main.yml` — document the new required var

**Note on the config-regeneration guard** (`main.yml:94-113`): the
`grep -q 'SystemdCgroup = true'` check means the config is only rewritten when it
is *not* already correct. That is good — but it also means a containerd upgrade
that resets the config **will** be detected and repaired on the next `site.yml`
run. Verify this still holds after reordering.

## Acceptance Criteria

- [ ] Bumping `containerd_apt_version` and re-running `make nodes` actually changes the installed version
- [ ] `apt-mark showhold` on each node lists `containerd.io`, `kubeadm`, `kubectl`, `kubelet` after a run
- [ ] All three nodes report the same `containerd --version`
- [ ] `roles/base`'s `apt upgrade: safe` does not move containerd (verify with `apt-get -s upgrade`)
- [ ] `SystemdCgroup = true` still present in `/etc/containerd/config.toml` after an upgrade+re-run cycle

## Work Log

- 2026-07-26 — RESOLVED in the same session. Unhold moved to the top of the role, before any install; containerd pinned to containerd_apt_version (2.2.6-1~ubuntu.24.04~noble, verified available for noble). Hold/unhold now share one `managed_held_packages` list so they cannot drift. Added a verification task asserting SystemdCgroup = true actually made it into the written config — the regex_replace would silently no-op if containerd renamed the key.
- 2026-07-26 — Filed from `/ce-review`. Found by tracing task order rather than
  behaviour; could not execute (`ansible-playbook` not installed locally).

## Resources

- `ansible/roles/kubernetes_node/tasks/main.yml:92-93` — the SystemdCgroup gotcha comment
- `ansible/roles/hardening/tasks/main.yml:115-121` — unattended-upgrades blacklist
