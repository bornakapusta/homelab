---
status: complete
priority: p3
issue_id: "013"
tags: [code-review, correctness, quality, ansible]
dependencies: []
---

# `control_plane_endpoint` is interpolated into a regex unescaped

## Problem Statement

`roles/base/tasks/main.yml:15-20`:

```yaml
- name: Make the control-plane endpoint resolvable on every node
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: "\\s{{ control_plane_endpoint }}$"
    line: "{{ hostvars[groups['control_plane'][0]].ansible_host }} {{ control_plane_endpoint }}"
    state: present
```

`control_plane_endpoint` is `k8s.lab.example` (`group_vars/all.yml:26`). Dots are
regex metacharacters, so the pattern also matches `k8sXlabYexample`,
`k8s-lab-example`, and so on. Any pre-existing `/etc/hosts` line ending in a
similarly-shaped hostname would be **replaced** rather than left alone.

## Findings

1. **Low likelihood, non-trivial consequence.** `/etc/hosts` on a fresh Ubuntu
   install contains `127.0.0.1 localhost`, `127.0.1.1 <hostname>`, and the IPv6
   block. None of those collide. But the task rewrites `/etc/hosts` on every run, so
   a hand-added entry that happens to match gets silently clobbered.
2. **The same pattern is used correctly two tasks earlier.**
   `roles/base/tasks/main.yml:9-13` uses `regexp: '^127\.0\.1\.1\s'` — dots
   explicitly escaped. So the convention is understood; line 18 is an oversight, not
   a misunderstanding.
3. **`regex_escape` is a built-in filter**, so the fix is one filter call with no
   new dependency: `regexp: "\\s{{ control_plane_endpoint | regex_escape }}$"`.
4. **A second, more likely mismatch:** the pattern anchors on `$`, so it only
   matches when the hostname is the **last** token on the line. A perfectly normal
   `/etc/hosts` entry like `192.168.178.26 k8s.lab.example k8s` does not match,
   so the task appends a duplicate line every time it decides the entry is missing.
   `lineinfile` would then have two entries for the same name — resolution still
   works (first match wins), but it is untidy and confusing during debugging.
5. **Related: `roles/kubernetes_node/tasks/main.yml:15`** —
   `regexp: '^([^#].*\sswap\s+sw\s+.*)$'` assumes the fstab swap options are exactly
   `sw`. Ubuntu's default swap.img line is `/swap.img none swap sw 0 0`, so it
   matches — but an LVM swap volume written with `defaults` instead of `sw` would
   not be commented out, and the kubelet would refuse to start after the next reboot.
   `swapoff -a` at line 8 masks this until a reboot happens. Worth widening to
   `\sswap\s+\S+\s+` in the same pass.

## Proposed Solutions

### Option A — escape the variable and relax the anchor (recommended)

```yaml
- name: Make the control-plane endpoint resolvable on every node
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '(^|\s){{ control_plane_endpoint | regex_escape }}(\s|$)'
    line: "{{ hostvars[groups['control_plane'][0]].ansible_host }} {{ control_plane_endpoint }}"
    state: present
```

And in `kubernetes_node`:

```yaml
- name: Remove swap from fstab permanently
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#]\S*\s+\S+\s+swap\s+\S+\s+.*)$'
    replace: '# \1'
```

- **Pros:** correct for any endpoint name; matches existing entries regardless of
  trailing aliases, so no duplicate lines; the fstab widening closes a
  reboot-triggered kubelet failure.
- **Cons:** the `(\s|$)` group makes the pattern slightly less readable.
- **Effort:** Trivial. **Risk:** Low.

### Option B — escape only, leave the `$` anchor

- **Pros:** one filter call, minimal diff.
- **Cons:** leaves the duplicate-line behaviour from finding 4.
- **Effort:** Trivial. **Risk:** Low.

### Option C — manage the whole `/etc/hosts` block with `blockinfile`

Replace both `/etc/hosts` tasks with a single Ansible-marked block containing
`127.0.1.1` and the endpoint mapping.

- **Pros:** no regex at all; fully idempotent; the managed region is explicit and
  visible in the file.
- **Cons:** the `127.0.1.1` line already exists outside the block (written by the
  installer), so you would end up with both it and the block version — needs a
  separate removal task, which is more code than the two current tasks.
- **Effort:** Small. **Risk:** Low.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/base/tasks/main.yml:15-20` — unescaped endpoint in `regexp`
- `ansible/roles/kubernetes_node/tasks/main.yml:12-16` — narrow fstab swap pattern

**Reference for the correct convention already in the repo:**
`ansible/roles/base/tasks/main.yml:11` — `regexp: '^127\.0\.1\.1\s'`

## Acceptance Criteria

- [ ] `control_plane_endpoint` passed through `regex_escape` wherever it appears in a `regexp`
- [ ] Running `make nodes` twice produces exactly one `k8s.lab.example` line in `/etc/hosts` on every node
- [ ] Pre-adding `192.168.178.26 k8s.lab.example k8s` by hand does not produce a duplicate on the next run
- [ ] fstab pattern commented out any swap entry regardless of the options field
- [ ] A node survives a reboot with swap still disabled (`swapon --show` empty, kubelet up)

## Work Log

- 2026-07-26 — RESOLVED in the same session. control_plane_endpoint now passed through regex_escape with (^|\s)...(\s|$) anchors, so entries carrying aliases are updated instead of duplicated. fstab swap pattern widened from a literal `sw` to \S+ so an LVM swap volume written with `defaults` is also commented out.
- 2026-07-26 — Filed from `/ce-review`. Both patterns reviewed by hand against
  Ubuntu 24.04's default `/etc/hosts` and `/etc/fstab` layouts; neither collides
  today, so this is preventive.

## Resources

- `ansible/roles/base/tasks/main.yml:8-20`
- `ansible/roles/kubernetes_node/tasks/main.yml:5-21`
