---
status: ready
priority: p2
issue_id: "018"
tags: [ansible, apt, kubernetes, idempotence]
dependencies: []
---

# Test Kubernetes package changes through apt holds

## Problem Statement

The `kubernetes_node` role uses exact apt versions together with persistent
package holds. Static checks and live same-version reruns pass, but no automated
test proves that a deliberate version change succeeds while the old packages
are held and that the resulting state is quiet on the next run.

## Findings

- `roles/kubernetes_node/tasks/main.yml` uses
  `allow_change_held_packages: true` for containerd and Kubernetes packages.
- The live cluster proved current-version idempotence, but did not perform a
  real upgrade or downgrade through a hold.
- The existing Molecule scenario intentionally covers only `hardening`; a
  container cannot validate this role's kernel and kubelet behavior.

## Proposed Solutions

### Option 1: Disposable VM transition test

**Approach:** Provision a disposable Ubuntu VM with an older available pinned
version, hold the managed packages, change the role pins, run the role, and
verify versions, hold state, services, and a zero-change rerun.

**Pros:** Exercises real apt, dpkg, systemd, kernel, and kubelet behavior.

**Cons:** Requires a VM fixture and access to two repository versions.

**Effort:** 3-5 hours

**Risk:** Low

---

### Option 2: Focused apt-only integration fixture

**Approach:** Extract the install-and-hold lifecycle into a narrowly scoped
test fixture using harmless packages with two versions.

**Pros:** Faster and easier to automate.

**Cons:** Does not prove the exact Kubernetes and Docker repository behavior.

**Effort:** 2-3 hours

**Risk:** Medium

## Recommended Action

Use a disposable Ubuntu VM and test a supported one-patch Kubernetes version
transition through existing holds. Keep this outside the normal homelab nodes so
the test cannot disrupt the live cluster.

## Technical Details

**Affected files:**

- `roles/kubernetes_node/tasks/main.yml`
- A new disposable-VM integration scenario or CI workflow

No production cluster or persistent data should be used as the test target.

## Acceptance Criteria

- [ ] Test starts with all four managed packages held at known versions.
- [ ] Changing exact pins successfully installs the requested versions.
- [ ] `apt-mark showhold` contains kubelet, kubeadm, kubectl, and containerd.io.
- [ ] containerd and kubelet remain operational after the transition.
- [ ] A second identical Ansible run reports zero changes.
- [ ] The test runs only against a disposable machine.

## Work Log

### 2026-08-02 - Review discovery

**By:** Codex

**Actions:**

- Confirmed same-version live idempotence on all three homelab nodes.
- Identified the missing real version-transition test during final review.

**Learnings:**

- A container-only test would not validate the kernel and kubelet portions of
  this role, so the useful test boundary is a disposable VM.
