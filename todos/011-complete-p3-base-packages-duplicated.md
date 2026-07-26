---
status: complete
priority: p3
issue_id: "011"
tags: [code-review, simplification, quality, ansible]
dependencies: []
---

# `base_packages` is defined twice, identically — one copy is dead

## Problem Statement

The same nine-item list exists in two places:

- `ansible/group_vars/all.yml:43-51`
- `ansible/roles/base/defaults/main.yml:6-15`

Ansible's precedence puts `group_vars/all` above role defaults, so the role
defaults copy is **never used**. Editing it has no effect, which is the worst
property a config file can have.

`CLAUDE.md` states that `group_vars/all.yml` is the "single source of truth for all
variables". The duplicate contradicts that claim in the one place someone would go
looking.

## Findings

1. **Silent-no-op risk.** Someone adding a package to
   `roles/base/defaults/main.yml` will see no change on the nodes and no error. The
   two lists are currently identical, so nothing is broken *yet* — this is a trap,
   not a bug.
2. **The comment header is misleading.** `roles/base/defaults/main.yml:2` says
   "Override in group_vars/all.yml" — which is exactly what has happened, so the
   file is technically self-documenting about its own irrelevance.
3. **The other roles do this correctly.** `hardening`, `control_plane`,
   `kubernetes_node`, and `worker` defaults files are comment-only (see
   `010-pending-p3-preflight-variable-assertions.md`). `base` is the sole
   inconsistency.
4. **`iw` has a real dependency.** `group_vars/all.yml:51` marks `iw` as
   "needed to disable WiFi power saving", and
   `roles/base/tasks/main.yml:69` invokes `/usr/sbin/iw` from the systemd unit.
   Whichever copy survives must keep `iw` — removing it silently breaks the
   power-save unit at boot, which reintroduces the node-flapping problem the unit
   exists to prevent.
5. **`chrony` and `ca-certificates`/`gnupg` also have real consumers.**
   `roles/base/tasks/main.yml:41-45` enables `chrony`;
   `roles/kubernetes_node/tasks/main.yml:63-77` needs `ca-certificates`/`gnupg` for
   the apt keyrings. The list is not arbitrary.

## Proposed Solutions

### Option A — keep the role default, drop it from `group_vars` (recommended)

`base_packages` is a property of the `base` role, not a site-wide setting. Role
defaults are the idiomatic home for it, and `group_vars/all.yml` remains available
for a genuine override without carrying a redundant copy.

Add a pointer comment in `group_vars/all.yml` where the list used to be:

```yaml
# base_packages lives in roles/base/defaults/main.yml — override here only if
# you need site-specific packages.
```

This keeps `group_vars/all.yml` focused on the things a user actually edits
(`admin_user`, `timezone`, versions, CIDRs) rather than an internal package list.

- **Pros:** matches the convention the other four roles already follow; the role
  becomes self-contained and reusable; `group_vars/all.yml` gets shorter, which
  matters because its header says "EDIT THIS FILE FIRST".
- **Cons:** mildly contradicts the "`group_vars` is the single source of truth for
  all variables" line in `CLAUDE.md` — so `CLAUDE.md` needs a one-line amendment to
  say "user-facing variables".
- **Effort:** Trivial. **Risk:** Low.

### Option B — keep `group_vars`, delete the role default

- **Pros:** literally matches the current `CLAUDE.md` wording.
- **Cons:** makes `roles/base` non-functional standalone (installing zero packages,
  silently — `apt: name: []` is a no-op, not an error); inconsistent with the other
  roles; keeps an internal list in the file a user is told to edit first.
- **Effort:** Trivial. **Risk:** Low.

### Option C — leave both, add a comment explaining precedence

- **Pros:** no behaviour change.
- **Cons:** documents the confusion rather than removing it; the lists will drift.
- **Effort:** Trivial. **Risk:** Low.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/group_vars/all.yml:42-51` — remove list, leave pointer comment
- `ansible/roles/base/defaults/main.yml:6-15` — becomes the authoritative copy
- `CLAUDE.md` — amend "single source of truth for all variables" → "for all
  user-facing variables"

**Do not drop while consolidating:** `iw` (WiFi power-save unit),
`chrony` (clock sync — `roles/base/tasks/main.yml:41-45`),
`ca-certificates` + `gnupg` (apt keyrings in `kubernetes_node`).

## Acceptance Criteria

- [ ] `base_packages` defined in exactly one file
- [ ] `make nodes` still installs all nine packages (verify with `dpkg -l iw chrony jq`)
- [ ] `iw` present and `wifi-no-powersave.service` active on all three nodes
- [ ] `CLAUDE.md` wording matches the chosen layout
- [ ] A comment in whichever file *doesn't* hold the list points at the one that does

## Work Log

- 2026-07-26 — RESOLVED in the same session. base_packages removed from group_vars; roles/base/defaults/main.yml is now authoritative, with a comment recording why each package is there (chrony, iw, ca-certificates/gnupg all have real consumers). CLAUDE.md amended: group_vars is the source of truth for user-facing variables.
- 2026-07-26 — Filed from `/ce-review` (simplification pass). No functional impact
  today; filed to prevent a future silent no-op edit.

## Resources

- `ansible/roles/base/tasks/main.yml:35-38` — the consuming task
- `ansible/roles/base/tasks/main.yml:55-78` — the `iw` dependency
