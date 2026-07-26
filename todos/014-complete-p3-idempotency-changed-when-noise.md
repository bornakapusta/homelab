---
status: complete
priority: p3
issue_id: "014"
tags: [code-review, idempotency, quality, ansible]
dependencies: []
---

# Several tasks always report `changed`, so a converged run never reads as clean

## Problem Statement

`CLAUDE.md` and `site.yml:7` both describe `site.yml` as idempotent and safe to
re-run. Functionally that is true. But a converged run still reports a handful of
changes every time, which destroys the main practical benefit of idempotency:
being able to glance at a run and see that nothing drifted.

Tasks that always report `changed`:

| Task | Location |
|---|---|
| `Disable swap now` | `roles/kubernetes_node/tasks/main.yml:8-10` — `changed_when: true` |
| `Unhold packages…` / `Hold…` | `roles/kubernetes_node/tasks/main.yml:141-169` — `dpkg_selections` flips state each run |
| `Apply Calico` | `roles/control_plane/tasks/main.yml:95-99` — `changed_when: true` |
| `Label this node as a worker` | `roles/worker/tasks/main.yml:29-37` — `changed_when: true` |
| `Reload ufw` (handler) | `roles/hardening/handlers/main.yml:7-9` — `changed_when: true` |
| `Upgrade installed packages` | `roles/base/tasks/main.yml:31-33` — changed whenever anything upgrades |

## Findings

1. **`Disable swap now` is guarded but mislabelled.** The `when:` at line 9
   (`ansible_swaptotal_mb > 0`) means it only runs when swap is actually on, and
   facts are gathered at play start — so after the first run it correctly skips.
   `changed_when: true` is accurate here. Not a real problem; listed for completeness.
2. **`Apply Calico` is inside a guarded block.** Lines 64-65 gate the whole block on
   `calico_present.rc != 0`, so on a converged cluster the block skips entirely. Also
   fine. The `changed_when: true` only matters on the run that actually installs.
3. **The `dpkg_selections` hold/unhold pair is the real noise.**
   `roles/kubernetes_node/tasks/main.yml:141-145` unholds four packages, then
   `:159-169` re-holds them — every single run, on every node. That is 7 reported
   changes per node, 21 per `site.yml` run, none of which represent drift. It also
   makes the genuinely interesting change (a package version actually moving)
   invisible in the noise.
4. **`Label this node as a worker`** is guarded by
   `worker_label.stdout != "worker"` (line 36), so it does skip once labelled. But
   the guard depends on the check task that has `failed_when: false` — see
   `005-pending-p2-worker-label-race-after-join.md`. Fixing `005` fixes this too.
5. **`Reload ufw` fires whenever `/etc/default/ufw` changes**, which is once. The
   `changed_when: true` on the handler is unavoidable for a `command` and is
   harmless.
6. **Bootstrap token accumulation.**
   `roles/control_plane/tasks/main.yml:121-126` runs
   `kubeadm token create --print-join-command` whenever any worker is missing from
   the API server, with `changed_when: false` — which is inaccurate (it creates
   server-side state). Tokens have a 24 h TTL so they expire on their own, but a
   repeatedly-failing `make cluster` mints a fresh join token each attempt.
   Low-impact, but `changed_when: false` on a task that mutates the cluster is
   wrong on principle.

## Proposed Solutions

### Option A — make the hold state conditional (recommended)

Read the current hold state once, and only change what needs changing:

```yaml
- name: Read current package hold state
  ansible.builtin.command: apt-mark showhold
  register: apt_holds
  changed_when: false

- name: Unhold managed packages so deliberate version changes can apply
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: install
  loop: [kubelet, kubeadm, kubectl, containerd.io]
  when: item in apt_holds.stdout_lines
```

The re-hold at the end of the role is naturally conditional already if you gate it
the same way. Combined with the reordering in
`004-pending-p2-containerd-hold-ordering.md`, a converged run reports zero changes
for all four packages.

For the token task, drop the inaccurate `changed_when: false`:

```yaml
- name: Generate a worker join command
  ansible.builtin.command: kubeadm token create --print-join-command
  register: join_command_raw
  changed_when: join_command_raw.rc == 0
  no_log: true
  when: groups['workers'] | difference(joined_nodes.stdout.split()) | length > 0
```

- **Pros:** a converged `make nodes` reports zero changes, so real drift becomes
  immediately visible; `changed` starts meaning something again.
- **Cons:** one extra `command` task per node; overlaps with the reordering work in
  todo `004`, so they should be done together.
- **Effort:** Small. **Risk:** Low.

### Option B — leave the tasks, document the expected noise

Add a note to `CLAUDE.md` listing which tasks always report changed and why.

- **Pros:** zero risk; honest.
- **Cons:** trains you to ignore the `changed` count, which is exactly the habit
  that lets real drift through unnoticed.
- **Effort:** Trivial. **Risk:** Low.

### Option C — `--check` mode as the drift detector instead

Rely on `ansible-playbook site.yml --check --diff` for drift detection and accept
noisy real runs.

- **Pros:** no code change; `--check` is the idiomatic drift tool.
- **Cons:** `--check` does not work cleanly here — `roles/kubernetes_node/tasks/main.yml:100-113`
  registers `containerd config default` output and then templates it into a
  `copy`, and in check mode the `command` does not run, so `containerd_default_config.stdout`
  is undefined and the play errors. `--check` would need its own fixes first.
- **Effort:** Medium. **Risk:** Low.

## Recommended Action

_(fill during triage)_

**Note:** best done in the same pass as `004-pending-p2-containerd-hold-ordering.md`
— both touch the same hold/unhold tasks, and doing them separately means editing
the same block twice.

## Technical Details

**Affected files:**
- `ansible/roles/kubernetes_node/tasks/main.yml:141-145,159-169` — hold/unhold
- `ansible/roles/control_plane/tasks/main.yml:121-126` — token `changed_when`
- `ansible/roles/kubernetes_node/tasks/main.yml:100-113` — the `--check`-mode gap (Option C context)
- `CLAUDE.md` — if Option B

## Acceptance Criteria

- [ ] A second consecutive `make nodes` on a converged cluster reports `changed=0` for all three nodes (allowing for `apt upgrade` when packages genuinely move)
- [ ] `apt-mark showhold` still lists all four packages after a run
- [ ] Bumping a pinned version still produces exactly the expected changes
- [ ] The token task reports `changed` when it actually mints a token
- [ ] Any remaining always-changed task has a comment explaining why

## Work Log

- 2026-07-26 — RESOLVED in the same session. Hold/unhold are now conditional on `apt-mark showhold` output, so a converged run reports no change for those 7 tasks. Token task's changed_when now reflects that it mints server-side state. Also added check_mode: false to the read-only command tasks, which fixes --check mode (previously `containerd config default` was skipped under --check, leaving its stdout undefined and erroring the run).
- 2026-07-26 — Filed from `/ce-review` (simplification/idempotency pass). Verified
  by reading guards rather than running: several tasks flagged initially as noisy
  turned out to be correctly guarded (`Disable swap now`, `Apply Calico`) and were
  downgraded to notes.

## Resources

- `ansible/roles/kubernetes_node/tasks/main.yml:158,165` — the comments explaining why the holds exist
- Related: `004-pending-p2-containerd-hold-ordering.md` — same code block
- Related: `005-pending-p2-worker-label-race-after-join.md` — fixes the label noise
