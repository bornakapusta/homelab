---
status: complete
priority: p3
issue_id: "012"
tags: [code-review, supply-chain, reproducibility, ansible]
dependencies: []
---

# `requirements.yml` pins no version, and `ansible.posix` is missing

## Problem Statement

`ansible/requirements.yml` is three lines:

```yaml
---
collections:
  - name: community.general
```

No version constraint. Every other external dependency in this repo is pinned —
`kubernetes_apt_version`, `calico_version`, three SHA256 digests
(`group_vars/all.yml:34-40`, `roles/kubernetes_node/tasks/main.yml:68,131`) — so
this is the one unpinned input, and it is the one that controls the behaviour of
the modules doing the actual work.

## Findings

1. **Four modules depend on it:**
   - `community.general.timezone` — `roles/base/tasks/main.yml:23`
   - `community.general.ufw` — `roles/hardening/tasks/main.yml:51,56,64,70,78,86`
   - `community.general.modprobe` — `roles/kubernetes_node/tasks/main.yml:35`

   `community.general` is a very large, fast-moving collection. A behaviour change
   in `community.general.ufw` between major versions would land silently on the next
   `ansible-galaxy collection install`.
2. **Nothing records which version was used.** With zero commits and no lockfile,
   there is no way to reproduce a working run later, or to tell whether a future
   breakage came from the collection or from a repo change.
3. **`ansible.posix` will be needed.** The recommended approach in
   `001-pending-p1-dedicated-ansible-user.md` uses
   `ansible.posix.authorized_key`. That collection is not currently declared, so
   that work is blocked on this file. (`ansible.builtin.user` can set
   `authorized_keys` indirectly via a `copy`/`lineinfile`, but
   `authorized_key` with `key_options` and `exclusive` is the right tool.)
4. **`ansible.utils` may be needed too** — `010-pending-p3-preflight-variable-assertions.md`
   proposes `ansible.utils.network_in_network` for the pod-CIDR overlap assertion.
5. **`min_ansible_version: "2.14"`** is declared in all five `meta/main.yml` files.
   That is the ansible-core floor, and it is unenforced — `ansible-galaxy` reads it
   for published roles, not for local ones. Nothing checks the controller's
   ansible-core version either.
6. **No tooling is installed on the controller.** `ansible-playbook`,
   `ansible-lint`, and `yamllint` are all absent from this machine — so the repo has
   never had its dependencies resolved at all. Recording versions and documenting
   the install step are the same task.

## Proposed Solutions

### Option A — pin with a compatible-release range and declare all collections (recommended)

```yaml
---
# Install with:  ansible-galaxy collection install -r requirements.yml
collections:
  - name: community.general
    version: ">=10.0.0,<11.0.0"   # replace with the range you actually test against
  - name: ansible.posix
    version: ">=1.6.0,<2.0.0"     # authorized_key, sysctl, mount
  # - name: ansible.utils          # only if the CIDR-overlap assert (todo 010) lands
  #   version: ">=5.0.0,<6.0.0"
```

Add a preflight check for the controller's ansible-core version alongside the
assertions in `010`:

```yaml
- name: Controller ansible-core must be recent enough
  ansible.builtin.assert:
    that:
      - ansible_version.full is version('2.14', '>=')
    fail_msg: "ansible-core {{ ansible_version.full }} is older than the 2.14 floor declared in roles/*/meta/main.yml"
  run_once: true
  delegate_to: localhost
  become: false
```

Pin the range only after confirming which major version you actually have —
`ansible-galaxy collection list community.general` once Ansible is installed.
Guessing the range is worse than leaving it open, because a wrong lower bound fails
the install with a confusing resolver error.

- **Pros:** reproducible runs; the `ansible.posix` gap that blocks todo `001`
  closes; major-version breakage becomes an explicit decision instead of a surprise.
- **Cons:** ranges need occasional bumping; requires installing Ansible first to
  know the right numbers.
- **Effort:** Trivial. **Risk:** Low.

### Option B — exact pins (`version: "10.4.0"`)

- **Pros:** fully deterministic.
- **Cons:** blocks security fixes within the major version; needs manual bumps for
  routine patches. Over-tight for a homelab.
- **Effort:** Trivial. **Risk:** Low.

### Option C — leave unpinned, document the versions in `CLAUDE.md`

- **Pros:** zero maintenance.
- **Cons:** documentation that nothing enforces; drifts immediately.
- **Effort:** Trivial. **Risk:** Low.

## Recommended Action

_(fill during triage)_

**Sequencing:** install Ansible on the controller first, run
`ansible-galaxy collection list`, then write the ranges from observed reality rather
than from guesses.

## Technical Details

**Affected files:**
- `ansible/requirements.yml` — add versions and `ansible.posix`
- `ansible/roles/*/meta/main.yml` — `min_ansible_version: "2.14"` (unenforced; pair with the assert)
- `CLAUDE.md` — the install command is already documented under Conventions; add the version-bump note
- `Makefile` — consider a `make deps` target wrapping `ansible-galaxy collection install -r ansible/requirements.yml`

**Controller state (2026-07-26):** `ansible-playbook`, `ansible-lint`, and
`yamllint` are all absent from this machine. Nothing in the repo has been executed
or linted. See `015-pending-p3-no-lint-or-ci.md`.

## Acceptance Criteria

- [ ] `requirements.yml` declares every collection actually used by the roles
- [ ] `ansible.posix` declared (unblocks todo `001`)
- [ ] Version constraints present and derived from an installed, working set
- [ ] `ansible-galaxy collection install -r ansible/requirements.yml` succeeds from clean
- [ ] `make nodes` passes with the pinned set
- [ ] Controller ansible-core version is asserted or documented

## Work Log

- 2026-07-26 — RESOLVED in the same session. Pinned community.general >=13.0.0,<14.0.0 and added ansible.posix >=2.0.0,<3.0.0 (needed by automation_user). Ranges resolved from an actually-installed set, not guessed. Added `make deps`. This work also uncovered a live breakage: stdout_callback = yaml resolves to community.general.yaml, REMOVED in community.general 12.0.0 — every playbook run aborted before starting. Fixed to stdout_callback = default + result_format = yaml.
- 2026-07-26 — Filed from `/ce-review`. Deliberately does **not** propose specific
  version numbers: no Ansible installed locally, so any range written now would be
  a guess.

## Resources

- `ansible/roles/hardening/tasks/main.yml:51-87` — heaviest `community.general` consumer
- Related: `001-pending-p1-dedicated-ansible-user.md` — needs `ansible.posix`
- Related: `010-pending-p3-preflight-variable-assertions.md` — may need `ansible.utils`
- Related: `015-pending-p3-no-lint-or-ci.md`
