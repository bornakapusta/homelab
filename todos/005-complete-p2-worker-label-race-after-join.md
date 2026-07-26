---
status: complete
priority: p2
issue_id: "005"
tags: [code-review, correctness, race-condition, ansible]
dependencies: []
---

# Worker labelling races the API server: node may not be registered yet when `kubectl label` runs

## Problem Statement

`roles/worker/tasks/main.yml` does, in immediate succession:

```
 9  - name: Join the cluster                    # kubeadm join, then...
18  - name: Check existing worker label         # kubectl get node <name>   (failed_when: false)
29  - name: Label this node as a worker         # kubectl label node <name>
```

`kubeadm join` returns as soon as the kubelet has written
`/etc/kubernetes/kubelet.conf` and TLS bootstrap has completed. The Node **object**
appearing in the API server is a separate, slightly later event. There is no wait
between join and label.

When the node is not yet registered:
- Line 18's `kubectl get node` fails → but `failed_when: false` (line 27) swallows it
- `worker_label.stdout` is empty → `worker_label.stdout != "worker"` is **true**
- Line 29 runs `kubectl label node node-3 …` → `NotFound`, task fails, `cluster.yml` aborts

## Findings

1. **`failed_when: false` at line 27 converts a signal into silence.** It is there
   to handle "label not set yet", which is legitimate, but it also masks
   "node does not exist yet" — two very different conditions producing the same
   empty `stdout`.
2. **The control-plane role does wait, but only for itself.**
   `roles/control_plane/tasks/main.yml:106-111` runs
   `kubectl wait --for=condition=Ready node/{{ inventory_hostname }}` — for the CP
   node. There is no equivalent wait for workers.
3. **Timing-dependent, so it will pass in testing and fail in the field.** On a
   fast LAN the Node object usually appears within a second; on the WiFi link this
   repo is explicitly built for (see `roles/base/tasks/main.yml:51-54`), the window
   widens. Intermittent `cluster.yml` failures are the symptom.
4. **`delegate_to` is correct.** Lines 24 and 35 delegate to
   `groups['control_plane'][0]`, which is where `admin.conf` lives. No issue there.
5. **`changed_when: true` at line 37** means the label task always reports changed
   even when `--overwrite` is a no-op. Cosmetic.
6. **Second-order:** `roles/control_plane/tasks/main.yml:114-126` computes
   `groups['workers'] | difference(joined_nodes.stdout.split())` to decide whether
   to mint a token. If a worker has `kubelet.conf` on disk but is **not** in the
   API server (a half-reset node), the CP skips token creation, `kubeadm_join_command`
   is undefined, and the worker also skips joining because `kubelet.conf` exists —
   so the node stays permanently absent with no error reported. Worth fixing in the
   same pass.

## Proposed Solutions

### Option A — wait for registration, then make the label check honest (recommended)

```yaml
- name: Wait for this node to register with the API server
  ansible.builtin.command: >
    kubectl get node {{ inventory_hostname }} -o name
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  delegate_to: "{{ groups['control_plane'][0] }}"
  register: node_registered
  until: node_registered.rc == 0
  retries: 30
  delay: 5
  changed_when: false

- name: Read the current worker label
  ansible.builtin.command: >
    kubectl get node {{ inventory_hostname }}
    -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/worker}'
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  delegate_to: "{{ groups['control_plane'][0] }}"
  register: worker_label
  changed_when: false      # no failed_when: false — the node provably exists now
```

Then keep the existing label task guarded by `worker_label.stdout != "worker"`.

Optionally also wait for `condition=Ready` before labelling, mirroring what the
control-plane role already does — though Ready requires Calico to have scheduled a
pod on the node, which adds up to a minute per worker.

- **Pros:** removes the race; `failed_when: false` disappears, so a genuinely
  missing node now fails loudly instead of silently mislabelling; mirrors the
  existing pattern in `control_plane`.
- **Cons:** adds up to 150 s of worst-case wait per worker.
- **Effort:** Small. **Risk:** Low.

### Option B — set the label at join time via `--node-labels`

Pass `--node-labels=node-role.kubernetes.io/worker=worker` through the kubelet
extra args, so no post-join `kubectl` is needed at all.

- **Pros:** eliminates both the race and the two `kubectl` round-trips;
  declarative.
- **Cons:** the kubelet is **not permitted** to self-assign labels in the
  `node-role.kubernetes.io/` prefix — the NodeRestriction admission plugin (on by
  default with kubeadm) rejects it, and the kubelet then fails to register at all.
  This would break the join outright. Rejected — documenting so it is not
  re-proposed.
- **Effort:** Small. **Risk:** High (does not work).

### Option C — add `retries`/`until` to the label task itself

- **Pros:** two-line diff.
- **Cons:** retries the *mutation* rather than the precondition, and leaves
  `failed_when: false` in place, so the underlying "empty stdout means two
  different things" confusion persists.
- **Effort:** Trivial. **Risk:** Low.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/worker/tasks/main.yml:18-27` — replace `failed_when: false` with a preceding `until` wait
- `ansible/roles/worker/tasks/main.yml:29-37` — `changed_when` should reflect actual change
- `ansible/roles/control_plane/tasks/main.yml:114-132` — the stale-`kubelet.conf` gap (finding 6)

**Suggested fix for finding 6:** make the worker's join guard check cluster
membership, not just file existence — e.g. join when
`kubelet.conf` is absent **or** the node is missing from `joined_nodes.stdout`,
and always mint a token when any worker is missing from the API server.

## Acceptance Criteria

- [ ] `make cluster` succeeds from a clean `kubeadm reset` on all three nodes, three runs in a row
- [ ] Both workers show `node-role.kubernetes.io/worker` in `kubectl get nodes --show-labels`
- [ ] Re-running `make cluster` on a fully-joined cluster reports zero changes for the label task
- [ ] A node with a stale `/etc/kubernetes/kubelet.conf` but absent from the API server produces a **failure**, not a silent skip
- [ ] No `failed_when: false` remains in `roles/worker/tasks/main.yml`

## Work Log

- 2026-07-26 — RESOLVED in the same session. Added an until/retries wait for API-server registration before labelling, and removed failed_when: false from the label read. Stale-state gap closed: the worker role now queries cluster membership itself (delegated, so --tags workers works) and fails loudly with reset instructions when kubelet.conf exists but the node is absent from the cluster.
- 2026-07-26 — Filed from `/ce-review`. Race identified by reading the task
  sequence; not reproduced (no cluster reachable from this machine, no Ansible
  installed). Option B investigated and rejected — NodeRestriction blocks
  kubelet-set `node-role.kubernetes.io/*` labels.

## Resources

- `ansible/roles/control_plane/tasks/main.yml:106-111` — the `kubectl wait` pattern to mirror
- `ansible/roles/worker/tasks/main.yml:4-16` — join guard
