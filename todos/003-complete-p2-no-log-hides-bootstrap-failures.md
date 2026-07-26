---
status: complete
priority: p2
issue_id: "003"
tags: [code-review, operations, debuggability, ansible]
dependencies: []
---

# `no_log: true` on `kubeadm init` and `kubeadm join` makes the two most failure-prone tasks undebuggable

## Problem Statement

`no_log: true` is set on the two tasks that do the actual cluster bootstrap:

- `roles/control_plane/tasks/main.yml:21` — `kubeadm init`
- `roles/worker/tasks/main.yml:16` — `kubeadm join`

`no_log` suppresses output on **failure as well as success**. When `kubeadm init`
fails — and it fails for a long tail of reasons: cgroup driver, CRI socket, port
6443 in use, `control_plane_endpoint` not resolving, swap still on, preflight
errors — Ansible prints `"censored due to no_log"` and nothing else. You are then
debugging the hardest step in the whole repo with zero output.

## Findings

1. **The motivation is sound.** Both commands emit a bootstrap token and
   `kubeadm init` emits a certificate key. Those are genuine secrets and should not
   land in terminal scrollback or CI logs. The mechanism is just too blunt.
2. **`kubeadm init` is the single most likely task to fail** on a first run, and it
   is the one with the least recoverable state (a half-initialised control plane
   needs `kubeadm reset -f`).
3. **The blast radius is worse for `join`.** `roles/worker/tasks/main.yml:9-16`
   runs against two hosts. A join failure on node-3 gives you no output and no
   indication of whether it was a token problem, a DNS problem
   (`k8s.lab.example` resolution — see `roles/base/tasks/main.yml:15-20`), or a
   firewall problem.
4. **`kubeadm token create --print-join-command`** at
   `roles/control_plane/tasks/main.yml:121-131` genuinely produces nothing but the
   secret. `no_log` there is correct and should stay.
5. `changed_when: kubeadm_init.rc == 0` at line 20 means a failed init is reported
   as `failed`, not `changed` — correct, but still opaque.

## Proposed Solutions

### Option A — narrow `no_log` to the token task; redact init/join output instead (recommended)

For `kubeadm init`, use `--skip-token-print` and drop `no_log`:

```yaml
- name: Initialise the control plane
  ansible.builtin.command: >
    kubeadm init
    --control-plane-endpoint={{ control_plane_endpoint }}
    --pod-network-cidr={{ pod_cidr }}
    --node-name={{ inventory_hostname }}
    --skip-token-print
  when: not admin_conf.stat.exists
  register: kubeadm_init
  changed_when: kubeadm_init.rc == 0
```

The join command is regenerated later anyway
(`roles/control_plane/tasks/main.yml:121`), so the printed token from `init` is
never used. `--skip-token-print` removes the secret at the source, which is
strictly better than hiding the whole result.

For `kubeadm join`, keep `no_log` on the invocation (the command line itself
contains the token) but add a rescue that surfaces diagnostics without echoing the
command:

```yaml
- name: Join the cluster
  block:
    - name: Run kubeadm join
      ansible.builtin.command: >
        {{ hostvars[groups['control_plane'][0]].kubeadm_join_command }}
        --node-name={{ inventory_hostname }}
      register: join_result
      changed_when: join_result.rc == 0
      no_log: true
  rescue:
    - name: Show why the join failed
      ansible.builtin.debug:
        msg: "{{ join_result.stderr_lines | default(['no stderr captured']) }}"
    - name: Fail with a pointer to the real logs
      ansible.builtin.fail:
        msg: "kubeadm join failed. Run: journalctl -u kubelet -n 100 --no-pager"
  when: not kubelet_conf.stat.exists
```

`stderr` from `kubeadm join` does not echo the token (the token is on the command
line, not in the output), so surfacing `stderr_lines` in the rescue is safe.

- **Pros:** secrets stop existing rather than being hidden; failures are
  diagnosable; no manual log-hunting on the node.
- **Cons:** slightly more YAML; requires confirming `--skip-token-print` is
  supported on the pinned kubeadm (it has been since 1.11, so this is safe).
- **Effort:** Small. **Risk:** Low.

### Option B — keep `no_log`, add a `rescue` that tails `journalctl`

Leave both tasks as-is; on failure, run
`journalctl -u kubelet -n 100 --no-pager` and `kubeadm init phase preflight`
and print those.

- **Pros:** minimal diff; secrets stay fully suppressed.
- **Cons:** `journalctl` output is a proxy for the real error, not the error
  itself; kubeadm preflight failures never reach the kubelet journal at all.
- **Effort:** Small. **Risk:** Low.

### Option C — remove `no_log` from both

- **Pros:** full diagnostics.
- **Cons:** bootstrap token and certificate key land in scrollback. The token is
  a 24-hour cluster-join credential — not catastrophic, but not something to
  leak casually either.
- **Effort:** Trivial. **Risk:** Medium.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/control_plane/tasks/main.yml:12-21` — add `--skip-token-print`, drop `no_log`
- `ansible/roles/worker/tasks/main.yml:9-16` — wrap in `block`/`rescue`
- `ansible/roles/control_plane/tasks/main.yml:121-131` — leave `no_log` as-is (correct)

## Acceptance Criteria

- [ ] A deliberately failed `kubeadm init` (e.g. wrong `control_plane_endpoint`) prints an actionable error
- [ ] A deliberately failed `kubeadm join` (e.g. ufw blocking 6443) prints an actionable error
- [ ] No bootstrap token or certificate key appears in `ansible-playbook cluster.yml` output on a **successful** run
- [ ] `kubeadm token create --print-join-command` output is still suppressed

## Work Log

- 2026-07-26 — RESOLVED in the same session. kubeadm init: added --skip-token-print and dropped no_log, so failures are now diagnosable. kubeadm join: kept no_log (token is on the command line) but wrapped in block/rescue that prints stderr_lines and a journalctl pointer. Token-minting task keeps no_log — its whole output is the secret.
- 2026-07-26 — Filed from `/ce-review`. Noted that `no_log` on these tasks is a
  deliberate project convention (recorded in project memory); this finding does
  not dispute the goal, only the mechanism — `--skip-token-print` achieves the
  same secrecy without sacrificing diagnostics.

## Resources

- `ansible/roles/control_plane/tasks/main.yml:12-21`
- `ansible/roles/worker/tasks/main.yml:9-16`
- Related: `005-pending-p2-worker-label-race-after-join.md`
