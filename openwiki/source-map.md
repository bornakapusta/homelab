---
type: Repository Reference
title: Repository Source Map and Evolution
description: Practical map of implementation, planning, tests, review evidence, and recent Git history for engineers navigating the homelab repository.
tags: [source-map, git-history, repository, navigation]
---

# Source map and repository evolution

## Start here by task

| Task | Primary sources |
|---|---|
| Understand intended use and basic commands | `README.md`, `Makefile` |
| Change topology or addresses | `ansible/inventory.ini`, `ansible/group_vars/all.yml` |
| Change node convergence | `ansible/site.yml`, `ansible/roles/*/tasks/main.yml` |
| Change bootstrap or Cilium | `ansible/cluster.yml`, `ansible/roles/control_plane/`, `ansible/roles/worker/` |
| Change safety assertions | `ansible/roles/preflight/` and role `meta/argument_specs.yml` |
| Change SSH, UFW, or updates | `ansible/roles/hardening/`, `ansible/molecule/hardening/` |
| Change controller dependencies | `ansible/requirements.yml`, `ansible/ansible.cfg`, `Makefile` |
| Understand product roadmap | `docs/PROJECT-PLAN.md`, then `docs/homelab-roadmap.md` |
| Investigate accepted or pending findings | `todos/`, recent `.context` review output |
| Run checks | `Makefile`, `.ansible-lint`, `.pre-commit-config.yaml` |

Use the [architecture overview](/openwiki/architecture/overview.md) for conceptual relationships before editing these files. The [provisioning workflows](/openwiki/workflows/provisioning.md) map executable ordering across them.

## Repository areas

### `autoinstall/`

`user-data.example` is a minimal cloud-init/autoinstall seed with placeholders. Its storage block is deliberately incomplete; the intended layout must be harvested from a successful interactive install. Real `user-data` is ignored because it contains sensitive identity material.

### `ansible/`

This is the implemented product core:

- `inventory.ini` defines Stage A topology and current physical addresses.
- `group_vars/all.yml` is the user-facing configuration hub.
- `site.yml` serially converges all nodes.
- `cluster.yml` initializes control plane, joins workers, and reports readiness.
- `ansible.cfg` controls inventory, output, sudo, SSH trust-on-first-use, and pipelining.
- `requirements.yml` pins collection major ranges.
- `roles/` contains seven explicit roles with README, defaults, tasks, argument specs, and metadata as applicable.
- `molecule/hardening/` is the only automated runtime scenario.
- Generated `kubeconfig` is local admin credential material and must stay untracked.

The canonical role sequence and ownership are documented in [architecture](/openwiki/architecture/overview.md); safety-sensitive values are documented in [configuration and security](/openwiki/domain/configuration-and-security.md).

### `docs/`

The docs tree is primary decision evidence, but not every statement is current implementation truth:

- `PROJECT-PLAN.md` is the broad target and phase checklist.
- `homelab-roadmap.md` expands the phases.
- `linux-k8s-foundations.md` records deeper technology choices.
- `homelab-decision-doc.md` is historical research; its k3s-then-Talos recommendation was superseded by Ubuntu plus kubeadm.
- SVG, HTML, and PDF artifacts visualize or package those plans.

Some current planning text still says Ubuntu 24.04, while inventory, README, package pins, and the latest commit target real Ubuntu 26.04 nodes. For executable decisions, prefer current inventory and code.

### `todos/`

Todos preserve code-review reasoning and acceptance criteria. Most are marked complete. Important active items are:

- `001-ready-p1-dedicated-ansible-user.md`: implementation exists; manual rollout and account switch remain.
- `016-pending-p3-apt-repository-deprecated.md`: migrate to deb822 after a known-good physical baseline.
- `017-pending-p2-tailscale-block-gaps.md`: fix supply-chain verification, credential storage, and UFW reachability.

A newer Cilium review reports an active package hold defect despite the older idempotency todo being complete. Prefer newer evidence when todo status and current code conflict. See the [operations runbook](/openwiki/operations/runbook.md).

### Root quality and operator files

- `Makefile` is the practical operator interface.
- `.ansible-lint` enforces the production profile.
- `.pre-commit-config.yaml` supplies secret and quality hooks.
- `.gitignore` protects predicted credential paths.
- `README.md` is the concise public setup guide.
- `CLAUDE.md` contains detailed repository operating guidance and has current uncommitted edits.

There is no infrastructure quality CI. The untracked `.github/workflows/openwiki-update.yml` updates documentation rather than provisioning code.

## Git evolution

The repository has three commits at the documented HEAD.

### Initial implementation

`bfcf354` established the current architectural boundary: Ansible owns machines and bootstrap, while future Argo CD owns cluster contents. It added serial node convergence, kubeadm plus the then-selected Calico path, pinned versions and digests, the two-user model, Make targets, docs, and review todos.

### Code-of-practice hardening

`d051d3d` added argument specs and role READMEs, fully namespaced role variables, centralized inventory-group resolution, provenance and backups for managed files, pre-commit secret scanning, and the hardening Molecule scenario. It deliberately retained local checks rather than CI and documented that `meta: flush_handlers` crosses role boundaries.

### Retargeting to physical reality

`19c42d9` replaced assumed addresses with the observed `.11`, `.44`, and `.66` values and moved package/test targets from Ubuntu 24.04 `noble` to 26.04 `resolute`. The commit explains why these addresses affect far more than SSH and why containerd's package suffix must match the Ubuntu suite. It also records the unresolved interactive-sudo blocker.

### Current uncommitted direction

The working tree replaces Calico bootstrap with a minimal Cilium path that:

- verifies an OCI digest resolves to the expected chart;
- requires reviewed Helm 4.2.x;
- refuses unsafe side-by-side Calico migration;
- compares release state, chart version, and exact values before reconciliation;
- rolls back failed Helm operations;
- waits for Cilium before cluster reporting.

Offline review under `ansible/.context/compound-engineering/ce-review/` reports passing available checks and a ready-to-merge verdict, with physical-cluster validation still outstanding. It also identifies the pre-existing package hold issue.

## Editing guidance

- Read `git status` and `git diff` before work: current behavior is not fully committed.
- Do not regenerate or hand-edit planning artifacts when changing runtime unless the decision itself changed.
- Keep machine state in Ansible and future in-cluster state in GitOps paths.
- Preserve role ordering and cross-role handler assumptions unless deliberately redesigning them.
- Pair implementation changes with the checks in [testing and validation](/openwiki/testing.md).
- Pair operationally risky changes with deployment and rollback updates in the [operations runbook](/openwiki/operations/runbook.md).
